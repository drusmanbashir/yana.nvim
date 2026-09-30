-- Fail-closed admission and baseline capture for buffer-only HOME edits, and the submit snapshot of open buffers.
local diff = require("yana.diff")
local hash = require("yana.safety.hash")

local M = {}
local uv = vim.uv or vim.loop
M.MAX_PROPOSAL_BYTES = 8 * 1024 * 1024

local PROTECTED = {
	[".ssh"] = true,
	[".gnupg"] = true,
	[".aws"] = true,
	[".azure"] = true,
	[".kube"] = true,
	[".password-store"] = true,
	[".netrc"] = true,
	[".pgpass"] = true,
	[".git-credentials"] = true,
	[".npmrc"] = true,
	[".pypirc"] = true,
}

local function clean(path)
	return vim.fs.normalize(diff.abs_path_literal(path)):gsub("/+$", "")
end

local function refusal(name, why)
	return nil, string.format("Open ~/%s in a buffer to edit it with Yana (%s).", name or "file", why)
end

function M.capture(bufnr, opts)
	opts = opts or {}
	local home_input = opts.home or vim.env.HOME
	if type(home_input) ~= "string" or home_input == "" or home_input:sub(1, 1) ~= "/" then
		return nil -- no environment HOME means there is no HOME-only route to apply
	end
	local home = clean(uv.fs_realpath(home_input) or home_input)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then return nil end
	local literal = vim.api.nvim_buf_get_name(bufnr)
	if literal == "" then return nil end
	literal = clean(literal)
	local parent = vim.fn.fnamemodify(literal, ":h")
	local name = vim.fn.fnamemodify(literal, ":t")
	if home == "" or parent ~= home then
		return nil -- ordinary project/non-direct-HOME path: this route does not apply
	end
	if vim.bo[bufnr].buftype ~= "" then
		return refusal(name, "the buffer is not a normal file buffer")
	end
	if PROTECTED[name:lower()] then
		return refusal(name, "protected credential paths are never eligible")
	end
	local cfg = require("yana.config")
	local backend = cfg.backend_descriptor and cfg.backend_descriptor(cfg.options.backend) or nil
	for _, runtime in ipairs((backend and backend.state_dirs) or {}) do
		local expanded = clean(vim.fn.expand(runtime))
		if literal == expanded or literal:sub(1, #expanded + 1) == expanded .. "/" then
			return refusal(name, "the active backend owns this runtime path")
		end
	end
	local state = vim.env.YANA_STATE_ROOT
	if type(state) == "string" and state ~= "" and state:sub(1, 1) == "/" then
		state = clean(state)
		if literal == state or literal:sub(1, #state + 1) == state .. "/" then
			return refusal(name, "Yana owns this state path")
		end
	end
	local lst = uv.fs_lstat(literal)
	if not lst then
		return refusal(name, "the file does not exist")
	end
	if lst.type ~= "file" then
		return refusal(name, "symlinks and non-regular files are not eligible")
	end
	local resolved = uv.fs_realpath(literal)
	local st = resolved and uv.fs_stat(resolved) or nil
	if not resolved or clean(resolved) ~= literal or not st or st.type ~= "file" then
		return refusal(name, "the file identity is not a direct regular HOME file")
	end
	local disk, err = diff.read_file_bytes(literal)
	if disk == nil then
		return refusal(name, "the disk baseline is unreadable: " .. tostring(err))
	end
	local buffer = diff.buffer_bytes_snapshot(bufnr)
	return {
		kind = "home_buffer_only",
		bufnr = bufnr,
		path = literal,
		home = home,
		name = name,
		dev = st.dev,
		ino = st.ino,
		mode = st.mode,
		disk_bytes = disk,
		disk_hash = hash.hash_bytes(disk),
		buffer_bytes = buffer,
		buffer_hash = hash.hash_bytes(buffer),
	}, nil
end

function M.revalidate(capture)
	if type(capture) ~= "table" or capture.kind ~= "home_buffer_only" then
		return nil, "buffer-only capture missing"
	end
	local current, err = M.capture(capture.bufnr, { home = capture.home })
	if not current then
		return nil, err or "buffer-only target is no longer eligible"
	end
	if current.path ~= capture.path or current.dev ~= capture.dev or current.ino ~= capture.ino then
		return nil, "buffer-only target identity changed"
	end
	-- Your edits while the agent works, and a save, are followed by the submit snapshot's
	-- extmarks: neither a buffer edit nor a save refuses.
	return current
end

-- Submit snapshot. For every open, named file buffer inside the
-- turn's roots, plus the home-folder buffer: B0, one invalidating extmark per B0
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
function M.take_snapshots(roots, first_bufnr, home_capture)
	local order, snaps = {}, {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(bufnr)
		if name ~= "" and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
			local path = diff.abs_path(name)
			local is_home = home_capture ~= nil and home_capture.bufnr == bufnr
			local b0 = (is_home or inside_roots(path, roots)) and diff.buffer_bytes_snapshot(bufnr) or nil
			if b0 then
				order[#order + 1] = { bufnr = bufnr, path = path, b0 = b0, home_capture = is_home and home_capture or nil }
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

-- The home-folder capture among a turn's snapshots, if the turn has one.
function M.home_capture_of(snaps)
	for _, snap in pairs(snaps or {}) do
		if snap.home_capture then return snap.home_capture end
	end
	return nil
end

function M.parse_response(text)
	if type(text) ~= "string" or text == "" then return nil, "buffer-only proposal response is empty" end
	if #text > M.MAX_PROPOSAL_BYTES then return nil, "buffer-only proposal exceeds the 8 MiB limit" end
	local ok, value = pcall(vim.json.decode, text)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return nil, "buffer-only proposal must be exactly one JSON object"
	end
	for key in pairs(value) do
		if key ~= "replacement_text" then return nil, "buffer-only proposal contains forbidden field: " .. tostring(key) end
	end
	if type(value.replacement_text) ~= "string" then
		return nil, "buffer-only proposal requires string field replacement_text"
	end
	if value.replacement_text:find("\0", 1, true) then return nil, "buffer-only proposal is not text" end
	local utf8_ok = pcall(vim.str_utfindex, value.replacement_text)
	if not utf8_ok then return nil, "buffer-only proposal is not valid UTF-8" end
	return value.replacement_text
end

function M.publish(turn, capture, response)
	local current, err = M.revalidate(capture)
	if not current then return nil, err end
	local replacement, perr = M.parse_response(response)
	if replacement == nil then return nil, perr end
	if replacement == capture.buffer_bytes then
		turn.home_buffer_capture = capture
		turn.home_buffer_noop = true
		return true
	end
	if type(turn) ~= "table" or type(turn.upper_dir) ~= "string" or turn.upper_dir == "" then
		return nil, "buffer-only private proposal layer is unavailable"
	end
	local upper = clean(turn.upper_dir)
	local target = upper .. "/" .. capture.name
	if vim.fn.fnamemodify(target, ":h") ~= upper then
		return nil, "buffer-only proposal target escaped its private layer"
	end
	local ok, werr = diff.write_file(target, replacement)
	if not ok then return nil, "could not publish buffer-only private proposal: " .. tostring(werr) end
	local chmod_ok, chmod_err = uv.fs_chmod(target, capture.mode)
	if not chmod_ok then return nil, "could not preserve private proposal mode: " .. tostring(chmod_err) end
	turn.home_buffer_capture = capture
	turn.home_buffer_proposal = { path = capture.path, upper_path = target, replacement_text = replacement }
	return true
end

-- The ordinary walker compares the private proposal with disk. When the
-- agent intentionally restores the disk bytes over an unsaved buffer change,
-- that comparison is empty even though the buffer review is not. Admit that
-- one pinned operation here, beside the protocol adapter that owns the two
-- baselines; callers must not infer it from UI state.
function M.classify_buffer_restore(turn, capture, changes, typed, classification)
	if not (capture and changes and #changes == 0 and turn.home_buffer_proposal
		and turn.home_buffer_proposal.replacement_text == capture.disk_bytes
		and capture.buffer_bytes ~= capture.disk_bytes)
	then
		return changes, typed, classification
	end
	local captured_ts = os.time()
	local mode = string.format("%o", capture.mode % 4096)
	local op = {
		kind = "modify", detail = "file", rel = capture.name, path = capture.path,
		root = turn.workspace, root_index = 1, base_hash_captured_ts = captured_ts,
		base_evidence = { state = "file", mode = mode, hash = capture.disk_hash },
	}
	local synthetic = {
		id = "shadow-" .. tostring(turn.turn_id) .. "-" .. capture.name,
		path = capture.path, rel = capture.name, root = turn.workspace,
		root_index = 1, root_is_primary = true, turn_id = turn.turn_id, turn_gen = turn.turn_gen,
		kind = "modify", before = capture.disk_bytes, after = capture.disk_bytes,
		base_state = "file", base_hash = capture.disk_hash, base_mode = mode,
		base_hash_captured_ts = captured_ts, after_mode = mode,
		upper_path = turn.home_buffer_proposal.upper_path, shadow_apply = true, status = "pending",
	}
	-- changes and classification.changes are the same list in the ordinary
	-- classifier. Write it once; appending through both names duplicates it.
	changes[1] = synthetic
	typed = typed or {}
	typed[#typed + 1] = op
	classification = classification or { changes = changes, groups = {}, individual = {}, unsafe = {}, ignored = {} }
	classification.changes = changes
	classification.individual = classification.individual or {}
	classification.individual[#classification.individual + 1] = op
	return changes, typed, classification
end

return M
