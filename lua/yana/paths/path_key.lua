-- F-CLAIM-KEYS (S3): a directory-safe name for ONE real path.
--
-- The editor's own per-turn state directories used to be named by
-- a Git-derived workspace identity, which walked up to the nearest `.git`
-- and hashed that directory's `(dev, ino)`. That tied state identity to Git,
-- walked the filesystem on a path that must not walk, and collided: two
-- directories in one repository produced one key.
--
-- This is the same rule `bin/lib/yanad/claims.py`'s `path_key` applies, and
-- deliberately so -- the daemon mints the layer directories and the editor
-- names its scratch beside them, so the two must not drift. Both hash the
-- REAL path and take the first 16 hex characters of the SHA-256.
--
-- Parity is pinned by `tests/yanad/t_store_u1.py`
-- (`test_path_key_is_the_path_and_not_its_repository`) on the Python side and
-- by `tests/headless/path_key_parity.lua` on this one.
local M = {}

--- 16-hex key for `path`. Resolves symlinks; consults no ancestor and no Git.
function M.of(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local real = vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/+$", "")
	if real == "" then
		real = "/"
	end
	return vim.fn.sha256(real):sub(1, 16)
end

return M
