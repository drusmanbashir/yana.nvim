-- Fail-closed admission and immutable baseline capture for buffer-only HOME edits.
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
	if current.disk_hash ~= capture.disk_hash then
		return nil, "buffer-only target changed on disk"
	end
	if current.buffer_hash ~= capture.buffer_hash then
		return nil, "buffer changed while the proposal was running"
	end
	return current
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
