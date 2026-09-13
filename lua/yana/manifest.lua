-- Shared manifest parsing: one hash domain and canonical relative paths.
local M = {}

M.HEADER = "# yana-manifest-v2"
M.HEADER_PATTERN = "^# yana%-manifest%-v2%s+(.+)$"

function M.validate_rel(rel)
	if type(rel) ~= "string" or rel == "" then
		return false, "empty relative path"
	end
	if rel:find("\0", 1, true) or rel:find("\n", 1, true) or rel:find("\r", 1, true) then
		return false, "relative path contains control characters"
	end
	if rel:match("^/") or rel:match("^%a:") then
		return false, "absolute path in manifest"
	end
	if rel:find("\\", 1, true) then
		return false, "backslash in relative path"
	end
	for part in rel:gmatch("[^/]+") do
		if part == "." or part == ".." then
			return false, "dot component in relative path"
		end
	end
	return true
end

function M.parse_header(line)
	local meta = line:match(M.HEADER_PATTERN)
	if not meta then
		return nil, "missing or malformed manifest header"
	end
	local settle = meta:match("settle=([^%s]+)")
	return { settle = settle or "unknown", raw = meta }
end

local function add_entry(map, h, rel, line_no)
	local ok, verr = M.validate_rel(rel)
	if not ok then
		return nil, string.format("manifest record %d: %s", line_no or 0, verr)
	end
	if #h ~= 64 or not h:match("^[%x]+$") then
		return nil, string.format("manifest record %d: bad hash %q", line_no or 0, h)
	end
	if map[rel] then
		return nil, "duplicate manifest entry: " .. rel
	end
	map[rel] = h
	return map
end

function M.read_file(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, "cannot read manifest: " .. tostring(path)
	end
	local first = f:read("*l")
	if not first then
		f:close()
		return nil, "empty manifest"
	end
	local header, herr = M.parse_header(first)
	if not header then
		f:close()
		return nil, herr
	end

	local map = { _header = header }
	local record_no = 0
	while true do
		local h = f:read(64)
		if not h or #h == 0 then
			break
		end
		if #h < 64 then
			f:close()
			return nil, string.format("truncated hash at record %d", record_no + 1)
		end
		local sep = f:read(1)
		if sep ~= "\0" then
			f:close()
			return nil, string.format("malformed separator at record %d", record_no + 1)
		end
		local rel_parts = {}
		while true do
			local ch = f:read(1)
			if not ch then
				f:close()
				return nil, string.format("truncated path at record %d", record_no + 1)
			end
			if ch == "\0" then
				break
			end
			rel_parts[#rel_parts + 1] = ch
		end
		record_no = record_no + 1
		local rel = table.concat(rel_parts)
		local ok, add_err = add_entry(map, h, rel, record_no)
		if not ok then
			f:close()
			return nil, add_err
		end
	end
	f:close()
	map._header = header
	return map
end

function M.read_lines(path)
	local map, err = M.read_file(path)
	if not map then
		return nil, err
	end
	local lines = {}
	for rel, h in pairs(map) do
		if rel:sub(1, 1) ~= "_" then
			lines[#lines + 1] = { hash = h, rel = rel }
		end
	end
	table.sort(lines, function(a, b)
		return a.rel < b.rel
	end)
	return lines, nil, map._header
end

function M.write_file(path, entries, opts)
	opts = opts or {}
	local settle = opts.settle or "none"
	local f, err = io.open(path, "wb")
	if not f then
		return false, err
	end
	f:write(string.format("%s settle=%s\n", M.HEADER, settle))
	for _, entry in ipairs(entries) do
		local ok, verr = M.validate_rel(entry.rel)
		if not ok then
			f:close()
			return false, verr
		end
		if #entry.hash ~= 64 then
			f:close()
			return false, "bad hash for " .. entry.rel
		end
		f:write(entry.hash)
		f:write("\0")
		f:write(entry.rel)
		f:write("\0")
	end
	f:close()
	return true
end

function M.write_staged_list(path, rels)
	local f, err = io.open(path, "wb")
	if not f then
		return false, err
	end
	for _, rel in ipairs(rels) do
		local ok, verr = M.validate_rel(rel)
		if not ok then
			f:close()
			return false, verr
		end
		f:write(rel)
		f:write("\0")
	end
	f:close()
	return true
end

function M.read_staged_list(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local rels = {}
	while true do
		local rel_parts = {}
		while true do
			local ch = f:read(1)
			if not ch then
				if #rel_parts == 0 then
					f:close()
					return rels
				end
				f:close()
				return nil, "truncated staged path"
			end
			if ch == "\0" then
				break
			end
			rel_parts[#rel_parts + 1] = ch
		end
		local rel = table.concat(rel_parts)
		if rel == "" then
			break
		end
		local ok, verr = M.validate_rel(rel)
		if not ok then
			f:close()
			return nil, verr
		end
		rels[#rels + 1] = rel
	end
end

--- Is one prep-time evidence record COMPLETE?
---
--- Every field the accept-time comparison needs, present and well-formed, or the
--- record refuses. Validating only `rel` let a row with no `base_state` through
--- to the applier, which then had nothing to compare type or mode with and fell
--- back to content alone — where absence and an empty file are the same value.
--- A record that cannot answer "what was here, of what type, at what mode" is
--- not weaker evidence, it is no evidence.
function M.validate_base_evidence_row(row, where)
	where = where or "base evidence"
	if type(row) ~= "table" or type(row.rel) ~= "string" then
		return false, where .. ": malformed record"
	end
	local ok, verr = M.validate_rel(row.rel)
	if not ok then
		return false, where .. ": " .. verr
	end
	if type(row.hash) ~= "string" or #row.hash ~= 64 or not row.hash:match("^%x+$") then
		return false, where .. ": missing or malformed before-fingerprint for " .. row.rel
	end
	local state = row.base_state
	if state ~= "absent" and state ~= "file" and state ~= "link" then
		return false, where .. ": missing or invalid base_state for " .. row.rel
	end
	if (state == "file" or state == "link") and type(row.base_mode) ~= "number" then
		return false, where .. ": missing base_mode for " .. row.rel
	end
	if state == "link" and (type(row.base_link_target) ~= "string" or row.base_link_target == "") then
		return false, where .. ": missing base_link_target for " .. row.rel
	end
	return true
end

--- Prep-time comparison closure evidence (JSONL), one record per touched path.
function M.read_base_evidence(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, "cannot read base evidence: " .. tostring(path)
	end
	local map = {}
	local line_no = 0
	for line in f:lines() do
		if line ~= "" then
			line_no = line_no + 1
			local ok, row = pcall(vim.json.decode, line)
			if not ok or type(row) ~= "table" then
				f:close()
				return nil, string.format("malformed base evidence at line %d", line_no)
			end
			local verr
			ok, verr = M.validate_base_evidence_row(row, string.format("base evidence line %d", line_no))
			if not ok then
				f:close()
				return nil, verr
			end
			if map[row.rel] then
				f:close()
				return nil, "duplicate base evidence entry: " .. row.rel
			end
			map[row.rel] = row
		end
	end
	f:close()
	if line_no == 0 then
		return nil, "empty base evidence"
	end
	return map
end

function M.write_base_evidence(path, rows)
	local f, err = io.open(path, "w")
	if not f then
		return false, err
	end
	for _, row in ipairs(rows) do
		-- Refuse to WRITE an incomplete record too: a change set that cannot be
		-- accepted must fail where it is produced, not where it is consumed.
		local ok, verr = M.validate_base_evidence_row(row, "base evidence row")
		if not ok then
			f:close()
			return false, verr
		end
		f:write(vim.json.encode(row))
		f:write("\n")
	end
	f:close()
	return true
end

return M
