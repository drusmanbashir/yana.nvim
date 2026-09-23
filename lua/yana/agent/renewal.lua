-- Do not extend. CONTEXT-PRESERVING MODE RENEWAL.
--
-- cursor's upstream session carries a FIXED mode chain, so a mode switch is a
-- seat re-attach: end the upstream session, start a new one in the new mode and
-- hand it a brief. The brief is BUILT from yana's own records, BOUND to the
-- conversation and turn it came from, SHOWN to the operator at the switch, and
-- INJECTED into the next prompt EXACTLY ONCE.
--
-- Nothing agent-authored may reach a control-plane decision, so the brief is
-- composed only from the operator's instruction, the ledger's decisions, the
-- change set's statuses and the panel's system refusals; never the transcript.
local M = {}

local config = require("yana.config")

----------------------------------------------------------------------
-- PRODUCT POLICY. Constants, not options.
----------------------------------------------------------------------

--- What the PANEL shows. A carried answer is NAMED and its head shown rather
--- than printed whole, so the operator's copy stays five-lines-checkable.
M.DISPLAY_ARTIFACT_CAP_BYTES = 1200

--- What the NEXT TURN receives. Larger than the display cap on purpose, but
--- bounded: an unbounded carry is sized by the previous agent's output.
M.CARRY_ARTIFACT_CAP_BYTES = 16384

--- The operator's own previous instruction, normalised onto one line.
M.INSTRUCTION_CAP_BYTES = 300

--- File names each of the three sets prints before saying how many more.
M.FILE_LIST_CAP = 12

--- Hash prefix length in the accepted set.
M.HASH_PREFIX = 12

-- Brief construction and rendering live in renewal_brief.lua; the facade below
-- keeps every M.* export reachable here, and deps carries the caps above.
local renewal_brief = require("yana.agent.renewal_brief").new({
	hash_prefix = M.HASH_PREFIX,
	file_list_cap = M.FILE_LIST_CAP,
	instruction_cap_bytes = M.INSTRUCTION_CAP_BYTES,
	carry_cap_bytes = M.CARRY_ARTIFACT_CAP_BYTES,
	display_cap_bytes = M.DISPLAY_ARTIFACT_CAP_BYTES,
})
M.answer_artifact = renewal_brief.answer_artifact
M.build = renewal_brief.build
M.carry_text = renewal_brief.carry_text
M.display_text = renewal_brief.display_text

----------------------------------------------------------------------
-- Every refusal is STRUCTURED: a `condition` (what is true that must not be) and
-- an `action` (what the operator can do about it).
----------------------------------------------------------------------

local function refusal(code, condition, action)
	return { code = code, condition = condition, action = action }
end

--- Why this chat cannot renew right now, as a structured refusal, or nil.
---
--- Ordered by cost, cheapest first, and by how close the condition is to the operator.
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

	-- 3. no unresolved diary bundle awaiting apply or replay. Daemon status is
	-- checked by `check_blocked`; this helper performs local checks only.
	-- `diary.status_summary` counts every `intent`/`displaced` journal row with no
	-- `done`, `refused` or `conflict` row against it.
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

local function status_refusal(p, status)
	local own_session = p.yanad_session_id and tostring(p.yanad_session_id) or nil
	for _, sess in ipairs(status.sessions or {}) do
		if own_session and tostring(sess.session_id) == own_session and sess.review then
			local sid = tostring(sess.session_id or "?")
			return refusal(
				"review_open_disk",
				"this session still has an open review recorded by yanad",
				"finish or reject it first (ca / :YanaReject); or abort with: bin/yana-overlay review-abort --session '"
					.. sid
					.. "'"
			)
		end
		if own_session and tostring(sess.session_id) == own_session then
			for _, turn in ipairs(sess.turns or {}) do
				local active = turn.state == "running" or turn.state == "settling" or turn.state == "reviewing"
				if active then
					return refusal(
						"turn_open",
						string.format(
							"yanad still has this session's turn open (session %s turn %s state %s)",
							tostring(sess.session_id),
							tostring(turn.turn_id),
							tostring(turn.state)
						),
						"wait for that turn to settle, or resolve the session with review-abort / session-delete"
					)
				end
			end
		end
	end
	return nil
end

local status_seq = 0

--- Check renewal without blocking. Ask skips daemon status because it cannot
--- claim or write the workspace.
function M.check_blocked(p, target_mode, done)
	local local_refusal = M.blocked(p)
	if local_refusal then
		done(local_refusal)
		return true
	end
	if target_mode == "ask" then
		done(nil)
		return true
	end
	status_seq = status_seq + 1
	local request_id = table.concat({
		"renewal",
		"status",
		tostring((vim.uv or vim.loop).hrtime()),
		tostring(status_seq),
	}, ":")
	require("yana.runtime.yanad").status({}, request_id, function(ok, result_or_code)
		if not ok or type(result_or_code) ~= "table" then
			done(refusal(
				"status_unknown",
				"yanad status is unavailable (" .. tostring(result_or_code or "unknown") .. ")",
				"wait for yanad to recover, then switch mode again"
			))
			return
		end
		done(status_refusal(p, result_or_code))
	end)
	return true
end

local function render_refusal(r)
	if not r then
		return nil
	end
	if r.action == nil or r.action == "" then
		return r.condition
	end
	return r.condition .. " — " .. r.action
end

function M.check_blocked_reason(p, target_mode, done)
	return M.check_blocked(p, target_mode, function(r)
		done(render_refusal(r))
	end)
end

--- The operator-facing rendering of `M.blocked`: condition, then action appended.
function M.blocked_reason(p)
	return render_refusal(M.blocked(p))
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
	-- Rendered once here, not at injection, so the brief cannot change between
	-- what the operator was shown and what the agent was sent.
	p.pending_brief = M.carry_text(brief)
	return p.pending_brief
end

--- True when this staged brief belongs to THIS conversation.
---
--- `new_chat` bumps `review_epoch`; without this check a brief orphaned by a
--- new chat would be injected into a conversation it has nothing to do with.
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
--- The fields are cleared before the value is returned, so a second call gets
--- nothing; a brief replayed on later turns would drift out of date silently.
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

--- Drop anything staged. Used by `new_chat`.
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
-- "I changed my mind. Do my previous request in inline mode." is a POINTER that
-- resolves to nothing in a renewed session. The product must supply the referent
-- or refuse; it never guesses. A pattern list is safe here: it only selects
-- between SENDING and REFUSING, never a mode, root or permission.
----------------------------------------------------------------------

--- Phrases that refer to an earlier request without restating it. Fixed product
--- policy, matched against the lower-cased prompt.
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
--- block, it states its own content (the `ask`-answer resend quotes its artifact).
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
--- Any of three sources the NEXT AGENT receives is enough: a LIVE upstream
--- session (`--resume`), a STAGED BRIEF carrying the previous instruction or
--- artifact, or a PACK SHARED CONTEXT block from the panel's conversation memory.
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
	if (p.last_question and p.last_question ~= "") or (p.last_answer_text and p.last_answer_text ~= "") then
		return true, "pack shared context"
	end
	return false, nil
end

--- Should this submit be refused, and why?
---
--- Returns nil when the prompt may go, or a structured refusal.
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

--- The toggle_mode cycle: config.modes, in list order.
function M.cycle()
	return vim.deepcopy(config.options.modes)
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
