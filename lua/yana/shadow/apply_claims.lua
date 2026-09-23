-- Claims are per FILE, never per workspace: a claim refuses a FILE under another
-- session's open review (the same path or one inside it). Reads, ask turns and an agent
-- inside its own overlay never claim; an empty touched set takes no claim; `file.claim`
-- arbitrates per file at accept.
local M = {}

local uv = vim.uv or vim.loop
local request_seq = 0
--- Absolute path for one `(repository, relative path)` accept check.
function M.file_claim_path(root, rel)
	if type(root) ~= "string" or root == "" or type(rel) ~= "string" or rel == "" then
		return nil
	end
	local abs = vim.fn.fnamemodify(root .. "/" .. rel, ":p")
	return abs
end

local function next_request_id(session_id)
	request_seq = request_seq + 1
	return table.concat({ session_id, "file.claim", tostring(uv.hrtime()), tostring(request_seq) }, ":")
end

local function holder_phrase(refusal)
	local editor = type(refusal) == "table" and type(refusal.editor) == "table" and refusal.editor or {}
	local pid = editor.pid
	if pid ~= nil and tostring(pid) ~= "" then
		return string.format("held by pid %s", tostring(pid))
	end
	local sid = type(refusal) == "table" and refusal.session_id or nil
	if type(sid) == "string" and sid ~= "" then
		return string.format("held by session %s", sid)
	end
	-- No synthesised "held by another session": a nil/empty refusal means the
	-- claim could not be decided (no_daemon / timeout), not that a peer holds it.
	return nil
end

--- Holder phrase when the daemon returned a real refusal, else nil.
local function refusal_description(_path, refusal)
	return holder_phrase(refusal)
end

--- Ask yanad whether this session may accept one path. The operation ID is
--- unique per operator attempt; reconnects reuse it inside the socket client.
--- `done(ok, path, description, code, refusal)` runs once after the reply.
function M.request_file_claim(root, rel, owner, done)
	local path = M.file_claim_path(root, rel)
	if not path then
		return false, "the change carries no repository/path to claim"
	end
	local session_id = owner and (owner.yanad_session_id or owner.session_id)
	if type(session_id) ~= "string" or session_id == "" then
		return false, "yanad session_id missing for file.claim"
	end
	local yanad = require("yana.runtime.yanad")
	local request_id = next_request_id(session_id)
	yanad.file_claim({
		session_id = session_id,
		path = path,
	}, request_id, function(ok, result_or_code, refusal)
		vim.schedule(function()
			if ok then
				done(true, path, nil, nil, nil)
				return
			end
			done(false, path, refusal_description(path, refusal), result_or_code, refusal)
		end)
	end)
	return true, request_id
end

return M
