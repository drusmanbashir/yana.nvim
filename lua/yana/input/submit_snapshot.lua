-- The submit snapshot of open buffers.
local diff = require("yana.diff")

local M = {}

-- Submit snapshot. For every open, named file buffer inside the
-- turn's roots: B0, one invalidating extmark per B0
-- line, a reload/unload listener and the edit counter. Each snapshot owns its
-- extmark ids and listener ids; release deletes exactly those, never a namespace.
M.SNAPSHOT_MAX_LINES = 50000
local SNAPSHOT_NS = vim.api.nvim_create_namespace("yana-buffer-snapshot")

local function inside_roots(path, roots)
	for _, root in ipairs(roots or {}) do
		local r = root:gsub("/+$", "")
		if path == r or path:sub(1, #r + 1) == r .. "/" then return true end
	end
	return false
end

local function listen(snap)
	snap.autocmds = {
		vim.api.nvim_create_autocmd("BufReadPost", { buffer = snap.bufnr, desc = "yana buffer snapshot",
			callback = function() snap.lost = "reloaded" end }),
		vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, { buffer = snap.bufnr,
			desc = "yana buffer snapshot", callback = function() snap.lost = snap.lost or "unloaded" end }),
	}
end

-- Returns snapshots keyed by absolute path, and the same snapshots in order: the
-- submit buffer first, then by path. A binary buffer has no text B0 and is skipped.
function M.take_snapshots(roots, first_bufnr, refusals)
	local order, snaps = {}, {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(bufnr)
		if name ~= "" and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
			local path = diff.abs_path(name)
			if inside_roots(path, roots) then
				local b0, err = diff.buffer_bytes_snapshot(bufnr)
				if b0 then
					order[#order + 1] = { bufnr = bufnr, path = path, b0 = b0,
						eol = { fileformat = vim.bo[bufnr].fileformat, bomb = vim.bo[bufnr].bomb } }
				elseif refusals then
					refusals[path] = err
				end
			end
		end
	end
	table.sort(order, function(x, y)
		if (x.bufnr == first_bufnr) ~= (y.bufnr == first_bufnr) then return x.bufnr == first_bufnr end
		return x.path < y.path
	end)
	local kept = {}
	for _, snap in ipairs(order) do
		if not snaps[snap.path] then -- two buffers naming one file: the first in order keeps it
			snap.ns, snap.ids = SNAPSHOT_NS, {}
			snap.tick_submit = vim.api.nvim_buf_get_changedtick(snap.bufnr)
			local count = vim.api.nvim_buf_line_count(snap.bufnr)
			if count > M.SNAPSHOT_MAX_LINES then
				snap.no_extmarks = true
			else
				for row = 0, count - 1 do
					snap.ids[row] = vim.api.nvim_buf_set_extmark(snap.bufnr, SNAPSHOT_NS, row, 0,
						{ end_row = row + 1, end_col = 0, invalidate = true, strict = false })
				end
			end
			listen(snap)
			snaps[snap.path] = snap
			kept[#kept + 1] = snap
		end
	end
	return snaps, kept
end

-- Overlay copy (INTERFACE.md section 2): each snapshot inside the roots gets its B0
-- written to a file in the turn's private folder. Returns session.seed_files. The
-- launcher splits `--seed path=from` at the last '=', so `from` must not hold one.
function M.write_seeds(order, roots, private_dir)
	local seeds = {}
	for _, snap in ipairs(order or {}) do
		if inside_roots(snap.path, roots) then
			local from = string.format("%s/seed/%d.b0", tostring(private_dir), #seeds + 1)
			if type(private_dir) ~= "string" or private_dir == "" or from:find("=", 1, true) then
				return nil, "the turn's private folder cannot hold the open buffer copies: " .. tostring(private_dir)
			end
			local ok, err = diff.write_file(from, snap.b0)
			if not ok then return nil, "could not write the open buffer copy for " .. snap.path .. ": " .. tostring(err) end
			seeds[#seeds + 1] = { path = snap.path, from = from }
		end
	end
	return seeds
end

function M.release_snapshot(snap)
	if vim.api.nvim_buf_is_valid(snap.bufnr) then
		for _, id in pairs(snap.ids or {}) do pcall(vim.api.nvim_buf_del_extmark, snap.bufnr, snap.ns, id) end
	end
	for _, id in ipairs(snap.autocmds or {}) do pcall(vim.api.nvim_del_autocmd, id) end
	snap.autocmds = nil
end

-- Release a turn's snapshots (all of them, or only those no file record carries).
function M.release_snapshots(tables, gen, only_uncarried)
	local snaps = tables and gen ~= nil and tables[gen]
	if not snaps then return end
	for path, snap in pairs(snaps) do
		if not (only_uncarried and snap.carried) then
			M.release_snapshot(snap)
			snaps[path] = nil
		end
	end
	if next(snaps) == nil then tables[gen] = nil end
end

return M
