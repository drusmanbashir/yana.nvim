-- Do not extend. Accept-from-shadow pass: diary + checkpoint are the only real-tree
-- writers.
local M = {}

local diary = require("yana.safety.diary")
local preview = require("yana.shadow.preview")
local diff = require("yana.diff")

M._test = {
	inject = {},
	fault = {},
}

-- Whether shadow-apply mode is currently turned on for this workspace.
function M.enabled()
	return preview.apply_enabled()
end

--- Path of `abs` relative to the turn workspace.
--- Returns nil when `abs` is outside the workspace, so a caller cannot silently
--- look up the wrong entry.
function M.workspace_rel(workspace, abs)
	if not workspace or not abs then
		return nil
	end
	local root = diff.abs_path(workspace)
	local target = diff.abs_path(abs)
	if target == root then
		return nil
	end
	local prefix = root:gsub("/$", "") .. "/"
	if target:sub(1, #prefix) ~= prefix then
		return nil
	end
	return target:sub(#prefix + 1)
end

local apply_claims = require("yana.shadow.apply_claims")

M.request_file_claim = apply_claims.request_file_claim

local apply_sessions = require("yana.shadow.apply_sessions")

M.check_files = apply_sessions.check_files
M.file_claim_refusal = apply_sessions.file_claim_refusal
M.opened_session = apply_sessions.opened_session

--- Start an accept pass for a completed shadow turn.
---
--- The pass does NOT open the durable journal.
---
--- So the pass carries the ARGUMENTS for the journal instead of the journal, and
--- `ensure_session` below opens it on the first operation that intends to change
--- durable state. A turn the operator rejects now never creates a diary directory at
--- all.
function M.begin_pass(shadow_turn, changes)
	if not M.enabled() then
		return nil, "apply mode disabled"
	end
	-- ONE JOURNAL PER ROOT, and the root is read off the change, never guessed.
	-- `safety/diary.lua` refuses a target outside its session's workspace ("path escapes
	-- workspace") and `safety/checkpoint.lua` refuses to capture one, which is exactly the
	-- boundary that makes a journal trustworthy. An extra root is a workspace in
	-- its own right, so it gets its own journal rooted at itself rather than a widened
	-- check on the workspace's.
	local primary = shadow_turn.workspace
	local paths = {}
	local paths_by_root = {}
	for _, change in ipairs(changes or {}) do
		if change.path then
			paths[#paths + 1] = change.path
			local root = (type(change.root) == "string" and change.root ~= "") and change.root or primary
			local list = paths_by_root[root]
			if not list then
				list = {}
				paths_by_root[root] = list
			end
			list[#list + 1] = change.path
		end
	end
	local pass = {
		shadow_turn = shadow_turn,
		diary_begin = {
			workspace = primary,
			stream = shadow_turn.stream,
		},
		turn_id = tostring(shadow_turn.turn_id),
		paths = paths,
		paths_by_root = paths_by_root,
		checkpoint_started = false,
	}
	return pass, nil
end

local apply_accept = require("yana.shadow.apply_accept")

-- Same table object as this facade's own `_test`: a fault or inject a
-- caller sets through `apply._test` must be the one
-- `apply_accept.reconcile_applied_buffer` reads.
apply_accept._test = M._test

M.reconcile_applied_buffer = apply_accept.reconcile_applied_buffer
M.accept_composed = apply_accept.accept_composed

--- The panel-local journal a standalone accept or scope revert writes through.
---
--- Primary-root changes keep `panel._standalone_diary`, opened at the review
--- workspace exactly as before. A change from an extra root cannot be
--- journalled there -- the diary refuses a target outside its own workspace --
--- so it gets its own panel-local journal rooted at that root, kept beside the
--- first one and reused for every later change from the same root.
local function standalone_session(panel, change, label)
	local primary_root = change and change.root_is_primary ~= false
	if primary_root then
		if not panel._standalone_diary then
			local ws = change.review_workspace or panel.cwd or vim.fn.getcwd()
			local session, err = diary.begin({
				workspace = ws,
				stream = panel.session_id or ("panel-" .. tostring(panel.id or label)),
			})
			if not session then
				return nil, err
			end
			panel._standalone_diary = session
		end
		return panel._standalone_diary
	end
	panel._standalone_diary_roots = panel._standalone_diary_roots or {}
	local root = change.root
	if panel._standalone_diary_roots[root] then
		return panel._standalone_diary_roots[root]
	end
	local session, err = diary.begin({
		workspace = root,
		stream = panel.session_id or ("panel-" .. tostring(panel.id or label)),
	})
	if not session then
		return nil, err
	end
	panel._standalone_diary_roots[root] = session
	return session
end

--- Journaled accept when no apply-mode shadow_pass exists (preview-mode inline
--- review). Checkpoint is omitted: preview turns discard the overlay without a
--- pass, but a real-tree accept during review still routes through the diary.
--- The standalone route consumes the SAME explicit `{action, bytes, mode,
--- purpose}` record as the pass route, takes the same
--- preflight, and reaches disk through the same `apply_accept.commit`. It has
--- no transfer-only shortcut and it never reads `change.kind` or
--- `change.after_mode` to decide what to do.
function M.accept_standalone(panel, change, composed, opts)
	if not panel then
		return false, "no panel"
	end
	local plan, perr = apply_accept.write_plan(change, composed, opts)
	if not plan then
		return false, perr
	end
	-- The same accept-step pairing as `accept_composed`, on the preview-mode
	-- route that has no apply pass. Pass the panel: file_claim_refusal(nil)
	-- drops yanad_session_id and fails closed with "yanad session_id missing".
	local ok, err = apply_accept.accept_preflight(panel, change)
	if not ok then
		return false, err
	end
	if plan.action == "none" then
		-- Nothing is owed, so no journal is opened: a pass that writes nothing
		-- must not leave a diary directory behind.
		return apply_accept.commit(nil, change, plan, opts and opts.own_splice)
	end
	-- A change from an extra root journals at THAT root: the diary's
	-- own "path escapes workspace" refusal is a boundary worth keeping, so the
	-- root becomes the journal's workspace rather than the check being widened.
	-- A primary-root change keeps the panel journal it has always used.
	local session, serr = standalone_session(panel, change, "inline")
	if not session then
		return false, serr
	end
	return apply_accept.commit(session, change, plan, opts and opts.own_splice)
end

--- Put ONE path back to the bytes the turn started from, through the journaled applier.
--- That is permitted by the ruling, but it is still a write, so it goes through the
--- diary like every other one: intent row, displaced copy, verification, and something
--- for crash recovery to work from.
---
--- `base_hash` is deliberately NOT passed. The accept moved the file, so the pre-turn
--- fingerprint is exactly what disk must NOT be expected to hold;
--- `diary.restore_workspace_bytes` observes the CURRENT state instead and displaces it,
--- which is what makes this undo reversible in its turn. Put ONE path back to bytes the
--- CALLER names, through the same journaled applier `revert_to_turn_start` uses -- with
--- the caller's content instead of `change.before`.
---
--- When `cA` ABSORBED an operator edit on a queued file, the bytes that were on disk
--- the instant before `cA` wrote are NOT the turn-start bytes: they are turn-start plus
--- the operator's own edit. Taking `cA`'s step back owes them exactly that disk state,
--- because the edit was never part of the step. Reverting to turn-start there destroys
--- an edit the operator made themselves.
---
--- `base_hash` is deliberately NOT passed, for the same reason
--- `revert_to_turn_start` does not pass it: the accept moved the file, so the
--- pre-accept fingerprint is exactly what disk must NOT be expected to hold.
function M.revert_to_bytes(panel, change, content)
	if not panel or not change or not change.path then
		return false, "revert needs a panel and a path"
	end
	if type(content) ~= "string" then
		return false, "revert_to_bytes needs the bytes to restore"
	end
	local session, serr
	local pass = panel.shadow_pass
	if pass then
		session, serr = apply_sessions.session_for_root(pass, apply_sessions.change_root(pass, change))
	else
		session, serr = standalone_session(panel, change, "undo_accept_turn_step")
	end
	if not session then
		return false, serr
	end
	return diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = content,
		target_mode = change.base_mode,
	})
end

function M.revert_to_turn_start(panel, change)
	if not panel or not change or not change.path then
		return false, "revert needs a panel and a path"
	end
	local session, serr
	local pass = panel.shadow_pass
	if pass then
		session, serr = apply_sessions.session_for_root(pass, apply_sessions.change_root(pass, change))
	else
		session, serr = standalone_session(panel, change, "undo_turn")
	end
	if not session then
		return false, serr
	end
	local content = change.before
	if content == nil then
		-- The turn-start DISK state of a created file is now the EMPTY FILE: `change.before
		-- == nil` is the creation MARKER ONLY, the BYTE baseline is `""`. Removing it here
		-- would merge hunk-undo and file-removal into one press -- the merge the operator
		-- refused -- and reverse a touch `U` never took part in.
		content = ""
	end
	return diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = content,
		target_mode = change.base_mode,
	})
end

-- Decode every row of the journals this pass has already opened.
function M.journal_rows(pass)
	local sessions = apply_sessions.opened_sessions(pass)
	if #sessions == 0 then
		-- No accept has happened on this pass, so no journal exists. Reading it
		-- must not open one: introspection is not an action.
		return {}
	end
	local rows = {}
	for _, session in ipairs(sessions) do
		local path = session.diary_dir .. "/journal.jsonl"
		if vim.fn.filereadable(path) == 1 then
			for _, line in ipairs(vim.fn.readfile(path)) do
				if line ~= "" then
					rows[#rows + 1] = vim.json.decode(line)
				end
			end
		end
	end
	return rows
end

return M
