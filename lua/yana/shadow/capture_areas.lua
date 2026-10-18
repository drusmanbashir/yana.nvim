-- Capture areas (Open Capture OC-03): the directories every inline turn
-- can edit without a grant -- the home folder and each writable data disk. Read
-- from the mount table and the invoking user's own write permission only, never
-- from configuration or anything a turn produced.
local M = {}

local uv = vim.uv or vim.loop

-- Filesystems that hold ordinary user files. Pseudo, memory, network and image
-- filesystems are never capture areas.
local DISK_FS = {
	ext2 = true, ext3 = true, ext4 = true, xfs = true, btrfs = true, f2fs = true,
	vfat = true, exfat = true, ntfs = true, ntfs3 = true, fuseblk = true, zfs = true,
}

-- Kernel, boot and runtime trees keep their established read-only policy.
local SYSTEM = { "/boot", "/proc", "/sys", "/dev", "/run", "/snap", "/var/snap", "/tmp" }

local function unescape(field)
	return (field:gsub("\\(%d%d%d)", function(octal)
		return string.char(tonumber(octal, 8))
	end))
end

local function inside(root, path)
	return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Parse `/proc/self/mountinfo` text into `{ device, root, mountpoint, options,
--- fstype }` rows, in mount order.
function M.mounts(text)
	local rows = {}
	for line in text:gmatch("[^\n]+") do
		local left, right = line:match("^(.-) %- (.*)$")
		if left then
			local fields = vim.split(left, " ", { plain = true })
			local tail = vim.split(right, " ", { plain = true })
			if fields[3] and fields[4] and fields[5] and fields[6] and tail[1] then
				rows[#rows + 1] = {
					device = fields[3],
					root = unescape(fields[4]),
					mountpoint = unescape(fields[5]),
					options = fields[6],
					fstype = tail[1],
				}
			end
		end
	end
	return rows
end

--- The sorted capture areas. A candidate with another filesystem mounted inside
--- it is left out: a kernel overlay does not cross mounts in its lower layer, so
--- covering it would hide that inner filesystem from the agent.
--- `opts.home`, `opts.mountinfo` and `opts.writable(path)` exist for tests.
function M.list(opts)
	opts = opts or {}
	local text = opts.mountinfo
	if not text then
		local fh = io.open("/proc/self/mountinfo", "r")
		text = fh and fh:read("*a") or ""
		if fh then
			fh:close()
		end
	end
	local writable = opts.writable or function(path)
		return uv.fs_access(path, "W") == true
	end
	local mounts = M.mounts(text)
	local function has_inner_mount(root)
		for _, row in ipairs(mounts) do
			if row.mountpoint ~= root and inside(root, row.mountpoint) then
				return true
			end
		end
		return false
	end

	local areas, seen = {}, {}
	local function add(path)
		if not seen[path] then
			seen[path] = true
			areas[#areas + 1] = path
		end
	end

	local home = opts.home or vim.env.HOME
	home = home and home ~= "" and uv.fs_realpath(home) or nil
	if home == "/" then
		home = nil -- a service account's "/" home is not an area and covers no disk
	end
	local home_source
	if home and writable(home) and not has_inner_mount(home) then
		add(home)
		-- Home's own filesystem subtree, so a bind of home or part of it elsewhere
		-- is recognised as an alias below rather than captured twice.
		local holder
		for _, row in ipairs(mounts) do
			if inside(row.mountpoint, home) and (not holder or #row.mountpoint >= #holder.mountpoint) then
				holder = row
			end
		end
		if holder then
			local rel = holder.mountpoint == "/" and home:sub(2) or home:sub(#holder.mountpoint + 2)
			local base = holder.root == "/" and "" or holder.root
			home_source = { device = holder.device, root = rel == "" and holder.root or base .. "/" .. rel }
		end
	end
	-- Only the last (visible) mount at each mountpoint counts.
	local visible = {}
	for index, row in ipairs(mounts) do
		visible[row.mountpoint] = index
	end
	local candidates = {}
	for index, row in ipairs(mounts) do
		local point = row.mountpoint
		local system = point == "/"
		for _, prefix in ipairs(SYSTEM) do
			system = system or inside(prefix, point)
		end
		local rw = ("," .. row.options .. ","):find(",rw,", 1, true) ~= nil
		local near_home = home and (inside(home, point) or inside(point, home))
		if visible[point] == index and not system and rw and DISK_FS[row.fstype] and not near_home
			and writable(point) and not has_inner_mount(point) then
			candidates[#candidates + 1] = row
		end
	end
	-- One area per filesystem subtree: a candidate whose source (device + root) is
	-- the same as, or inside, an earlier candidate's is an alias of it, not a
	-- second area -- two overlays over one subtree would propose one file twice.
	-- A btrfs subvolume mounted on its own (root "/@data") still counts.
	for i, row in ipairs(candidates) do
		local alias = home_source ~= nil and row.device == home_source.device
			and (inside(home_source.root, row.root) or inside(row.root, home_source.root))
		for j, other in ipairs(candidates) do
			if j ~= i and other.device == row.device and inside(other.root, row.root)
				and (other.root ~= row.root or j < i) then
				alias = true
				break
			end
		end
		if not alias then
			add(row.mountpoint)
		end
	end
	table.sort(areas)
	return areas
end

return M
