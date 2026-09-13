-- Capture-set state. Rendering and Neovim APIs belong to view/controller.
local M = {}

local function copy(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local result = {}
	seen[value] = result
	for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
	return result
end

local function parent(path)
	local result = path:match("^(.+)/[^/]+/?$")
	return result or path
end

local function base(path)
	return path:match("([^/]+)/?$") or path
end

local function inside(root, path)
	return root and path and (path == root or path:sub(1, #root + 1) == root .. "/")
end

local function ignored(name)
	return name == "node_modules" or name:sub(1, 1) == "."
end

local function real(m, path)
	return m.fs.realpath and (m.fs.realpath(path) or path) or path
end

local function entry(item, path)
	if type(item) == "string" then return { name = base(item), path = item } end
	if type(item) ~= "table" then return nil end
	local name = item.name or item[1]
	local value = item.path or item[2] or (name and path .. "/" .. name)
	if not name or not value then return nil end
	return { name = name, path = value, type = item.type or item[3] }
end

local function children(m, path)
	if m.children[path] then return m.children[path] end
	local result = {}
	for _, raw in ipairs(m.fs.scandir(path) or {}) do
		local item = entry(raw, path)
		if item and not ignored(item.name) and (item.type == nil or item.type == "directory" or item.type == "link")
			and (not m.fs.isdir or m.fs.isdir(item.path)) then
			item.path = real(m, item.path)
			result[#result + 1] = item
		end
	end
	table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
	m.children[path] = result
	return result
end

local function has_daughters(m, path)
	return #children(m, path) > 0
end

local function tree_rows(m, path, depth, result)
	for _, item in ipairs(children(m, path)) do
		local expanded = m.expanded[item.path] == true
		result[#result + 1] = {
			path = item.path, name = item.name, depth = depth, expanded = expanded,
			has_children = has_daughters(m, item.path),
		}
		if expanded then tree_rows(m, item.path, depth + 1, result) end
	end
end

local function walk_sync(m)
	local found, count, truncated = {}, 0, false
	local function visit(path, depth)
		if depth > m.max_depth or count >= m.max_results then truncated = true; return end
		for _, item in ipairs(children(m, path)) do
			if count >= m.max_results then truncated = true; return end
			count = count + 1
			found[#found + 1] = { path = item.path, name = item.name, depth = depth }
			if depth < m.max_depth then visit(item.path, depth + 1) end
		end
	end
	visit(m.home, 1)
	return found, truncated
end

local function finish_search(m, values, truncated)
	if m.search_token and m.search_token.cancelled then return end
	m.search_cache, m.search_truncated, m.search_ready = values or {}, truncated == true, true
	if m.on_search then m.on_search(m) end
end

local function start_search(m)
	if m.search_started then return end
	m.search_started = true
	m.search_token = { cancelled = false }
	if type(m.fs.walk) == "function" then
		m.search_handle = m.fs.walk(m.home, {
			max_depth = m.max_depth, max_results = m.max_results,
			skip = ignored, token = m.search_token,
		}, function(values, truncated) finish_search(m, values, truncated) end)
	else
		finish_search(m, walk_sync(m))
	end
end

function M.new(opts)
	opts = opts or {}
	local fs = opts.fs or {}
	local home = opts.home or "/"
	local m = {
		home = home, fs = fs, state_root = opts.state_root, max_depth = opts.max_depth or 8,
		max_results = opts.max_results or 5000, expanded = {}, children = {}, filter = "",
		search_cache = {}, search_ready = false, search_started = false, search_truncated = false,
		draft = copy(opts.draft or {}), marked = {}, active_row = 1, on_search = opts.on_search,
	}
	m.expanded[home] = true
	return m
end

function M.rows(m)
	if m.filter ~= "" then
		if not m.search_ready then return {} end
		local needle = m.filter:lower()
		local result = {}
		for _, item in ipairs(m.search_cache) do
			if item.name:lower():find(needle, 1, true) then
				result[#result + 1] = { path = item.path, name = item.path:sub(#m.home + 2), depth = 0, filtered = true }
			end
		end
		return result
	end
	local result = {}
	tree_rows(m, m.home, 0, result)
	return result
end

function M.toggle(m, path)
	if has_daughters(m, path) then m.expanded[path] = not m.expanded[path] end
	return m.expanded[path] == true
end

function M.collapse(m, path)
	if m.expanded[path] then m.expanded[path] = false; return path end
	local up = parent(path)
	return up
end

function M.set_filter(m, text)
	m.filter = text or ""
	if m.filter ~= "" then start_search(m) end
	return m.filter
end

function M.add(m, path)
	local value = real(m, path)
	if not value or (m.fs.isdir and not m.fs.isdir(value)) then return nil, "path is not a directory" end
	if m.state_root and inside(m.state_root, value) then return nil, "path resolves inside yana's state root: " .. value end
	for _, item in ipairs(m.draft) do if item == value then return nil, "already in the capture set: " .. value end end
	m.draft[#m.draft + 1] = value
	return value
end

function M.remove(m, path)
	for i, item in ipairs(m.draft) do
		if item == path then table.remove(m.draft, i); m.marked[path] = nil; return true end
	end
	return false
end

function M.mark(m, path)
	if not path then return false end
	m.marked[path] = not m.marked[path]
	return m.marked[path]
end

function M.commit_list(m)
	return copy(m.draft)
end

function M.cancel_search(m)
	if m.search_token then m.search_token.cancelled = true end
	if m.search_handle and m.search_handle.cancel then pcall(m.search_handle.cancel) end
	m.search_handle = nil
end

return M
