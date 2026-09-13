-- Do not extend. Accept-from-shadow pass: diary + checkpoint are the only real-tree
-- writers.
local M = {}

local diary = require("yana.safety.diary")
local checkpoint = require("yana.safety.checkpoint")
local preview = require("yana.shadow.preview")
local diff = require("yana.diff")
local log = require("yana.log")
local hash = require("yana.safety.hash")

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
	-- boundary that makes a journal trustworthy. A declared write root is a workspace in
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
M.single_file_accept_refusal = apply_accept.single_file_accept_refusal
M.accept_transfer = apply_accept.accept_transfer
M.accept_apply = apply_accept.accept_apply
M.accept_composed = apply_accept.accept_composed

--- The panel-local journal a standalone accept or scope revert writes through.
---
--- Primary-root changes keep `panel._standalone_diary`, opened at the review
--- workspace exactly as before. A change from a declared write root cannot be
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
function M.accept_standalone(panel, change, composed, opts)
	if not panel then
		return false, "no panel"
	end
	opts = opts or {}
	local staged_bufnr = opts.staged_bufnr
	if change and change.single_file then
		local refusal = M.single_file_accept_refusal(change, staged_bufnr)
		if refusal then
			return false, refusal
		end
		return M.accept_transfer(panel, change, composed, staged_bufnr)
	end
	if apply_accept.valid_loaded_buffer(staged_bufnr) then
		local live = diff.buffer_bytes_snapshot(staged_bufnr)
		-- A created file is an ordinary file.
		if live == composed and change and change.kind ~= "delete" and not apply_accept.mode_delta(change) then
			return M.accept_transfer(panel, change, composed, staged_bufnr)
		end
		if live ~= composed then
			log.write(
				log.levels.WARN,
				"yana: staged buffer mismatch for " .. tostring(change and change.path or "?") .. " -- written at accept"
			)
		elseif apply_accept.mode_delta(change) then
			log.write(log.levels.WARN, "yana: mode change — written at accept (trash gate pending)")
		end
	end
	if change.base_hash == nil then
		return false,
			"refusing to accept "
				.. tostring(change.path)
				.. ": the change set carries no before-fingerprint for it, so drift cannot be judged"
	end

	-- The same accept-step pairing as `accept_composed`, on the preview-mode
	-- route that has no apply pass. Pass the panel: file_claim_refusal(nil)
	-- drops yanad_session_id and fails closed with "yanad session_id missing".
	local standalone_claim_refusal = M.file_claim_refusal(panel, change)
	if standalone_claim_refusal then
		return false, standalone_claim_refusal
	end
	-- A change from a declared write root journals at THAT root: the diary's
	-- own "path escapes workspace" refusal is a boundary worth keeping, so the
	-- root becomes the journal's workspace rather than the check being widened.
	-- A primary-root change keeps the panel journal it has always used.
	local session, serr = standalone_session(panel, change, "inline")
	if not session then
		return false, serr
	end
	local is_delete = change.kind == "delete"
	local predicted_op_id = string.format("%s:%d", session.stream, (session.op_seq or 0) + 1)
	local ok, err = diary.intent({
		session = session,
		path = change.path,
		target = is_delete and "" or (composed or ""),
		op_kind = is_delete and "delete" or "replace",
		base_hash = change.base_hash,
		-- WHEN that fingerprint was captured, same reason as accept_apply above.
		base_hash_captured_ts = change.base_hash_captured_ts,
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
		target_mode = change.after_mode,
		record_only = true,
	})
	if not ok then
		return false, err
	end
	local detail
	ok, err, detail = diary.apply_pending({
		session = session,
		path = change.path,
	})
	if not ok then
		if type(detail) == "table" then
			change.shadow_refusal = detail
		end
		return false, err
	end
	local uv = vim.uv or vim.loop
	local applied = {
		path = change.path,
		kind = is_delete and "delete" or "replace",
		stat = (not is_delete) and uv.fs_stat(change.path) or nil,
		diary_dir = session.diary_dir,
		op_id = predicted_op_id,
		base_hash = change.base_hash,
		target_hash = hash.hash_bytes(is_delete and "" or (composed or "")),
	}
	local rok, rerr = M.reconcile_applied_buffer(applied)
	if not rok then
		applied.reconcile_error = rerr
	end
	return true, nil, applied
end

--- Scope-revert an out-of-zone edit through the journaled applier.
function M.scope_revert(panel, change)
	if not panel or not change or not change.path or change.before == nil then
		return false, "scope revert requires a before snapshot"
	end
	local session, serr = standalone_session(panel, change, "scope")
	if not session then
		return false, serr
	end
	return diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = change.before,
		base_hash = change.base_hash,
		base_hash_captured_ts = change.base_hash_captured_ts,
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
	})
end

-- `M.restore_staged_removal`, the redo half, went with them: it was reachable only
-- through the `change._undo_staged` note `stage_and_remove` was the sole writer of. The
-- file is removed by ONE press and one only -- the last `u`, walking the `file_touch`
-- register row (lua/yana/review_undo.lua).

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

-- Revert every root's checkpoint this pass opened, restoring pre-turn state.
function M.revert_pass(pass)
	-- A pass with no journal has nothing captured and nothing to put back.
	if not pass or not pass.diary_session then
		return true
	end
	-- Every root that opened a journal is reverted, not just the workspace's: a
	-- turn that wrote into two roots and is reverted must put both back. Each
	-- root's checkpoint is its own durable artefact under its own diary
	-- directory, and the same "the artefact decides" rule applies to each.
	for _, session in pairs(pass.diary_sessions or {}) do
		if vim.fn.filereadable(checkpoint.manifest_path(session, pass.turn_id)) == 1 then
			local ok, err = checkpoint.revert_turn({ session = session, turn_id = pass.turn_id })
			if not ok then
				return ok, err
			end
		end
	end
	-- NOT `pass.checkpoint_started`: that boolean is process-local state on the pass
	-- OBJECT, and a retried or resumed pass is a new object over the same diary directory
	-- and turn id. Reading it there would answer "no checkpoint" for a checkpoint that is
	-- on disk, and this function would return `true` — a whole-turn revert reporting
	-- success having restored nothing, which is the same silent shape
	-- `checkpoint.begin_turn`'s guard exists to stop. The durable artefact decides.
	if vim.fn.filereadable(checkpoint.manifest_path(pass.diary_session, pass.turn_id)) ~= 1 then
		return true
	end
	return checkpoint.revert_turn({
		session = pass.diary_session,
		turn_id = pass.turn_id,
	})
end

-- Discard the shadow turn's preview state now this pass has finished.
function M.finish_pass(pass)
	if pass and pass.shadow_turn then
		preview.discard(pass.shadow_turn)
	end
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

-- Read a path's real on-disk bytes.
function M.read_real_bytes(path)
	return diff.read_file_bytes(path)
end

return M
