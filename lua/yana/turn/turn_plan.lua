-- Immutable per-turn capture plan. It computes data only; yanad persists it.
local M = {}

local function json(value)
	if type(value) == "table" then
		local count, array = 0, true
		for key in pairs(value) do
			count = count + 1
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false end
		end
		if array then
			local out = {}
			for index = 1, count do out[index] = json(value[index]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys, out = {}, {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do out[#out + 1] = vim.json.encode(key) .. ":" .. json(value[key]) end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return vim.json.encode(value)
end

local function real(path)
	local uv = vim.uv or vim.loop
	return uv.fs_realpath(path) or path
end

local function contains(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.mountinfo(text)
	local mounts = {}
	for line in text:gmatch("[^\n]+") do
		local left, right = line:match("^(.-) %- (.+)$")
		if left and right then
			local fields, fs = vim.split(left, " ", { trimempty = true }), vim.split(right, " ", { trimempty = true })
			mounts[#mounts + 1] = { mount_id = tonumber(fields[1]), dev = fields[3], mountpoint = fields[5], options = fields[6], fstype = fs[1] }
		end
	end
	return mounts
end

local function mount_for(mounts, path)
	local found
	for _, mount in ipairs(mounts) do
		if contains(mount.mountpoint, path) and (not found or #mount.mountpoint > #found.mountpoint) then found = mount end
	end
	return found
end

local function is_leaf(mounts, root)
	for _, mount in ipairs(mounts) do if mount.mountpoint ~= root and contains(root, mount.mountpoint) then return false end end
	return true
end

local function candidate(mount)
	local blocked = { proc = true, sysfs = true, devtmpfs = true, devpts = true, tmpfs = true, overlay = true, squashfs = true, fuse = true, fuseblk = true }
	if blocked[mount.fstype] then return false end
	-- The per-mount options are a comma-separated list; `rw` is one whole
	-- element of it. A substring test would also accept `rw` inside
	-- `errors=remount-ro`, and a Lua pattern has no alternation to spell the
	-- boundary with, so split and compare the element.
	for _, option in ipairs(vim.split(mount.options, ",", { trimempty = true })) do
		if option == "rw" then return true end
	end
	return false
end

function M.canonical(plan)
	local body = vim.deepcopy(plan)
	body.plan_id = nil
	return json(body)
end

function M.plan_id(plan)
	return vim.fn.sha256(M.canonical(plan))
end

function M.verify(plan)
	if type(plan) ~= "table" or plan.plan_version ~= 1 or type(plan.plan_id) ~= "string" then return nil, "invalid turn plan" end
	for _, key in ipairs({ "session_id", "turn_id", "mode", "anchor", "label", "seeds", "layers", "protected", "writable_exceptions", "prompt_boundary" }) do
		if plan[key] == nil then return nil, "missing turn plan field: " .. key end
	end
	if M.plan_id(plan) ~= plan.plan_id then return nil, "plan_id mismatch" end
	return true
end

-- One planned derivation step is not implemented, and that is a known
-- behavioural conflict: automatically adding every writable leaf mount would
-- widen what a turn can write before a file under that mount becomes part of
-- the turn's context.
--
-- `tests/turn_plan_gate.sh` -- the S1 contract row, written against the same
-- feature ID -- forbids exactly that. Its fixture mounts `$GATE/nested/inner`
-- as a writable, leaf, ext4 mount, and requires the derived layers to be
-- `proj` ALONE: "ro/tmpfs/submount excluded, one root per mount". Implemented
-- literally, step 4 adds `nested/inner` and the row goes red (measured
-- 2026-09-12: "layers are 'nested/inner|proj', expected 'proj'").
--
-- The spec's own refusal table points the same way as the test: it keeps an
-- `unseeded` class for "a writable directory no seed reached", with the remedy
-- "open a file there and resend". If step 4 added every writable leaf mount,
-- almost nothing could ever be `unseeded` and that class would be dead.
--
-- So one of the two is wrong, and deciding which is a behavioural ruling, not
-- an implementation detail: step 4 widens what a turn may write without the
-- operator opening anything there. The pinned contract row wins until that is
-- ruled on. Raised in CLOUD-PACKET-capture-scope-STATUS.md.

function M.build(input)
	local mounts = M.mountinfo(input.mountinfo)
	local seeds, seen, roots, claimed = {}, {}, {}, {}
	-- F-CAPTURE-COVER derivation, CONFINEMENT.md "Capture mechanism". The seeds
	-- are $HOME, the working directory, and the directory of every file buffer,
	-- selection source and @mention in the turn -- filesystem position and the
	-- editor's own state, never an option, allowlist or Git fact.
	--
	-- Built by append rather than as one constructor: a nil `home` or `anchor`
	-- inside a table constructor leaves a hole that stops `ipairs` at the
	-- first seed, silently dropping every later one.
	local ordered = {}
	-- The first seed is $HOME, read here rather than taken on trust from the
	-- caller: the derivation is this module's, and a caller that forgot to pass
	-- it would silently narrow the cover instead of failing. An explicit
	-- `input.home` still wins, which is what lets the gate fixture drive a
	-- synthetic tree.
	ordered[#ordered + 1] = input.home or vim.env.HOME
	ordered[#ordered + 1] = input.anchor
	for _, path in ipairs(input.seeds or {}) do ordered[#ordered + 1] = path end

	local function claim(root)
		if not claimed[root] then
			claimed[root], roots[#roots + 1] = true, root
		end
	end

	-- Step 3. For each seed on a candidate mount, the layer root is its highest
	-- ancestor that stays on that mount and has no mount strictly below it --
	-- the mountpoint itself. A SEED THAT ITSELF CARRIES A MOUNT YIELDS NO
	-- LAYER: an overlay there would have to clone a tree with a locked child
	-- mount, which an unprivileged mount namespace refuses with EINVAL.
	for _, path in ipairs(ordered) do
		local seed = real(path)
		if not seen[seed] then
			seen[seed], seeds[#seeds + 1] = true, seed
			local mount = mount_for(mounts, seed)
			local carries_mount = false
			for _, other in ipairs(mounts) do
				if other.mountpoint == seed and (not mount or other.mount_id ~= mount.mount_id) then carries_mount = true end
			end
			if mount and candidate(mount) and is_leaf(mounts, mount.mountpoint) and not carries_mount then
				-- Two seeds under one mount name ONE root. Without this the
				-- root is appended once per seed and the turn mounts the same
				-- tree as several overlay layers.
				claim(real(mount.mountpoint))
			end
		end
	end

	table.sort(roots)
	local protected = { real(input.state_root), real(input.socket_dir) }

	-- Step 5. Drop a root nested in another root, or inside a protected path.
	--
	-- Nesting is dropped because two overlays over one tree is the cross-layer
	-- bleed the change set cannot decode: a path would land in two uppers and
	-- the walk would report it twice. Protected is dropped because yana's own
	-- state IS the evidence this turn's review is read from -- an overlay over
	-- it hands the agent its own change set.
	local layers = {}
	for _, root in ipairs(roots) do
		local blocked = false
		for _, path in ipairs(protected) do if contains(path, root) then blocked = true end end
		for _, other in ipairs(roots) do
			if other ~= root and contains(other, root) then blocked = true end
		end
		local mount = mount_for(mounts, root)
		if not blocked and mount then
			layers[#layers + 1] = { index = #layers + 1, root = root, mount_id = mount.mount_id, dev = mount.dev,
				upper = string.format("%s/sessions/%s/turns/%s/layers/%d/upper", input.state_root, input.session_id, input.turn_id, #layers + 1),
				work = string.format("%s/sessions/%s/turns/%s/layers/%d/work", input.state_root, input.session_id, input.turn_id, #layers + 1) }
		end
	end
	local plan = { plan_version = 1, session_id = input.session_id, turn_id = input.turn_id, mode = input.mode,
		anchor = real(input.anchor), label = input.label, seeds = seeds, layers = layers, protected = protected,
		writable_exceptions = input.writable_exceptions, prompt_boundary = vim.tbl_map(function(layer) return layer.root end, layers) }
	plan.plan_id = M.plan_id(plan)
	return plan
end

return M
