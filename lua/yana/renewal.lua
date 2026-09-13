-- Do not extend. CONTEXT-PRESERVING MODE RENEWAL.
--
-- A mid-chat mode switch cannot be a flag flip: cursor's upstream session carries a
-- FIXED mode chain. So switching is SEAT RE-ATTACH (legacy name kept for module path) —
-- end the upstream session, start a new one in the new mode, hand it a brief. From the
-- operator's side the chat continues.
--
--   1. BUILD it from yana's OWN records;
--   2. BIND it to the identity of the conversation and turn it came from;
--   3. SHOW it to the operator at the moment of switching;
--   4. INJECT it into the next prompt EXACTLY ONCE.
--
-- THE CARDINAL PRINCIPLE (the product's core ruling) IS THE CONSTRAINT THAT SHAPES
-- EVERY LINE HERE. Nothing agent-influenced may select a mode, and nothing
-- agent-authored may be laundered into a control-plane decision. So the brief is
-- composed from the operator's own instruction, the ledger's decisions, the change
-- set's statuses and the panel's system refusals.
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

-- Brief construction and rendering (answer_artifact, build, carry_text,
-- display_text) moved to renewal_brief.lua. Facade below keeps
-- every M.* export reachable under this module's original name; deps carries
-- the caps above so the split module closes over no bare upvalue.
local renewal_brief = require("yana.renewal_brief").new({
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
--
-- Every refusal is STRUCTURED: a `condition` (what is true that must not be) and an
-- `action` (the thing the operator can do about it). Splitting them is the point, not
-- decoration. `action` is that field: it is either populated or it is not, and no row
-- has to grade prose.
--
-- The rendered form is `condition .. " — " ..
----------------------------------------------------------------------

local function refusal(code, condition, action)
	return { code = code, condition = condition, action = action }
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

	-- 3. no unresolved diary bundle awaiting apply or replay. Daemon status is
	-- checked by `check_blocked`; this helper performs local checks only.
	--
	-- This precondition shipped as a DERIVATION: the argument was that a bundle awaiting
	-- apply cannot exist without a pending change, an open review or a held claim, so
	-- checks 2-4 covered it.
	--
	-- `diary.status_summary(session)` IS that query. It walks the journal and counts every
	-- `intent` (or `displaced`) row with no `done`, `refused` or `conflict` row against it
	-- — precisely "awaiting apply or replay".
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
--- claim or write the workspace (server ruling R-a).
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
	require("yana.yanad").status({}, request_id, function(ok, result_or_code)
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

--- The operator-facing rendering of `M.blocked`. Both halves, always, in that
--- order: existing rows grep the condition text, the action is APPENDED.
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
-- WHY A PATTERN LIST IS SAFE HERE. Nothing about this selects a mode, a root or a
-- permission: it selects between SENDING and REFUSING, and it errs towards refusing
-- only when the referent is genuinely absent. The text it matches is the OPERATOR'S
-- OWN, typed into the prompt buffer.
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
--- Three honest sources, any of which is enough, and ALL are things the NEXT
--- AGENT will actually receive:
---   * a LIVE upstream session (`--resume`): the agent has the history itself;
---   * a STAGED BRIEF carrying the previous instruction or artifact.
---   * a PACK SHARED CONTEXT block assembled from the panel's conversation
---     memory when entering an empty slot.
---
--- Under two_seat backends, an empty seat's first submit receives a seat-shared context
--- block from the panel's conversation memory, so that same memory is now a real link.
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

--- The toggle_mode cycle: config.modes, in list order. A mode missing from the
--- list is never offered.
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
