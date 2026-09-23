-- :YanaRoots controller. State, projection, and filesystem walk live in roots/.
local config = require("yana.config")
local grid = require("yana.panel.ui_grid")
local model = require("yana.roots.model")
local view = require("yana.roots.view")
local notify = require("yana.notify")
local persisted = require("yana.runtime.persisted_state")
local uv = vim.uv or vim.loop

local M = {}
local active, raised_empty_once = nil, false
local LEFT, RIGHT = "navigation", "capture set"
local DISCLOSURE = {
	"Folder added here is writable by turns from EVERY project.",
	"setup{ write_roots = {...} } remains the hand-authored default; this list is saved in Yana state.",
	"Space add/remove · m mark · Del remove marked/cursor · Right expand · Left/Backspace up · Tab switch · Enter save · Escape cancel",
}

local function copy(value) return vim.deepcopy(value) end

local function state_root_abs()
	local raw = require("yana.shadow.preview").state_root()
	return uv.fs_realpath(raw) or vim.fn.fnamemodify(raw, ":p")
end

local function abs_path(path)
	if not path or path == "" then return nil end
	local expanded = vim.fn.expand(path)
	return uv.fs_realpath(expanded) or vim.fn.fnamemodify(expanded, ":p")
end

local function contains(root, path)
	return root and path and (path == root or path:sub(1, #root + 1) == root .. "/")
end

local function refuse(msg) notify.one_line(msg, vim.log.levels.WARN) end
local function refuse_in_dialog(msg) vim.notify(notify.flatten(msg), vim.log.levels.WARN) end

local function validate_dir(path)
	local real = abs_path(path)
	if not real then return nil, string.format("yana: refused '%s' — path does not exist", tostring(path)) end
	if vim.fn.isdirectory(real) ~= 1 then return nil, string.format("yana: refused '%s' — not a directory", real) end
	local state = state_root_abs()
	if contains(state, real) or contains(real, state) then
		return nil, string.format("yana: refused '%s' — resolves inside yana's state root (%s)", real, state)
	end
	return real
end

local function commit_roots(roots)
	config.options.write_roots = config.normalize_write_roots(roots)
	persisted.save_write_roots(config.options)
end

local function fs_for(home)
	local function scandir(dir)
		local result, handle = {}, uv.fs_scandir(dir)
		if not handle then return result end
		while true do
			local name, typ = uv.fs_scandir_next(handle)
			if not name then break end
			result[#result + 1] = { name = name, path = dir .. "/" .. name, type = typ }
		end
		return result
	end
	local function walk(root, opts, done)
		local token = opts.token
		local queue, result, count = { { path = root, depth = 0 } }, {}, 0
		local truncated = false
		local function step()
			if token.cancelled then return end
			local item = table.remove(queue, 1)
			if not item then return done(result, truncated) end
			uv.fs_scandir(item.path, function(err, handle)
				if token.cancelled then return end
				if not err and handle then
					while true do
						local name, typ = uv.fs_scandir_next(handle)
						if not name then break end
						if name:sub(1, 1) ~= "." and name ~= "node_modules" and (typ == "directory" or typ == "link") then
							local path = item.path .. "/" .. name
							if vim.fn.isdirectory(path) == 1 then
								if count >= opts.max_results then truncated = true; break end
								count = count + 1
								result[#result + 1] = { path = uv.fs_realpath(path) or path, name = name, depth = item.depth + 1 }
								if item.depth + 1 < opts.max_depth then queue[#queue + 1] = { path = path, depth = item.depth + 1 } end
							end
						end
					end
				end
				step()
			end)
		end
		step()
		return { cancel = function() token.cancelled = true end }
	end
	return { scandir = scandir, isdir = function(path) return vim.fn.isdirectory(path) == 1 end, realpath = uv.fs_realpath, walk = walk }
end

local function refresh(state)
	if state and not state.done then state.grid:refresh({ place_cursor = true }) end
end

local function left_rows(state)
	local rows = model.rows(state.model)
	state.data_rows = math.max(1, math.max(#rows, #state.model.draft))
	return rows
end

local function focused_left(state)
	return left_rows(state)[state.active_row]
end

local function add_left(state)
	local item = focused_left(state)
	if not item then return refuse_in_dialog("yana: highlight a directory to add") end
	local value, err = model.add(state.model, item.path)
	if not value then return refuse_in_dialog("yana: refused '" .. tostring(item.path) .. "' — " .. err) end
	refresh(state)
end

local function remove_right(state, span)
	if state.active_col ~= RIGHT then return end
	local path = span and span.value or state.model.draft[state.active_row]
	if path then model.remove(state.model, path); refresh(state) end
end

local function remove_marked_or_cursor(state, span)
	if state.active_col ~= RIGHT then return end
	local targets = copy(state.model.marked)
	if next(targets) == nil and span and span.value then targets[span.value] = true end
	for path in pairs(targets) do model.remove(state.model, path) end
	state.active_row = math.min(math.max(1, state.active_row), math.max(1, #state.model.draft))
	refresh(state)
end

local function close_dialog(state, apply)
	if not state or state.done then return end
	state.done = true
	model.cancel_search(state.model)
	if apply then
		commit_roots(model.commit_list(state.model))
		notify.one_line(string.format("yana: capture set now has %d root(s)", #state.model.draft), vim.log.levels.INFO)
	end
	if state.grid and not state.grid.closed then state.grid:close(false) end
	if active == state then active = nil end
	if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then pcall(vim.api.nvim_set_current_win, state.origin_win) end
end

local function on_key(g, key)
	local state = g.state
	if state.active_col == LEFT then
		local item = focused_left(state)
		if key == "<Right>" then
			if item and item.has_children and not item.expanded then
				local expanded = model.toggle(state.model, item.path)
				state.cwd, state.reveal_row = item.path, expanded and state.active_row or nil
			end
			refresh(state); state.reveal_row = nil; return true
		end
		if key == "<Left>" then
			if item then state.cwd = model.collapse(state.model, item.path) end
			refresh(state); return true
		end
		if #key == 1 and key ~= " " and not key:match("[%c]") then
			model.set_filter(state.model, state.model.filter .. key); state.active_row = 1
			refresh(state); return true
		end
	end
	return false
end

local function on_back(g)
	local state = g.state
	if state.active_col == LEFT and state.model.filter ~= "" then
		model.set_filter(state.model, state.model.filter:sub(1, -2)); state.active_row = 1; refresh(state); return
	end
	if state.active_col == LEFT then
		local item = focused_left(state)
		if item then state.cwd = model.collapse(state.model, item.path) end
		refresh(state); return
	end
	state.active_col, state.active_col_i, state.active_row = LEFT, 1, 1
	refresh(state)
end

function M.open()
	if active and not active.done then return end
	local home = config.home_dir()
	local state = {
		origin_win = vim.api.nvim_get_current_win(), active_col = LEFT, active_col_i = 1, active_row = 1,
		cwd = home, done = false,
		model = model.new({ home = home, fs = fs_for(home), draft = config.options.write_roots or {}, state_root = state_root_abs() }),
	}
	state.model.on_search = function()
		vim.schedule(function() if not state.done then refresh(state) end end)
	end
	active = state
	local width = math.min(110, math.max(72, vim.o.columns - 8))
	local height = math.min(30, math.max(16, math.floor(vim.o.lines * 0.7)))
	state.grid = grid.open({
		state = state, layout = "columns", columns = view.labels(), type_to_filter = true, reserved_keys = {},
		width = width, height = height, max_height = height, fixed_size = true,
		column_widths = function(inner)
			local left = math.floor((inner - 1) / 2)
			return { left, inner - 1 - left }
		end,
		column_separator = { vertical = "│", junction = "┼" }, scroll_data = true, header_lines = 2, wrap_legend = true,
		global_mouse = true, focus_guard = true, window_title = " Capture set ", title_pos = "center",
		title = function() return view.title(state.model, width) end, legend = table.concat(DISCLOSURE, "  "), rule_char = "─", pin_legend = true,
		cells = function() state.model.active_col, state.model.active_row = state.active_col, state.active_row; return view.cells(state.model) end,
		row_count = function(s) return s.data_rows or 1 end,
		column_count = function(s, col) return col == LEFT and #model.rows(s.model) or #s.model.draft end,
		on_key = on_key, on_back = on_back,
		on_space = function(_, span) if span and span.col == LEFT then add_left(state) elseif span then remove_right(state, span) end end,
		on_mark = function(_, span) if span and span.col == RIGHT then model.mark(state.model, span.value) end end,
		on_delete = function(_, span) remove_marked_or_cursor(state, span) end,
		on_enter = function() close_dialog(state, true) end, on_cancel = function() close_dialog(state, false) end,
		hl_groups = { live = "YanaReviewBtnText", current = "YanaReviewBtnKey", flash = "YanaReviewBtnFlash", marked = "YanaReviewBtnMarked", hover = "YanaReviewBtnHover", key = "YanaReviewBtnKey", dim = "YanaReviewBtnDim" },
	})
end

function M.is_open() return active ~= nil and not active.done end

function M.add_root(dir)
	local real, err = validate_dir(dir)
	if not real then refuse(err); return false end
	local roots = copy(config.options.write_roots or {})
	for _, path in ipairs(roots) do
		if path == real then notify.one_line("yana: already in write_roots: " .. real, vim.log.levels.INFO); return true end
	end
	roots[#roots + 1] = real
	commit_roots(roots)
	notify.one_line("yana: added to write_roots (capture set): " .. real, vim.log.levels.INFO)
	return true
end

function M.maybe_notify_on_empty()
	if raised_empty_once or #(config.options.write_roots or {}) > 0 then return end
	if vim.env.YANA_HERMETIC_ROOT and vim.env.YANA_HERMETIC_ROOT ~= "" and vim.env.YANA_TEST_CAPTURE_SET_DIALOG ~= "1" then return end
	raised_empty_once = true
	notify.one_line("yana: capture set empty — :YanaRoots to add folders writable from every project", vim.log.levels.INFO)
end

function M.maybe_raise_on_empty() M.maybe_notify_on_empty() end
function M.command(opts)
	local arg = vim.trim((opts and opts.args) or "")
	if arg == "" then M.open() else M.add_root(arg) end
end

M._test = {
	disclosure_lines = function() return copy(DISCLOSURE) end,
	left_bufnr = function() return active and active.grid and active.grid.buf or nil end,
	draft = function() return active and model.commit_list(active.model) or nil end,
	marked = function() return active and copy(active.model.marked) or nil end,
	spans = function() return active and active.grid and copy(active.grid.spans) or nil end,
	set_filter = function(value)
		if active then
			model.set_filter(active.model, value or ""); active.active_row = 1
			if active.model.filter ~= "" then vim.wait(500, function() return active.model.search_ready end, 20) end
		end
	end,
	refresh = function() if active then refresh(active) end end,
	left_focused_path = function() local item = active and focused_left(active); return item and item.path or nil end,
	cwd = function() return active and active.cwd or nil end,
	reset_session_flag = function() raised_empty_once = false end,
}

return M
