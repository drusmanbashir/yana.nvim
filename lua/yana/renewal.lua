-- CONTEXT-PRESERVING MODE RENEWAL — the BRIEF (the modes module doc, Stage 0
-- and Stage 1; the rollout doc's mode-switch question).
--
-- WHY THIS IS A MODULE AND NOT A PAIR OF LOCALS IN ui.lua. A mid-chat mode
-- switch cannot be a flag flip: cursor's upstream session carries a FIXED mode
-- chain. So switching is SESSION RENEWAL WITH CONTEXT CARRY — end the upstream
-- session, start a new one in the new mode, hand it a brief. From the
-- operator's side the chat continues. That makes the brief a durable object
-- with four separable duties, each of which is a place a handoff can silently
-- lose something:
--
--   1. BUILD it from yana's OWN records;
--   2. BIND it to the identity of the conversation and turn it came from;
--   3. SHOW it to the operator at the moment of switching;
--   4. INJECT it into the next prompt EXACTLY ONCE.
--
-- THE CARDINAL PRINCIPLE (the product's core ruling) IS THE CONSTRAINT THAT SHAPES EVERY LINE
-- HERE. Nothing agent-influenced may select a mode, and nothing agent-authored
-- may be laundered into a control-plane decision. So the brief is composed
-- from the operator's own instruction, the ledger's decisions, the change
-- set's statuses and the panel's system refusals. The ONE piece of agent text
-- that crosses is the ANSWER ARTIFACT, and it crosses as an OPAQUE PAYLOAD
-- addressed to the next agent — never parsed for a mode, a root, a permission
-- or a path. It is carried because the operator ruled that it must be
-- (modes.md, "the brief must carry the ANSWER, not only a summary of it"):
-- an `ask` turn accepts no files, so the accepted/rejected sets are empty and
-- the code the operator wants integrated lives only in the answer.
--
-- WHAT IS DELIBERATELY NOT CARRIED: the raw transcript. "A brief the operator
-- can read in five lines beats a replay nobody checks."
local M = {}

local config = require("yana.config")

----------------------------------------------------------------------
-- PRODUCT POLICY. Constants, not options.
--
-- A brief whose size the operator can dial is a brief whose truncation is
-- their fault when the next turn loses the artifact. These are the product's
-- numbers and they are stated in the modes module doc, §3.
----------------------------------------------------------------------

--- What the PANEL shows. The operator's copy stays five-lines-checkable, so a
--- carried answer is NAMED and its head shown rather than printed whole
--- (modes.md: "a carried answer is longer than five lines, so 'shown' may mean
--- named and expandable rather than printed in full").
M.DISPLAY_ARTIFACT_CAP_BYTES = 1200

--- What the NEXT TURN receives. Larger than the display cap on purpose: the
--- same operator note says the displayed brief is capped "and the next turn
--- receives the artifact as context". Bounded all the same — an unbounded
--- carry is a prompt whose size is decided by the previous agent's output.
M.CARRY_ARTIFACT_CAP_BYTES = 16384

--- The operator's own previous instruction, normalised onto one line.
M.INSTRUCTION_CAP_BYTES = 300

--- How many file names each of the three sets prints before it says how many
--- more there were. A brief that lists two hundred files is a transcript.
M.FILE_LIST_CAP = 12

--- Hash prefix length in the accepted set. Long enough to distinguish, short
--- enough to stay inside a readable line.
M.HASH_PREFIX = 12

----------------------------------------------------------------------
-- PRECONDITIONS — Stage 0's five quiescent checks.
--
-- Every refusal is STRUCTURED: a `condition` (what is true that must not be)
-- and an `action` (the thing the operator can do about it). Splitting them is
-- the point, not decoration. rollout.md Q12 records the friction that produced
-- it — "a refusal that does not name the action that clears it is a defect,
-- not a message" — and rung 2 of the project's friction ladder says the way to
-- retire a judgement is to make it a field a test can read. `action` is that
-- field: it is either populated or it is not, and no row has to grade prose.
--
-- The rendered form is `condition .. " — " .. action`, which APPENDS the
-- action to the text existing rows already grep for rather than replacing it
-- (Q12's explicit rule).
----------------------------------------------------------------------

local function refusal(code, condition, action)
	return { code = code, condition = condition, action = action }
end

--- Where this workspace's claim lives, if it can be derived at all.
local function claim_dir_for(p)
	local turn = p.shadow_turn
	if turn and turn.claim_dir then
		return turn.claim_dir
	end
	if not p.cwd then
		return nil
	end
	local okp, preview = pcall(require, "yana.shadow.preview")
	if not okp then
		return nil
	end
	local okc, dir = pcall(preview.claim_dir, p.cwd)
	return okc and dir or nil
end

--- The runnable release for a named claim. Q12 records the RIGHT shape by
--- worked example: an unapproved root refuses and prints the exact
--- `--approve-root` command. This does the same for a stuck claim instead of
--- telling the operator that something is held and leaving them to find out
--- how to unstick it.
local function release_action(claim_dir)
	if not claim_dir or claim_dir == "" then
		return "wait for it to settle, or force-release the claim once you have confirmed the holder is gone"
	end
	return string.format(
		"wait a moment; if the holder is gone, force-release it with "
			.. ":lua require('yana.ui').force_release_claim('<why>') (CLI: bin/yana-overlay force-release --claim %s --reason '<why>')",
		claim_dir
	)
end

--- Why this chat cannot renew right now, as a structured refusal, or nil.
---
--- Ordered by cost, cheapest first, and by how close the condition is to the
--- operator: an in-flight turn is the one they can see.
function M.blocked(p)
	if not p then
		return refusal("no_panel", "there is no yana panel here", "open one with :Yana")
	end

	-- 1. no turn in flight for this chat.
	if p.busy or p.job ~= nil or p.awaiting_exit then
		return refusal("turn_in_flight", "a turn is still running", "wait for it to finish, or :YanaStop")
	end

	-- 2. no open review and no pending changes for this workspace.
	local pending = require("yana.diff").pending(p.changes or {})
	if #pending > 0 then
		return refusal(
			"pending_changes",
			string.format("%d change(s) are still awaiting your decision", #pending),
			"accept or reject them first (ca / :YanaReject)"
		)
	end
	if require("yana.inline_diff").active_state({}) ~= nil then
		return refusal("review_open", "a review is open", "finish or reject it first (ca / :YanaReject)")
	end

	-- 3/4. the claim carries no review-open marker, and the previous turn
	-- released it. Read from DISK rather than from our own memory of it: the
	-- marker outliving the process is exactly the case this must not miss.
	local claim_dir = claim_dir_for(p)
	if claim_dir then
		local okj, jail = pcall(require, "yana.shadow.jail")
		if okj then
			if jail.review_open(claim_dir) then
				return refusal(
					"review_open_disk",
					"this workspace still has an open review recorded on disk",
					"finish or reject it first (ca / :YanaReject); " .. release_action(claim_dir)
				)
			end
			if jail.claim_held(claim_dir) then
				local holder = jail.claim_holder(claim_dir)
				return refusal(
					"claim_held",
					string.format(
						"the previous turn has not released its workspace claim yet (holder: %s)",
						tostring(holder or "unknown")
					),
					release_action(claim_dir)
				)
			end
		end
	end

	-- 5. no unresolved diary bundle awaiting apply or replay.
	--
	-- MEASURED SINCE 2026-08-20, AND THAT IS A CHANGE WORTH NAMING. This
	-- precondition shipped as a DERIVATION: the argument was that a bundle
	-- awaiting apply cannot exist without a pending change, an open review or a
	-- held claim, so checks 2-4 covered it. That argument was written down so
	-- it could be attacked rather than assumed, and `MODE-16` in
	-- the modes E2E test design doc was queued as its replacement
	-- trigger: "when diary grows a real unresolved-bundle query, MODE-15 is
	-- replaced by a direct check".
	--
	-- `diary.status_summary(session)` IS that query. It walks the journal and
	-- counts every `intent` (or `displaced`) row with no `done`, `refused` or
	-- `conflict` row against it — precisely "awaiting apply or replay". So the
	-- derivation is retired here and the check is a measurement.
	local pass = p.shadow_pass
	local dsession = pass and pass.diary_session or nil
	if dsession then
		local okd, diary = pcall(require, "yana.safety.diary")
		if okd then
			local oks, summary = pcall(diary.status_summary, dsession)
			if oks and type(summary) == "table" and (summary.pending or 0) > 0 then
				return refusal(
					"diary_unresolved",
					string.format(
						"%d journaled change(s) from the previous turn are still unresolved",
						summary.pending
					),
					"let the apply pass finish, or resolve the bundle (:YanaDump names the journal) before switching"
				)
			end
		end
	end

	return nil
end

--- The operator-facing rendering of `M.blocked`. Both halves, always, in that
--- order: existing rows grep the condition text, the action is APPENDED.
function M.blocked_reason(p)
	local r = M.blocked(p)
	if not r then
		return nil
	end
	if r.action == nil or r.action == "" then
		-- Not reachable through `M.blocked`, and deliberately not silently
		-- tolerated either: a refusal with no remedy is the defect Q12 names.
		return r.condition
	end
	return r.condition .. " — " .. r.action
end

----------------------------------------------------------------------
-- THE ANSWER ARTIFACT
----------------------------------------------------------------------

--- The code blocks of an answer, verbatim, or the whole answer when it carries
--- none.
---
--- "What is carried is the answer's code blocks — the artefact — not the
--- conversational prose around them" (modes.md, operator note 2026-08-19).
--- Verbatim matters: an artifact that is summarised, reflowed or re-indented
--- is not the thing the operator asked to integrate.
function M.answer_artifact(answer)
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

	for _, c in ipairs(p.changes or {}) do
		local name = c.rel or c.path
		local hash = c.base_hash
		if c.status == "accepted" then
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

	for _, row in ipairs(p.system_refusals or {}) do
		push_unique(refused, seen_f, row.rel, { rel = row.rel, reason = row.reason or row.refusal_reason })
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
function M.build(p, from_mode, to_mode)
	p = p or {}
	local artifact, artifact_kind = M.answer_artifact(p.last_answer_text)
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
			names[#names + 1] = string.format("%s@%s", row.rel, tostring(row.hash):sub(1, M.HASH_PREFIX))
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

--- The five-line head every rendering shares.
local function head_lines(b)
	local lines = {
		"Continuing an existing conversation in a new mode.",
		string.format("Workspace: %s", b.workspace),
		string.format("Mode: %s (was %s)", b.to_mode, b.from_mode),
	}
	if b.instruction then
		local q = clip(b.instruction, M.INSTRUCTION_CAP_BYTES)
		if #b.instruction > M.INSTRUCTION_CAP_BYTES then
			q = q .. "…"
		end
		lines[#lines + 1] = "Previous instruction: " .. q
	end
	if b.outcome then
		lines[#lines + 1] = "Previous outcome: " .. b.outcome
	end
	if #b.accepted > 0 then
		lines[#lines + 1] = "Accepted last turn: " .. name_list(b.accepted, M.FILE_LIST_CAP)
	end
	if #b.rejected > 0 then
		lines[#lines + 1] = "Rejected last turn: " .. name_list(b.rejected, M.FILE_LIST_CAP)
	end
	-- A refusal is part of the story: a control-plane refusal in particular is
	-- something the next session must not be told happened cleanly.
	if #b.system_refused > 0 then
		lines[#lines + 1] = "Refused: " .. refused_list(b.system_refused, M.FILE_LIST_CAP)
	end
	return lines
end

--- What the NEXT TURN receives. Carries the artifact.
function M.carry_text(b)
	if type(b) ~= "table" then
		return nil
	end
	local lines = head_lines(b)
	if b.artifact and b.artifact ~= "" then
		local body, truncated = clip(b.artifact, M.CARRY_ARTIFACT_CAP_BYTES)
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
function M.display_text(b)
	if type(b) ~= "table" then
		return nil
	end
	local lines = head_lines(b)
	if b.artifact and b.artifact ~= "" then
		local body, truncated = clip(b.artifact, M.DISPLAY_ARTIFACT_CAP_BYTES)
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

----------------------------------------------------------------------
-- STAGING, BINDING AND SINGLE CONSUMPTION
----------------------------------------------------------------------

--- Stage the brief on the panel for its next prompt.
function M.stage(p, brief)
	if not p or type(brief) ~= "table" then
		return nil
	end
	p.pending_brief_record = brief
	-- The rendered carry text is kept as its own field because ui.lua's prompt
	-- assembly reads it, `mode_ui_consistency_smoke` asserts on it, and a
	-- renderer that ran at injection time would let the brief change between
	-- what the operator was shown and what the agent was sent.
	p.pending_brief = M.carry_text(brief)
	return p.pending_brief
end

--- True when this staged brief belongs to THIS conversation.
---
--- `new_chat` throws the conversation away and bumps `review_epoch`. Without
--- this check a brief staged by a renewal and then orphaned by a new chat
--- would be injected into a conversation it has nothing to do with — the
--- operator would see a fresh chat and the agent would be told about a
--- previous turn that is not theirs.
function M.binds_to(brief, p)
	if type(brief) ~= "table" or not p then
		return false
	end
	if brief.panel_id ~= nil and brief.panel_id ~= p.id then
		return false
	end
	if brief.review_epoch ~= nil and brief.review_epoch ~= p.review_epoch then
		return false
	end
	return true
end

--- Take the staged brief, ONCE.
---
--- Consumed exactly once by construction: the fields are cleared before the
--- value is returned, so a second call — and a second submit — gets nothing.
--- A brief replayed on every later turn would drift out of date and start
--- contradicting the live conversation, which is a subtler failure than
--- forgetting it, because nothing on screen would say so.
---
--- Returns `text, brief`, or nil when there is nothing staged or the staged
--- brief belongs to a conversation that no longer exists.
function M.consume(p)
	if not p then
		return nil
	end
	local text = p.pending_brief
	local brief = p.pending_brief_record
	p.pending_brief = nil
	p.pending_brief_record = nil
	if text == nil or text == "" then
		return nil
	end
	if brief ~= nil and not M.binds_to(brief, p) then
		return nil, brief, "stale"
	end
	return text, brief
end

--- Drop anything staged. Used by `new_chat`: the conversation the brief
--- describes is being discarded, so the brief goes with it.
function M.clear(p)
	if not p then
		return
	end
	p.pending_brief = nil
	p.pending_brief_record = nil
end

----------------------------------------------------------------------
-- THE CHANGED-MIND PROMPT
--
-- "I changed my mind. Do my previous request in inline mode." — the operator's
-- own worked example. The prompt is a POINTER: it carries no statement of what
-- is to be done, only a reference to something said earlier. Sent into a
-- renewed session that was never told what came before, it resolves to
-- nothing, and the agent answers a question nobody asked.
--
-- That failure is silent in both directions — the operator sees their sentence
-- go out, the agent sees a coherent-looking instruction — so the product must
-- either supply the referent or refuse. It never guesses.
--
-- WHY A PATTERN LIST IS SAFE HERE. Nothing about this selects a mode, a root
-- or a permission: it selects between SENDING and REFUSING, and it errs
-- towards refusing only when the referent is genuinely absent. The text it
-- matches is the OPERATOR'S OWN, typed into the prompt buffer. Agent output
-- never reaches this function.
----------------------------------------------------------------------

--- Phrases that refer to an earlier request without restating it. Product
--- policy: a list, not a configurable one, and lower-cased at the call site.
M.BACK_REFERENCE_PATTERNS = {
	"previous request",
	"previous question",
	"previous instruction",
	"previous answer",
	"previous ask",
	"earlier request",
	"earlier question",
	"last request",
	"last question",
	"my last one",
	"what i asked",
	"what i just asked",
	"the thing i asked",
	"as i asked",
	"changed my mind",
	"same request",
	"same question",
	"that answer",
	"the answer above",
	"the code above",
	"please integrate", -- the operator's own worked example
	"now integrate",
	"go ahead and integrate",
}

--- Does this prompt refer back to something rather than state it?
--- Returns the matched phrase, or nil.
function M.back_reference(question)
	if type(question) ~= "string" or question == "" then
		return nil
	end
	local low = question:lower()
	for _, phrase in ipairs(M.BACK_REFERENCE_PATTERNS) do
		if low:find(phrase, 1, true) then
			return phrase
		end
	end
	return nil
end

--- A message that is ONLY a pointer. Longer than this, or carrying a fenced
--- block, and the message states its own content — the `ask`-answer resend
--- composes exactly such a prompt, quoting the artifact it refers to, and it
--- must not be refused for naming what it also carries.
M.POINTER_MAX_BYTES = 400

local function is_bare_pointer(question)
	if type(question) ~= "string" then
		return false
	end
	if #question > M.POINTER_MAX_BYTES then
		return false
	end
	return question:find("```", 1, true) == nil
end

--- What this chat can offer such a prompt as a referent.
---
--- Two honest sources, either of which is enough, and BOTH are things the NEXT
--- AGENT will actually receive:
---   * a LIVE upstream session (`--resume`): the agent has the history itself;
---   * a STAGED BRIEF carrying the previous instruction or artifact.
---
--- `p.last_question` is deliberately NOT a source. After a renewal the panel
--- still remembers the previous instruction, but the renewed session does not
--- and never will unless the brief carries it — counting the panel's memory as
--- a link is exactly the silent amnesia this refusal exists to prevent.
local function has_linked_intent(p)
	if not p then
		return false, "no panel"
	end
	if p.session_id ~= nil and p.session_id ~= "" then
		return true, "live upstream session"
	end
	local brief = p.pending_brief_record
	if type(brief) == "table" and M.binds_to(brief, p) then
		if (brief.instruction and brief.instruction ~= "") or (brief.artifact and brief.artifact ~= "") then
			return true, "staged renewal brief"
		end
	end
	return false, nil
end

--- Should this submit be refused, and why?
---
--- Returns nil when the prompt may go, or a structured refusal naming WHAT IS
--- MISSING and the remedy — the same two-field shape the renewal preconditions
--- use, for the same reason.
function M.changed_mind_gap(p, question)
	local phrase = M.back_reference(question)
	if not phrase then
		return nil
	end
	if not is_bare_pointer(question) then
		return nil
	end
	local linked, _ = has_linked_intent(p)
	if linked then
		return nil
	end
	return refusal(
		"unlinked_back_reference",
		string.format(
			"this message refers back to an earlier request (%q) but this chat has no earlier request to resolve it against"
				.. " — there is no upstream session to resume and no carried brief",
			phrase
		),
		"say what you want done in this message, or resume the earlier chat (:YanaSessions) and switch mode from there"
	)
end

--- The rendered form, for the notification.
function M.changed_mind_gap_reason(p, question)
	local r = M.changed_mind_gap(p, question)
	if not r then
		return nil
	end
	return r.condition .. " — " .. r.action
end

--- The mode cycle Stage 0/1 permits. `agentic` is absent unless the operator
--- explicitly opted in: the opt-in IS the operator selection, and a mode you
--- can reach by pressing a key twice is not a mode anyone chose deliberately.
function M.cycle()
	if config.options.enable_agentic == true then
		return { "ask", "inline", "agentic" }
	end
	return { "ask", "inline" }
end

--- The mode after `current` in the cycle.
function M.next_mode(current)
	local order = M.cycle()
	local idx = 1
	for i, m in ipairs(order) do
		if m == current then
			idx = i
			break
		end
	end
	return order[(idx % #order) + 1]
end

return M
