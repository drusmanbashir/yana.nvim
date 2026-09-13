-- The renewal BRIEF's construction and rendering — split out of
-- lua/yana/renewal.lua. Builds the durable brief record from
-- yana's own records (ledger decisions, change-set statuses, system
-- refusals) and renders it two ways: the operator's capped panel copy and
-- the larger carry-text the next turn receives. See renewal.lua's own
-- header comment for why the brief exists at all.
--
-- `deps` carries the parent's product-policy caps (constants, not options —
-- see renewal.lua) so this module closes over no upvalue it was not handed.
local M = {}

function M.new(deps)
----------------------------------------------------------------------
-- THE ANSWER ARTIFACT
----------------------------------------------------------------------

--- The code blocks of an answer, verbatim, or the whole answer when it carries
--- none.
---
--- Verbatim matters: an artifact that is summarised, reflowed or re-indented is not the
--- thing the operator asked to integrate.
local function answer_artifact(answer)
	if type(answer) ~= "string" or answer == "" then
		return nil, nil
	end
	local blocks = {}
	for block in answer:gmatch("```[%w_%-%+%.#]*\n(.-)\n```") do
		local body = vim.trim(block)
		if body ~= "" then
			blocks[#blocks + 1] = body
		end
	end
	if #blocks > 0 then
		return table.concat(blocks, "\n\n"), "code_blocks"
	end
	return answer, "answer_text"
end

local function clip(s, cap)
	if type(s) ~= "string" then
		return nil, false
	end
	if #s <= cap then
		return s, false
	end
	return s:sub(1, cap), true
end

----------------------------------------------------------------------
-- BUILDING THE BRIEF
----------------------------------------------------------------------

local function push_unique(list, seen, key, row)
	if key == nil or key == "" or seen[key] then
		return
	end
	seen[key] = true
	list[#list + 1] = row
end

--- Accepted / rejected / system-refused file sets, from YANA'S OWN RECORDS.
---
--- Three sources, in decreasing authority, unioned by file name:
---   * the turn LEDGER's decisions (`accept_file`/`accept_hunk`/`accept_turn`,
---     `reject_file`/`reject_hunk`, and the `system`-actor refusals) — the
---     record of what the operator and the control plane actually did;
---   * the CHANGE SET's own statuses, which carry the turn-start fingerprint;
---   * `p.system_refusals`, the same rows `:YanaRefusals` shows.
---
--- None of them is agent prose. The agent's own summary of what it did is
--- exactly the thing the operator note said was not enough, and it is not
--- consulted here at all.
local function decision_sets(p)
	local accepted, rejected, refused = {}, {}, {}
	local seen_a, seen_r, seen_f = {}, {}, {}
	-- A plain submit runs before the new turn's ledger exists, so p.turn_gen is
	-- the previous turn. Lifetime p.changes must not leak older decisions into
	-- this turn's note.
	local previous_gen = p.turn_gen
	local seen_untagged = p._decision_note_seen_untagged or {}
	local seen_refusals = p._decision_note_seen_refusals or {}
	p._decision_note_seen_untagged = seen_untagged
	p._decision_note_seen_refusals = seen_refusals

	local function belongs_to_previous_turn(change)
		if change.turn_gen ~= nil then
			return tostring(change.turn_gen) == tostring(previous_gen)
		end
		if seen_untagged[change] then
			return false
		end
		seen_untagged[change] = true
		return true
	end

	for _, c in ipairs(p.changes or {}) do
		if belongs_to_previous_turn(c) then
			local name = c.rel or c.path
			local hash = c.base_hash
			if c.status == "accepted" then
				if c._accept_regime == "transfer" then
					local b = vim.fn.bufnr(c.path, false)
					if b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
						name = tostring(name) .. " (accepted, unsaved — not yet on disk)"
					end
				end
				push_unique(accepted, seen_a, name, { rel = name, hash = hash })
			elseif c.status == "rejected" then
				push_unique(rejected, seen_r, name, { rel = name })
			elseif c.status == "system_refused" then
				push_unique(refused, seen_f, name, { rel = name, reason = c.review_error or c.refusal_reason })
			end
			if c.review_error and c.review_error ~= "" then
				push_unique(refused, seen_f, name, { rel = name, reason = c.review_error })
			end
		end
	end

	for _, row in ipairs(p.system_refusals or {}) do
		if not seen_refusals[row] then
			seen_refusals[row] = true
			push_unique(refused, seen_f, row.rel, { rel = row.rel, reason = row.reason or row.refusal_reason })
		end
	end

	local okl, ledger = pcall(require, "yana.ledger")
	if okl and p.id ~= nil then
		local okg, L = pcall(ledger.latest, p.id)
		if okg and type(L) == "table" then
			for _, d in ipairs(L.decisions or {}) do
				local name = d.rel
				local a = d.action
				if d.actor == "user" and (a == "accept_file" or a == "accept_hunk" or a == "accept_turn") then
					push_unique(accepted, seen_a, name, { rel = name })
				elseif d.actor == "user" and (a == "reject_file" or a == "reject_hunk") then
					push_unique(rejected, seen_r, name, { rel = name })
				elseif d.actor == "system" and d.status == "system_refused" then
					push_unique(refused, seen_f, name, { rel = name, reason = d.reason })
				end
			end
		end
	end

	return accepted, rejected, refused
end

--- How the previous turn ENDED, from the ledger's own closing record.
local function outcome_of(p)
	local okl, ledger = pcall(require, "yana.ledger")
	if not okl or p.id == nil then
		return nil
	end
	local okg, L = pcall(ledger.latest, p.id)
	if not okg or type(L) ~= "table" then
		return nil
	end
	local o = L.outcome
	if type(o) ~= "table" then
		return nil
	end
	if o.cancelled then
		return "cancelled"
	end
	if o.turn_errored or (o.exit_code ~= nil and o.exit_code ~= 0) then
		return string.format("ended with an error (exit %s)", tostring(o.exit_code))
	end
	if o.got_result then
		return "completed"
	end
	return "ended without a result"
end

--- Compose the brief for a renewal from `from_mode` to `to_mode`.
---
--- The returned RECORD is the durable object; `M.carry_text` and
--- `M.display_text` render it. Keeping the record separate from its rendering
--- is what lets the operator's copy stay short while the next turn receives
--- the whole artifact — two different caps on one set of facts, rather than
--- one string that has to be both.
local render_decision_note
local function build(p, from_mode, to_mode)
	p = p or {}
	local artifact, artifact_kind = answer_artifact(p.last_answer_text)
	local accepted, rejected, refused = decision_sets(p)
	local instruction = nil
	if p.last_question and p.last_question ~= "" then
		instruction = tostring(p.last_question):gsub("%s+", " ")
	end

	return {
		-- BINDING. Which conversation, which session and which turn this brief
		-- is the continuation of. `panel_id` + `review_epoch` are what make a
		-- brief non-transferable: `new_chat` bumps the epoch, so a brief staged
		-- for a conversation that was then thrown away can never be injected
		-- into its replacement (see M.consume).
		panel_id = p.id,
		review_epoch = p.review_epoch,
		from_session_id = p.session_id,
		from_turn_gen = p.turn_gen,
		from_turn_id = p.shadow_turn and p.shadow_turn.turn_id or nil,

		workspace = tostring(p.cwd or vim.fn.getcwd()),
		from_mode = tostring(from_mode),
		to_mode = tostring(to_mode),
		instruction = instruction,
		outcome = outcome_of(p),
		accepted = accepted,
		rejected = rejected,
		system_refused = refused,
		decision_note = render_decision_note(accepted, rejected, refused),
		artifact = artifact,
		artifact_kind = artifact_kind,
		built_at = os.time(),
	}
end

----------------------------------------------------------------------
-- RENDERING
----------------------------------------------------------------------

local function name_list(rows, cap)
	local names = {}
	for i, row in ipairs(rows) do
		if i > cap then
			names[#names + 1] = string.format("… and %d more", #rows - cap)
			break
		end
		if row.hash and row.hash ~= "" then
			names[#names + 1] = string.format("%s@%s", row.rel, tostring(row.hash):sub(1, deps.hash_prefix))
		else
			names[#names + 1] = tostring(row.rel)
		end
	end
	return table.concat(names, ", ")
end

local function refused_list(rows, cap)
	local out = {}
	for i, row in ipairs(rows) do
		if i > cap then
			out[#out + 1] = string.format("… and %d more", #rows - cap)
			break
		end
		if row.reason and row.reason ~= "" then
			out[#out + 1] = string.format("%s (%s)", tostring(row.rel), tostring(row.reason))
		else
			out[#out + 1] = tostring(row.rel)
		end
	end
	return table.concat(out, ", ")
end

render_decision_note = function(accepted, rejected, refused)
	if #accepted == 0 and #rejected == 0 and #refused == 0 then
		return nil
	end
	local lines = {
		"Yana record from the previous turn; operator decisions are authoritative, not agent claims:",
	}
	if #accepted > 0 then
		lines[#lines + 1] = "Accepted: " .. name_list(accepted, deps.file_list_cap)
	end
	if #rejected > 0 then
		lines[#lines + 1] = "Rejected: " .. name_list(rejected, deps.file_list_cap)
	end
	if #refused > 0 then
		lines[#lines + 1] = "Refused: " .. refused_list(refused, deps.file_list_cap)
	end
	return table.concat(lines, "\n")
end

--- The five-line head every rendering shares.
local function head_lines(b)
	local lines = {
		"Continuing an existing conversation in a new mode.",
		string.format("Workspace: %s", b.workspace),
		string.format("Mode: %s (was %s)", b.to_mode, b.from_mode),
	}
	if b.instruction then
		local q = clip(b.instruction, deps.instruction_cap_bytes)
		if #b.instruction > deps.instruction_cap_bytes then
			q = q .. "…"
		end
		lines[#lines + 1] = "Previous instruction: " .. q
	end
	if b.outcome then
		lines[#lines + 1] = "Previous outcome: " .. b.outcome
	end
	if #b.accepted > 0 then
		lines[#lines + 1] = "Accepted last turn: " .. name_list(b.accepted, deps.file_list_cap)
	end
	if #b.rejected > 0 then
		lines[#lines + 1] = "Rejected last turn: " .. name_list(b.rejected, deps.file_list_cap)
	end
	-- A refusal is part of the story: a control-plane refusal in particular is
	-- something the next session must not be told happened cleanly.
	if #b.system_refused > 0 then
		lines[#lines + 1] = "Refused: " .. refused_list(b.system_refused, deps.file_list_cap)
	end
	return lines
end

--- What the NEXT TURN receives. Carries the artifact.
local function carry_text(b)
	if type(b) ~= "table" then
		return nil
	end
	local lines = head_lines(b)
	if b.artifact and b.artifact ~= "" then
		local body, truncated = clip(b.artifact, deps.carry_cap_bytes)
		lines[#lines + 1] = (b.artifact_kind == "code_blocks")
				and "Artifact from the previous answer (its code blocks, verbatim):"
			or "The previous answer, carried in full:"
		lines[#lines + 1] = body .. (truncated and "\n…" or "")
	end
	return table.concat(lines, "\n")
end

--- What the OPERATOR is shown at the moment of switching. Same facts, artifact
--- NAMED and headed rather than printed whole: a handoff they cannot see is a
--- handoff they cannot correct, and a handoff they will not read is the same
--- thing again.
local function display_text(b)
	if type(b) ~= "table" then
		return nil
	end
	local lines = head_lines(b)
	if b.artifact and b.artifact ~= "" then
		local body, truncated = clip(b.artifact, deps.display_cap_bytes)
		lines[#lines + 1] = string.format(
			"Last ask artifact: %d bytes of %s, carried in full to the next message%s",
			#b.artifact,
			b.artifact_kind == "code_blocks" and "code" or "answer text",
			truncated and " (head shown here)" or ""
		)
		lines[#lines + 1] = body .. (truncated and "\n…" or "")
	end
	return table.concat(lines, "\n")
end

  return {
    answer_artifact = answer_artifact,
    build = build,
    carry_text = carry_text,
    display_text = display_text,
  }
end

return M
