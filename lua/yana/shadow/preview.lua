-- Preview mode turn lifecycle: jailed agent → typed op report → discard.
--
-- There is no snapshot step. CORE, "No whole-repository work": the overlay
-- lower layer IS the before-picture, so copying the workspace at turn start
-- re-derived information the kernel already held. Starting a turn now costs
-- three mkdirs regardless of how large the repository is.
local M = {}

local config = require("yana.config")
local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local manifest = require("yana.paths.manifest")
local ops = require("yana.shadow.ops")
local uv = vim.uv or vim.loop

local REFUSED_MAX_FILE_BYTES = 8 * 1024 * 1024
local REFUSED_MAX_TURN_BYTES = 64 * 1024 * 1024
local REFUSED_KEEP_TURNS = 5
local REFUSED_KEEP_SECONDS = 7 * 24 * 60 * 60

M.REFUSED_LIMITS = {
	file_bytes = REFUSED_MAX_FILE_BYTES,
	turn_bytes = REFUSED_MAX_TURN_BYTES,
	turns = REFUSED_KEEP_TURNS,
	seconds = REFUSED_KEEP_SECONDS,
}

M._config = {
	state_root = vim.fn.expand("~/.local/state/yana"),
}

M._test = {
	force_state_root = nil,
}

--- Where per-turn state lives. Matches `bin/yana-turn`'s `$STATE_ROOT`, so
--- a claim taken by the editor and one taken by the CLI collide as they should.
---
--- Precedence, byte-compatible with bin/yana-turn's shell resolver: YANA_STATE_ROOT,
--- then XDG_STATE_HOME/yana, then $HOME/.local/state/yana. A host with a
--- writable XDG_STATE_HOME but a read-only/minimal $HOME must still land the
--- editor on the same directory as the CLI.
function M.state_root()
	if M._test.force_state_root then
		return M._test.force_state_root
	end
	local env = vim.env.YANA_STATE_ROOT
	if env and env ~= "" then
		return env
	end
	local xdg = vim.env.XDG_STATE_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/yana"
	end
	return M._config.state_root
end

-- True when overlay capture (preview or apply) is turned on.
function M.enabled()
	local mode = config.overlay_mode() and "apply" or "off"
	return mode == "preview" or mode == "apply"
end

-- True when review mode (auto-apply) is currently active.
function M.apply_enabled()
	return config.review_mode_active()
end

-- Current overlay mode: "apply" when enabled, else "off".
function M.mode()
	return config.overlay_mode() and "apply" or "off"
end

-- Workspace/root resolution and on-disk pruning helpers. Exposed here so
-- `preview_turn.lua`/`preview_settle.lua`/`preview_claims.lua` can reach the
-- same instance without requiring this facade back (a load-time cycle).
local preview_workspace = require("yana.shadow.preview_workspace").new({
	state_root = M.state_root,
	limits = M.REFUSED_LIMITS,
})

M.resolve_workspace = preview_workspace.resolve_workspace
M.workspace_for_turn = preview_workspace.workspace_for_turn
M.layer_dir = preview_workspace.layer_dir
M.turn_dir = preview_workspace.turn_dir
M.resolve_roots = preview_workspace.resolve_roots
M.broad_root_for = preview_workspace.broad_root_for

-- Turn-launch lifecycle.
local preview_turn = require("yana.shadow.preview_turn").new({
	state_root = M.state_root,
	enabled = M.enabled,
	workspace = preview_workspace,
})

M.begin_turn = preview_turn.begin_turn
M.session_roots = preview_turn.session_roots

-- Refusal-retention, layer recovery, and claim release.
local preview_settle = require("yana.shadow.preview_settle").new({
	state_root = M.state_root,
	limits = M.REFUSED_LIMITS,
	workspace = preview_workspace,
	turn = preview_turn,
})

M.stage_undo_removal = preview_settle.stage_undo_removal
M.retain_system_refused = preview_settle.retain_system_refused
M.retain_refusal_group = preview_settle.retain_refusal_group
M.recover_layer = preview_settle.recover_layer
M.arm_review_open = preview_settle.arm_review_open
M.release = preview_settle.release

-- Build the typed ops report and formatted lines for this turn.
function M.end_turn(session)
	if not session then
		return nil, "no preview session"
	end
	local report_ops, err = ops.typed_ops_from_session(session)
	if not report_ops then
		return nil, err
	end
	return {
		ops = report_ops,
		lines = ops.format_lines(report_ops),
	}, nil
end

--- Drop everything this turn created. There is no snapshot tree to remove:
--- the only per-turn state is the overlay layer and the private scratch, both
--- of which are O(what the agent wrote).
function M.discard(session)
	if not session then
		return true
	end
	-- Its async review.close must observe the turn after this callback returns.
	if session.yanad_session_id then
		return true
	end
	local keep_private = false
	local ok_record, record = pcall(require, "yana.record")
	if ok_record and record.enabled() then
		keep_private = true
	end
	if session.private_dir and not keep_private then
		pcall(vim.fn.delete, session.private_dir, "rf")
	end
	if not session.preserve_layer then
		-- Every root's layer, not just the workspace's: a turn that wrote into a
		-- declared root and was discarded must leave nothing of that root's
		-- proposal behind either.
		for _, root in ipairs(M.session_roots(session)) do
			if root.layer_dir then
				pcall(vim.fn.delete, root.layer_dir, "rf")
			end
		end
	end
	local keep_refused = session.turn_dir
		and vim.fn.isdirectory(session.turn_dir .. "/refused") == 1
	if session.turn_dir and not keep_private and not keep_refused then
		pcall(vim.fn.delete, session.turn_dir, "rf")
	end
	return true
end

-- Append this turn's report lines into the panel's conversation buffer.
function M.render_report(panel, session)
	local report, err = M.end_turn(session)
	if not report then
		return false, err
	end
	if panel and panel.conv_buf and vim.api.nvim_buf_is_valid(panel.conv_buf) then
		local buf = panel.conv_buf
		local lines = report.lines
		local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local was_modifiable = vim.bo[buf].modifiable
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, #cur, #cur, false, lines)
		vim.bo[buf].modifiable = was_modifiable
	end
	return true, report
end

return M
