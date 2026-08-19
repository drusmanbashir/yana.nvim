-- Content-hash authority for safety modules (N7). NUL-safe for arbitrary binary bytes.
local M = {}

local diff = require("yana.diff")

local function sha256sum_bytes(s)
	local r = vim.system({ "sha256sum", "-b" }, { stdin = s, text = false }):wait()
	if r.code ~= 0 then
		error("sha256sum failed: " .. tostring(r.stderr or r.stdout or r.code))
	end
	-- Bound, not `return assert(...)`. Lua's assert returns ALL its arguments,
	-- so the tail call handed back (digest, "sha256sum returned no hash") and
	-- any multi-value context downstream — io.write, a positional argument, a
	-- varargs call — silently appended the message to the hash.
	local digest = r.stdout:match("^(%x+)")
	if not digest then
		error("sha256sum returned no hash")
	end
	return digest
end

--- Deterministic hex sha256 of raw file bytes. Agrees with coreutils sha256sum.
function M.hash_bytes(s)
	-- Both returns are parenthesised on purpose: in Lua that truncates the
	-- expression to exactly one value. This is the content-hash authority for
	-- the safety modules, so "returns one string" is part of its contract and
	-- is enforced structurally here rather than trusted to each callee.
	s = s or ""
	if not s:find("\0", 1, true) then
		return (vim.fn.sha256(s))
	end
	return (sha256sum_bytes(s))
end

--- Read path and hash its bytes; nil + err when unreadable.
function M.hash_file(path)
	local content, err = diff.read_file_bytes(path)
	if content == nil then
		return nil, err
	end
	return M.hash_bytes(content), content
end

return M
