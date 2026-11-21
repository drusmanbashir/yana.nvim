-- Whole-turn checkpoint and revert layered on the accept diary.
-- Captures pre-turn bytes into the diary folder; revert restores via diary.write_bytes.
local M = {}

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local uv = vim.uv or vim.loop

M._test = {}

local function hash_bytes(s)
	-- Parenthesised: a bare `return f(s)` is a tail call and forwards however
	-- many values f returns, so this alias would silently inherit any future
	-- second return from the hash authority.
	return (hash.hash_bytes(s))
end

local function read_bytes(path)
	local content, err = diff.read_file_bytes(path)
	if content == nil and vim.fn.filereadable(path) ~= 1 then
		return "", nil
	end
	return content, err
end

--- WHAT THIS PATH WAS WHEN THE TURN STARTED, as a tag, not as bytes.
---
--- `read_bytes` above answers "" for a path that does not exist, and "" is also what an
--- existing empty file reads as. Storing only the bytes therefore threw away the one
--- distinction the revert needs: a whole-turn revert of a file the agent CREATED
--- restored "" and left a ZERO-BYTE FILE where the operator had nothing, and reported
--- success.
---
--- THE TAG IS A MEASUREMENT, NOT THE PRODUCER'S TYPING. `the change model contract`
--- does distinguish `create` from `modify`, but that typing is not what belongs here.
--- It is not reachable -- `shadow/apply.lua:begin_pass` projects `change.path` out of
--- the change set and drops `kind` and `base_state`, so `begin_turn` receives a flat
--- list of strings -- and threading it through would be the wrong repair anyway.
---
local function capture_state(path)
	local st = uv.fs_lstat(path)
	if st == nil then
		return "absent", nil
	end
	if st.type == "file" then
		return "file", st.mode % 4096
	end
	-- Not a regular file. Tagged by what it is and refused at restore rather than
	-- at capture: review-apply leaves such an object "exactly as found with the
	-- refusal naming it", and refusing here would instead halt the accept that
	-- merely NAMED it. Nothing is silently restored over it either way.
	return tostring(st.type), st.mode % 4096
end

local function checkpoint_root(session, turn_id)
	return session.diary_dir .. "/checkpoint/" .. turn_id
end

local function manifest_path(session, turn_id)
	return checkpoint_root(session, turn_id) .. "/manifest.json"
end

local function store_path(session, turn_id, rel)
	local safe = vim.fn.sha256(rel):sub(1, 32)
	return checkpoint_root(session, turn_id) .. "/files/" .. safe .. ".bin"
end

local function resolve_in_workspace(workspace, path)
	workspace = diff.abs_path(workspace)
	path = diff.abs_path(path)
	if path ~= workspace and not vim.startswith(path, workspace .. "/") then
		return nil, "path escapes workspace"
	end
	local rel = path:sub(#workspace + 2)
	if rel == "" then
		return path, ""
	end
	return path, rel
end

local function read_manifest(session, turn_id)
	local path = manifest_path(session, turn_id)
	if vim.fn.filereadable(path) ~= 1 then
		return nil, "checkpoint not found"
	end
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function write_manifest(session, turn_id, manifest)
	local root = checkpoint_root(session, turn_id)
	vim.fn.mkdir(root .. "/files", "p")
	local fd, err = uv.fs_open(manifest_path(session, turn_id), "w", 438)
	if not fd then
		return false, err
	end
	local payload = vim.json.encode(manifest)
	local ok, werr = uv.fs_write(fd, payload, -1)
	uv.fs_close(fd)
	if not ok then
		return false, werr
	end
	return true
end

--- Capture the before-set for a turn into the diary folder.
--- opts.session — diary session from diary.begin
--- opts.turn_id — turn identity (e.g. generation counter)
--- opts.paths — list of paths the turn may touch (abs or workspace-relative)
---
--- IDEMPOTENT ON (session, turn_id), and guarded on the MANIFEST rather than on
--- anything the caller holds. Capturing those as the turn's pre-turn state makes the
--- whole-turn revert restore the ACCEPTED state and report success — the operator asks
--- to undo the turn, is told it worked, and the turn is still there. Silent data loss,
--- so the guard is the one artefact that survives the pass object being rebuilt: the
--- manifest on disk.
---
--- The re-entry is a NO-OP, not a merge. The existing capture is returned as it
--- stands, so a retried pass that names MORE paths than the first does not
--- extend the checkpoint — the module cannot tell a path the turn has not
--- touched yet (still pre-turn, safe to add) from one it already accepted (post-
--- accept, the whole defect), and guessing is what this exists to stop.
function M.begin_turn(opts)
	opts = opts or {}
	local session = opts.session
	local turn_id = tostring(opts.turn_id or "0")
	local paths = opts.paths or {}

	if vim.fn.filereadable(manifest_path(session, turn_id)) == 1 then
		local ok, existing = pcall(read_manifest, session, turn_id)
		if not ok or type(existing) ~= "table" then
			return nil,
				"a checkpoint already exists for turn "
					.. turn_id
					.. " but its manifest is unreadable; refusing to re-capture over possibly-accepted bytes"
		end
		return {
			session = session,
			turn_id = turn_id,
			entries = existing.entries or {},
			reused = true,
		}
	end

	local entries = {}
	for _, raw in ipairs(paths) do
		local abs, rel = resolve_in_workspace(session.workspace, raw)
		if not abs then
			return nil, rel
		end
		local state, mode = capture_state(abs)
		local content, err = read_bytes(abs)
		if content == nil then
			return nil, err
		end
		local dst = store_path(session, turn_id, rel ~= "" and rel or vim.fn.fnamemodify(abs, ":t"))
		local rel_key = rel ~= "" and rel or vim.fn.fnamemodify(abs, ":t")
		vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
		local fd, oerr = uv.fs_open(dst, "w", 438)
		if not fd then
			return nil, oerr
		end
		local wok, werr = uv.fs_write(fd, content, -1)
		uv.fs_close(fd)
		if not wok then
			return nil, werr
		end
		entries[#entries + 1] = {
			path = abs,
			rel = rel_key,
			base_hash = hash_bytes(content),
			state = state,
			mode = mode,
			store_path = dst,
		}
	end

	local manifest = {
		kind = "checkpoint",
		turn_id = turn_id,
		stream = session.stream,
		workspace = session.workspace,
		ts = os.time(),
		entries = entries,
	}
	local ok, err = write_manifest(session, turn_id, manifest)
	if not ok then
		return nil, err
	end

	return {
		session = session,
		turn_id = turn_id,
		entries = entries,
	}
end

--- The manifest a caller guards on. Normalised the same way `begin_turn` and
--- `revert_turn` normalise their own `turn_id`, so a caller holding a number
--- cannot be told "no checkpoint" about a checkpoint those two can see.
function M.manifest_path(session, turn_id)
	return manifest_path(session, tostring(turn_id or "0"))
end

return M
