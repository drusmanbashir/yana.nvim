-- Model hierarchy picker. Axes and selection state stay here; ui_grid owns UI.
local mh = require("yana.agent.model_hierarchy")
local matrix = require("yana.panel.ui_model_hierarchy_matrix")
local grid = require("yana.panel.ui_grid")
local buttons = require("yana.panel.ui_review_buttons")
local notify = require("yana.notify")

local M = {}
local NS = vim.api.nvim_create_namespace("yana.model_hierarchy")
local HL = buttons.hl_groups()
local LEGEND = " Space fix · Enter apply · Esc cancel "
local LEGEND_BACK = " Space fix · Enter apply · Esc cancel · BS back "
local active

local function contains(values, wanted)
	for _, value in ipairs(values or {}) do if value == wanted then return true end end
	return false
end

local function refresh_columns(s)
	s.columns = mh.live_columns(s.backend, s.rows, s.all_columns)
	if #s.columns == 0 then s.columns = { "model" } end
	for col in pairs(s.fixed) do if not contains(s.columns, col) then s.fixed[col] = nil end end
	if not contains(s.columns, s.active_col) then
		s.active_col_i, s.active_col, s.active_val = 1, s.columns[1], nil
	end
end

local function value_at(s, col, row_i)
	local values = s.axes[col] or {}
	return values[row_i] or values[1]
end

local function ensure_active(s)
	refresh_columns(s)
	matrix.rebuild_axes(s)
	s.active_col_i = math.min(math.max(1, s.active_col_i or 1), #s.columns)
	s.active_col = s.columns[s.active_col_i]
	s.active_row = math.min(math.max(1, s.active_row or 1), math.max(1, s.data_rows))
	s.active_val = value_at(s, s.active_col, s.active_row)
end

local function current_value(s, col)
	local want = s.current and s.current[col]
	if type(want) ~= "string" or want == "" or want == "-" then
		return nil
	end
	return contains(s.axes[col] or {}, want) and want or nil
end

local function cell_rows(s)
	refresh_columns(s)
	local axes = matrix.rebuild_axes(s)
	local out = {}
	for row_i = 1, math.max(1, s.data_rows) do
		local row = {}
		for _, col in ipairs(s.columns) do
			local value = (axes[col] or {})[row_i]
			if value then
				-- One yellow current value per column. A staged pick shadows the
				-- stored value until Enter; Escape discards `fixed`.
				local selected = s.fixed[col] or current_value(s, col)
				local marked = value == selected
				row[#row + 1] = {
					col = col, value = value, row_i = row_i,
					text = " " .. value .. " ",
					key_offset = 1, key_width = 0,
					dim = matrix.axis_dim(s, col, value), fixed = s.fixed[col] == value,
					current = marked,
					active = row_i == s.active_row and col == s.active_col and value == s.active_val,
				}
			end
		end
		out[#out + 1] = row
	end
	return out
end

local function clear_right_fixed(s, col)
	local after = false
	for _, candidate in ipairs(s.columns) do
		if candidate == col then after = true
		elseif after and s.fixed[candidate] then
			local value = s.fixed[candidate]
			if not contains(matrix.axis_values(s, candidate), value) or matrix.axis_dim(s, candidate, value) then
				s.fixed[candidate] = nil
			end
		end
	end
end

local function toggle_fix(s, col, value, dim)
	if dim or not value then return end
	if s.fixed[col] == value then s.fixed[col] = nil else s.fixed[col] = value end
	clear_right_fixed(s, col)
end

local function apply_session(s)
	local resolved = mh.resolve(s.backend, s.fixed, s.rows)
	if not resolved then
		local missing = mh.missing_required(s.backend, s.fixed)
		notify.one_line("yana: model hierarchy — fix required cells before Enter: "
			.. (#missing > 0 and table.concat(missing, ", ") or "complete selection"), vim.log.levels.WARN)
		return false
	end
	if s.on_apply then s.on_apply(resolved) end
	M.close(s)
	return true
end

local function close_session(s, cancelled)
	if not s or s._closed then return end
	s._closed = true
	if active == s then active = nil end
	if s.grid then s.grid:close(false) end
	if cancelled and s.on_cancel then s.on_cancel() end
end

local function render(s, opts)
	ensure_active(s)
	return s.grid and s.grid:render(opts)
end

function M.open(opts)
	opts = opts or {}
	if active then close_session(active, true) end
	local backend = opts.backend or "cursor"
	local all_columns = opts.columns or mh.columns(backend)
	local rows = opts.rows or {}
	local current = opts.current or mh.decode_current(backend, opts.current_model, opts.current_modes, rows) or {}
	local s = {
		backend = backend, all_columns = all_columns, columns = all_columns, rows = rows,
		fixed = {}, current = current, data_rows = 1, active_row = 1, active_col_i = 1,
		active_col = all_columns[1], refreshing = opts.refreshing and true or false,
		source_note = opts.source_note, on_apply = opts.on_apply, on_cancel = opts.on_cancel,
		on_back = opts.on_back,
	}
	s.grid = grid.open({
		state = s, layout = "columns", columns = function(x) return x.columns end,
		cells = cell_rows, row_count = function(x) return x.data_rows end,
		column_count = function(x, col) return #(x.axes[col] or {}) end, value_at = value_at,
		title = function(x)
			local title = { "yana: model hierarchy", x.backend }
			if x.source_note and x.source_note ~= "" then title[#title + 1] = x.source_note end
			if x.refreshing then title[#title + 1] = "refreshing…" end
			return table.concat(title, " · ")
		end,
		window_title = " " .. backend .. " ", title_pos = "left",
		legend = opts.on_back and LEGEND_BACK or LEGEND,
		hl_groups = HL, focus_guard = true, global_mouse = true, fit_buffer = false, namespace = NS,
		map_desc = {
			["<LeftMouse>"] = "yana: model hierarchy press",
			["<LeftRelease>"] = "yana: model hierarchy release",
			["<MouseMove>"] = "yana: model hierarchy hover",
			["<LeftDrag>"] = "yana: model hierarchy ignore drag",
			["<2-LeftMouse>"] = "yana: model hierarchy ignore double",
			["<3-LeftMouse>"] = "yana: model hierarchy ignore triple",
			["<BS>"] = "yana: model hierarchy back",
		},
		on_space = function() toggle_fix(s, s.active_col, s.active_val, matrix.axis_dim(s, s.active_col, s.active_val)) end,
		on_release = function(_, span) if span then toggle_fix(s, span.col, span.value, span.dim) end end,
		on_cursor = function() ensure_active(s) end,
		on_enter = function() apply_session(s) end,
		on_cancel = function() close_session(s, true) end,
		on_back = opts.on_back and function()
			local cb = s.on_back
			close_session(s, false)
			if type(cb) == "function" then cb() end
		end or nil,
	})
	s.buf, s.win = s.grid.buf, s.grid.win
	vim.bo[s.buf].filetype = "yana_model_hierarchy"
	active = s
	ensure_active(s)
	render(s, { place_cursor = true })
	return s
end

function M.close(s) close_session(s or active, false) end

M._test = {}
function M._test.active() return active end
function M._test.selectable_values(s, col)
	s = s or active
	if not s or not contains(s.columns, col) then return s and {} or nil end
	refresh_columns(s); matrix.rebuild_axes(s)
	return vim.deepcopy(s.axes[col] or {})
end
function M._test.fixed(s) return s and vim.deepcopy(s.fixed) or {} end
function M._test.move(s, col, value)
	s = s or active
	refresh_columns(s); matrix.rebuild_axes(s)
	for i, candidate in ipairs(s.axes[col] or {}) do
		if candidate == value then
			s.active_col, s.active_val, s.active_row = col, value, i
			for ci, name in ipairs(s.columns) do if name == col then s.active_col_i = ci end end
			render(s, { place_cursor = true }); return
		end
	end
	s.active_col, s.active_val = col, value
	render(s, { place_cursor = true })
end
function M._test.press(s, key)
	s = s or active
	if not (s and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_buf_is_valid(s.buf)) then return end
	vim.api.nvim_set_current_win(s.win)
	local lhs = key == " " and "<Space>" or key
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
end
function M._test.click(s, col, value)
	s = s or active
	M._test.move(s, col, value)
	for _, span in ipairs(s.spans or {}) do
		if span.col == col and span.value == value then toggle_fix(s, col, value, span.dim); break end
	end
	render(s)
end
function M._test.click_apply(s) return apply_session(s or active) end
function M._test.active_cell(s)
	s = s or active
	return s and { col = s.active_col, value = s.active_val } or nil
end
function M._test.mouse_maps_installed(s)
	s = s or active
	if not (s and vim.api.nvim_buf_is_valid(s.buf)) then return false end
	local found = {}
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(s.buf, "n")) do found[map.lhs] = map.desc end
	return found["<LeftMouse>"] == "yana: model hierarchy press"
		and found["<LeftRelease>"] == "yana: model hierarchy release"
		and found["<MouseMove>"] == "yana: model hierarchy hover"
end
function M._test.spans(s) s = s or active; return s and s.spans or {} end
function M._test.hl_usage() return { active = HL.hover, fixed = HL.flash, key = HL.key, dim = HL.dim, live = HL.live } end
function M._test.geometry(s)
	s = s or active
	if not (s and vim.api.nvim_win_is_valid(s.win)) then return {} end
	local config = vim.api.nvim_win_get_config(s.win)
	return { border = type(config.border) == "string" and config.border or "rounded", title = type(config.title) == "string" and config.title or s.backend, footer = type(config.footer) == "string" and config.footer or (s.on_back and LEGEND_BACK or LEGEND), width = config.width, height = config.height }
end
function M._test.hl_groups() return HL end

return M
