-- Turn-launch lifecycle (begin_turn and root resolution), split out of
-- shadow/preview.lua. Reached from the facade under the original names.
-- `deps.workspace` is the `preview_workspace.lua` instance the facade already
-- built; `deps.state_root`/`deps.enabled` are the facade's own functions,
-- passed in rather than required back (a load-time cycle).
local M = {}

local config = require("yana.config")
local diff = require("yana.diff")
local jail = require("yana.shadow.jail")
local ops = require("yana.shadow.ops")

function M.new(deps)
	local I = {}

-- Start a turn: resolve roots and return a daemon-backed session.
function I.begin_turn(opts)
	opts = opts or {}
	-- Finalize runs after the agent exits and may outlive this runtime path
	-- during a plugin update. Pin its applier now, while the turn's code is
	-- known to exist, so a later directory rename cannot strand the turn.
	require("yana.shadow.apply")
	if not deps.enabled() then
		return nil, "shadow mode disabled"
	end
	if not jail.available() then
		return nil, jail.OVERLAY_UNAVAILABLE_MSG
	end
	local turn_mode = config.resolve_mode(opts.mode or config.options.mode)

	local candidate = deps.workspace.workspace_candidate(opts)
	local flags = opts.single_file_flags or {}
	if flags.workspace and flags.workspace ~= "" then
		opts.workspace = flags.workspace
	end
	local workspace = diff.abs_path(opts.workspace or deps.workspace.workspace_for_turn(opts))
	local stream = opts.stream or "default"
	local turn_id = tostring(opts.turn_id or opts.turn_gen or "0")

	-- Declared roots are resolved BEFORE any per-turn state is created: a turn
	-- that cannot have the set it declared must not leave layer or turn state
	-- behind for the next one to trip over.
	local declared = opts.write_roots
	if declared == nil then
		declared = config.options.write_roots
	end
	local single_file_decision
	if not (flags.workspace and flags.workspace ~= "") then
		local single_file = require("yana.single_file")
		local decision, derr = single_file.decide({
			real_path = deps.workspace.buffer_real_path(opts),
			candidate_dir = candidate,
			flags = flags,
		})
		if derr then
			return nil, derr
		end
		if decision then
			if type(declared) == "table" and #declared > 0 then
				return nil, "single-file mode: declared write roots are not available"
			end
			local materialised, merr = single_file.materialise(decision, deps.state_root())
			if not materialised then
				return nil, merr
			end
			single_file_decision = decision
			workspace = materialised.workspace
			opts._single_file_materialised = materialised
			require("yana.log").lifecycle("single_file_mode", {
				trigger = decision.trigger,
				real_path = decision.real_path,
				scratch_ws = materialised.workspace,
				flag_lifetime = "next turn only",
			})
		end
	end

	-- THE BROAD ROOT IS CHOSEN BEFORE ANY PER-TURN STATE EXISTS, for the same
	-- reason the declared set is: a turn that cannot have the scope it was
	-- configured for must not leave a layer, a claim or a turn directory behind
	-- for the next one to trip over.
	local broad_root, broad_why
	if opts._single_file_materialised then
		broad_root = workspace
	else
		broad_root, broad_why = deps.workspace.broad_root_for(workspace, declared)
	end
	if not broad_root then
		return nil, broad_why
	end
	local root_paths, roots_err = deps.workspace.resolve_roots(workspace, declared)
	if not root_paths then
		return nil, roots_err
	end
	local opened_workspace = workspace
	local primary_workspace = root_paths[1] or workspace
	if primary_workspace ~= workspace then
		broad_root = primary_workspace
	end
	local turn_dir = deps.workspace.turn_dir(primary_workspace, stream, turn_id)
	local private_dir = turn_dir .. "/private"
	-- A panel-local turn id can be reused after an editor restart. Never let a
	-- same-id durable refusal from that earlier process authenticate this turn.
	pcall(vim.fn.delete, turn_dir .. "/refused", "rf")
	vim.fn.mkdir(private_dir, "p")
	deps.workspace.prune_refused_turns(vim.fn.fnamemodify(turn_dir, ":h"))

	local yanad_session_id = opts.yanad_session_id or opts.session_id
	local roots = {
		{
			index = 1,
			primary = true,
			workspace = primary_workspace,
			layer_dir = nil,
			upper_dir = nil,
			work_dir = nil,
		},
	}
	for i = 2, #root_paths do
		local root = root_paths[i]
		roots[#roots + 1] = {
			index = i,
			primary = false,
			workspace = root,
			layer_dir = nil,
			upper_dir = nil,
			work_dir = nil,
		}
	end

	local session = {
		workspace = primary_workspace,
		opened_workspace = opened_workspace,
		-- The ONE directory this turn's overlay is mounted at, and the base the finalize
		-- walk's primary relative paths are read against.
		broad_root = broad_root,
		stream = stream,
		session_id = opts.session_id,
		turn_id = turn_id,
		turn_gen = opts.turn_gen,
		turn_dir = turn_dir,
		private_dir = private_dir,
		layer_dir = nil,
		upper_dir = nil,
		yanad_session_id = yanad_session_id,
		mode = turn_mode,
		-- Under yanad, reclaim evidence comes from status, not disk holder files.
		reclaimed_from = nil,
		roots = roots,
		refused_bytes = 0,
		refused_retained = {},
	}
	if opts._single_file_materialised then
		session.single_file = {
			trigger = single_file_decision.trigger,
			real_path = single_file_decision.real_path,
			candidate_dir = single_file_decision.candidate_dir,
			workspace = workspace,
			copy_path = opts._single_file_materialised.copy_path,
			records = opts._single_file_materialised.records,
			map = opts._single_file_materialised.map,
			base = opts._single_file_materialised.base,
		}
	end
	local lifecycle = require("yana.turn_lifecycle")
	session.turn_pass = lifecycle.begin_turn({
		panel_id = opts.panel_id or 0,
		generation = opts.generation or opts.turn_gen or 0,
		stream = stream,
		turn_id = turn_id,
		workspace = opened_workspace,
	})
	return session, nil
end

--- Every root of a turn, whatever shape the session is in.
---
--- Sessions built by `begin_turn` carry `roots`; sessions built by hand -- the
--- headless rows and recovery paths that predate declared write roots do
--- exactly that -- carry only the aliases. Both answer here, so no caller has
--- to know which it holds.
function I.session_roots(session)
	return ops.session_roots(session)
end

	return I
end

return M
