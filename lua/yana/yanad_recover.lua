-- Rebuild one daemon-kept review after editor death.
local M = {}

local uv = vim.uv or vim.loop
local request_seq = 0

local function log_pruned(fields)
	require("yana.log").lifecycle("recovery.pruned", fields)
end

--- After a refuse or discovery prune: one DEBUG lifecycle line, then delete.
function M.prune_after_refuse(session_id, recovery, path)
	log_pruned({
		path = path,
		turn_id = recovery and recovery.turn_id or nil,
		reason = "base_hash_mismatch",
		session_id = session_id,
	})
	if type(session_id) ~= "string" or session_id == "" then
		return
	end
	request_seq = request_seq + 1
	local request_id = string.format("recovery:prune:%d:%d", vim.fn.getpid(), request_seq)
	pcall(function()
		local yanad = require("yana.yanad")
		if type(yanad.session_delete) == "function" then
			yanad.session_delete({ session_id = session_id }, request_id, function() end)
		end
	end)
end

--- Log daemon status.pruned rows (discovery-time silent deletes).
function M.note_discovery_prunes(pruned)
	for _, row in ipairs(pruned or {}) do
		if type(row) == "table" then
			log_pruned({
				path = row.path,
				turn_id = row.turn_id,
				reason = row.reason or "base_hash_mismatch",
				session_id = row.session_id,
			})
		end
	end
end

local function inside(root, path)
	local real_root = type(root) == "string" and uv.fs_realpath(root) or nil
	local real_path = type(path) == "string" and uv.fs_realpath(path) or nil
	return real_root ~= nil
		and real_path ~= nil
		and (real_path == real_root or real_path:sub(1, #real_root + 1) == real_root .. "/")
end

local function current_base(row)
	local st = uv.fs_lstat(row.path)
	if row.base_state == "absent" then
		if st ~= nil then
			return nil, "base hash mismatch: expected absent path " .. tostring(row.path)
		end
		return nil
	end
	if row.base_state ~= "file" or not st or st.type ~= "file" then
		return nil, "base hash mismatch: expected file " .. tostring(row.path)
	end
	local before, err = require("yana.diff").read_file_bytes(row.path)
	if before == nil then
		return nil, "base hash unreadable for " .. tostring(row.path) .. ": " .. tostring(err)
	end
	local actual = require("yana.safety.hash").hash_bytes(before)
	if actual ~= row.base_hash then
		return nil, "base hash mismatch for " .. tostring(row.path)
	end
	return before
end

local function build_changes(recovery)
	if type(recovery) ~= "table" or type(recovery.turn_dir) ~= "string"
		or type(recovery.bundle) ~= "table" or #recovery.bundle == 0 then
		return nil, "daemon recovery manifest is missing"
	end
	local changes = {}
	for _, row in ipairs(recovery.bundle) do
		if type(row) ~= "table" or type(row.path) ~= "string" or type(row.base_hash) ~= "string" then
			return nil, "daemon recovery bundle is invalid"
		end
		-- A mode the daemon never recorded must arrive as an ABSENT key, never as
		-- a sentinel: `yanad.lua` decodes JSON null to Lua nil so `vim.NIL`
		-- (userdata, and truthy) cannot reach `mode_perm`'s `% 4096` three modules
		-- downstream. Refuse the bundle HERE, where it enters recovery and can
		-- still be named, rather than crash mid-paint with the review half-built.
		for _, key in ipairs({ "base_mode", "after_mode" }) do
			if row[key] ~= nil and type(row[key]) ~= "number" then
				return nil, string.format(
					"daemon recovery bundle has a non-numeric %s (%s) for %s",
					key, type(row[key]), row.path
				)
			end
		end
		local before, base_err = current_base(row)
		if base_err then
			return nil, base_err
		end
		local after
		if row.kind ~= "delete" then
			if not inside(recovery.turn_dir, row.upper_path) then
				return nil, "daemon recovery proposal escaped its turn directory"
			end
			after = require("yana.diff").read_file_bytes(row.upper_path)
			if after == nil then
				return nil, "daemon recovery proposal is unreadable: " .. tostring(row.upper_path)
			end
		end
		changes[#changes + 1] = vim.tbl_extend("force", {}, row, {
			before = before,
			after = after,
			shadow_apply = true,
			status = "pending",
			review_workspace = row.root,
		})
	end
	return changes
end

function M.recover(session_id, deps, done)
	deps = deps or {}
	done = done or function() end
	local panel = deps.panel
	if not panel or not session_id or session_id == "" then
		done(false, "recovery needs a session and panel")
		return false
	end
	local panel_id = panel.id
	request_seq = request_seq + 1
	local request_id = string.format("recovery:attach:%d:%d", vim.fn.getpid(), request_seq)
	-- THE PANEL IS PENDING FOR THE WHOLE ATTACH. Without this a submit landing
	-- during the in-flight attach read the panel as "answered and failed" and
	-- CREATED a second daemon session for one conversation (ui_submit's retry
	-- branch); the attach answer then overwrote the id below and the created
	-- session was left ownerless. Pending is exactly what the submit needs to
	-- see: it parks the turn instead, and this callback fires it.
	panel.yanad_session_pending = true
	-- The kept session is what this panel is FOR, so its retry door re-ATTACHES
	-- rather than creating. Only a panel with no kept session at all keeps the
	-- create door ui_panel_lifecycle's create_panel installed.
	panel.yanad_start_session = function(p)
		M.recover(session_id, deps, done)
		return p
	end
	local function settle(err)
		panel.yanad_session_pending = false
		panel.yanad_session_err = err
	end
	require("yana.yanad").session_attach({ session_id = session_id }, request_id, function(ok, result)
		if deps.current_panel and (deps.current_panel() ~= panel or panel.id ~= panel_id) then
			-- Not this panel's answer any more; leave its flags to whoever owns it now.
			done(false, "stale recovery callback")
			return
		end
		if not ok or type(result) ~= "table" then
			local msg = "yana: recovery attach failed: " .. tostring(result)
			settle(tostring(result))
			if deps.notify then deps.notify(msg, vim.log.levels.ERROR) end
			done(false, msg)
			return
		end
		local recovery = result.recovery
		-- O8 / ruling: the daemon's own meta is the only record of what the
		-- turn was permitted to do. Never guess "edit" — a mode-less record
		-- is a confinement fault and must be refused by name.
		if type(recovery) ~= "table" or type(recovery.mode) ~= "string" or recovery.mode == "" then
			local msg = "yana: recovery refused: turn mode missing from daemon recovery record"
			settle("recovery record has no turn mode")
			if deps.notify then deps.notify(msg, vim.log.levels.ERROR) end
			done(false, msg)
			return
		end
		local changes, err = build_changes(recovery)
		if not changes then
			local msg = "yana: recovery refused: " .. tostring(err)
			settle(tostring(err))
			if deps.notify then deps.notify(msg, vim.log.levels.ERROR) end
			-- Race window: valid at discovery, stale at accept. No second dialog.
			if type(err) == "string" and err:find("base hash", 1, true) then
				local path = err:match("for (.+)$") or err:match("path (.+)$")
				M.prune_after_refuse(session_id, recovery, path)
			end
			done(false, msg)
			return
		end
		local turn = {
			workspace = result.workspace,
			turn_id = recovery.turn_id,
			turn_gen = recovery.turn_id,
			turn_dir = recovery.turn_dir,
			mounted_root = recovery.mounted_root,
			roots = recovery.roots or {},
			layers = recovery.layers,
			review_files = recovery.files or {},
			review_tabs = recovery.tabs or {},
			review_bundle = recovery.bundle,
			yanad_session_id = session_id,
			mode = recovery.mode,
		}
		panel.yanad_session_id = session_id
		panel.yanad_session_pending = false
		panel.yanad_session_err = nil
		panel.shadow_turn = turn
		panel.changes = panel.changes or {}
		for _, change in ipairs(changes) do
			change.turn_id = recovery.turn_id
			change.turn_gen = recovery.turn_id
			change.panel_id = panel.id
			change.yanad_session_id = session_id
			table.insert(panel.changes, change)
			if deps.render_change then
				local rendered, render_err = pcall(deps.render_change, panel, change)
				if not rendered then
					done(false, "recovery render failed: " .. tostring(render_err))
					return
				end
			end
			local opts = deps.inline_review_opts and deps.inline_review_opts(panel, change) or {}
			local called, opened, open_err = pcall(require("yana.inline_diff").review, change, opts)
			if not called or opened == false then
				done(false, open_err or opened or "inline review refused")
				return
			end
		end
		-- The attach succeeded and the id is seated, so a turn parked by a
		-- submit made while it was in flight is spendable now. Same one
		-- consumer the create path uses (ui_panel_lifecycle's fire_parked_turn,
		-- installed on the panel), so the clear-before-fire invariant holds
		-- across both doors.
		-- Unguarded: every panel gets this door in create_panel, and a panel
		-- without one is a construction bug that must be seen.
		panel.yanad_fire_parked_turn(panel)
		done(true, result)
	end)
	return true
end

return M
