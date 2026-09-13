-- Pure capture-set projection: model state in, grid cells out.
local M = {}
local roots_model = require("yana.roots.model")

local function contains(list, value)
	for _, item in ipairs(list or {}) do if item == value then return true end end
	return false
end

local function shown(path, home)
	if path == home then return "~" end
	if home ~= "/" and path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
	return path
end

local function take_head(text, width)
	local result, used = "", 0
	for i = 0, vim.fn.strchars(text) - 1 do
		local char = vim.fn.strcharpart(text, i, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > width then break end
		result, used = result .. char, used + char_width
	end
	return result
end

local function take_tail(text, width)
	local result, used = "", 0
	for i = vim.fn.strchars(text) - 1, 0, -1 do
		local char = vim.fn.strcharpart(text, i, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > width then break end
		result, used = char .. result, used + char_width
	end
	return result
end

local function middle_clip(text, width)
	if width <= 1 then return "…" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local content_width = width - vim.fn.strdisplaywidth("…")
	local head_width = math.floor(content_width / 2)
	return take_head(text, head_width) .. "…" .. take_tail(text, content_width - head_width)
end

function M.labels()
	return { "navigation", "capture set" }
end

function M.cells(model)
	local left, draft = roots_model.rows(model), model.draft
	local count = math.max(#left, #draft)
	local result = {}
	for row = 1, count do
		local line = {}
		local item = left[row]
		if item then
			local marker = item.has_children and (item.expanded and "▾" or "▸") or "  "
			line[#line + 1] = {
				col = "navigation", row_i = row, value = item.path,
				text = string.rep("  ", item.depth or 0) .. marker .. item.name .. "/",
				active = model.active_col == "navigation" and model.active_row == row,
				current = contains(model.draft, item.path),
			}
		end
		local path = draft[row]
		if path then
			line[#line + 1] = {
				col = "capture set", row_i = row, value = path, text = shown(path, model.home),
				clip = "leading",
				active = model.active_col == "capture set" and model.active_row == row,
				current = true, marked = model.marked[path] == true,
			}
		end
		result[#result + 1] = line
	end
	return result
end

function M.title(model, width)
	local home = model.home
	local matches = 0
	if model.filter ~= "" and model.search_ready then
		for _, item in ipairs(model.search_cache) do if item.name:lower():find(model.filter:lower(), 1, true) then matches = matches + 1 end end
	end
	local prefix = "Home: " .. shown(home, home)
	if model.filter == "" then return prefix end
	local suffix = model.search_ready and ("  (" .. matches .. " matches)") or "  (searching…)"
	if model.search_truncated then suffix = suffix .. " (truncated)" end
	local filter = model.filter
	if width then
		local available = width - vim.fn.strdisplaywidth(prefix .. "   filter: ") - vim.fn.strdisplaywidth(suffix)
		filter = middle_clip(filter, math.max(1, available))
	end
	return prefix .. "   filter: " .. filter .. suffix
end

return M
