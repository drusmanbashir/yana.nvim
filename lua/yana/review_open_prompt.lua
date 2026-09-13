-- Prompt for a structured yanad review refusal. No claim sidecars are read.
local M = { _prompt_open = false }

local MAX_NAMED_FILES = 3

local function file_phrase(files)
	if type(files) ~= "table" or #files == 0 then
		return "Review open (file set not recorded)"
	end
	local named = {}
	for i, path in ipairs(files) do
		if i > MAX_NAMED_FILES then
			named[#named + 1] = string.format("+%d more", #files - MAX_NAMED_FILES)
			break
		end
		named[#named + 1] = tostring(path)
	end
	return "Review open on " .. table.concat(named, ", ")
end

local function editor_phrase(editor)
	if type(editor) ~= "table" or editor.pid == nil then
		return "in an editor that cannot be identified"
	end
	if editor.cwd and editor.cwd ~= "" then
		return string.format("in nvim %s (%s)", tostring(editor.pid), tostring(editor.cwd))
	end
	return string.format("in nvim %s", tostring(editor.pid))
end

local function items_for(refuse)
	local editor = refuse.editor or {}
	return {
		string.format("Abort that review - session %s in nvim %s", tostring(refuse.session_id or "?"), tostring(editor.pid or "?")),
		"Cancel - leave the review exactly as it is",
	}
end

local REMOTE_ABORT = [[
vim.schedule(function()
	require("yana.inline_diff").abort_active()
end)
return true
]]

local function notify(opts, message, level)
	if type(opts.notify) == "function" then
		return opts.notify(message, level)
	end
	return require("yana.notify").one_line(message, level)
end

local function editor_target(editor)
	local pid = type(editor) == "table" and tonumber(editor.pid) or nil
	local servername = type(editor) == "table" and editor.servername or nil
	if type(servername) ~= "string" or servername == "" then
		servername = "<missing>"
	end
	return pid, servername
end

local function report_failure(editor, opts, reason)
	local pid, servername = editor_target(editor)
	notify(opts, string.format(
		"yana: cannot request abort in nvim %s via %s: %s",
		tostring(pid or "?"),
		servername,
		reason
	), vim.log.levels.WARN)
end

local function report_requested(editor, opts)
	local pid = editor_target(editor)
	notify(opts, "yana: abort requested in nvim " .. tostring(pid or "?"), vim.log.levels.INFO)
end

local function schedule_local_abort(editor, opts)
	local schedule = opts.schedule or vim.schedule
	schedule(function()
		require("yana.inline_diff").abort_active()
	end)
	report_requested(editor, opts)
end

local function close_channel(channel, opts)
	local close = opts.close or vim.fn.chanclose
	pcall(close, channel)
end

local function abort_refusal(refuse, opts)
	local editor = type(refuse.editor) == "table" and refuse.editor or {}
	local pid, servername = editor_target(editor)
	if not pid or pid < 1 or pid % 1 ~= 0 then
		return report_failure(editor, opts, "recorded pid is invalid")
	end
	if pid == vim.fn.getpid() then
		return schedule_local_abort(editor, opts)
	end
	if servername == "<missing>" then
		return report_failure(editor, opts, "recorded socket is missing")
	end

	local dial = opts.dial or function(path)
		return vim.fn.sockconnect("pipe", path, { rpc = true })
	end
	local ok_dial, channel = pcall(dial, servername)
	if not ok_dial or type(channel) ~= "number" or channel <= 0 then
		return report_failure(editor, opts, "editor socket is unreachable")
	end

	local request = opts.rpcrequest or vim.fn.rpcrequest
	local ok_pid, actual_pid = pcall(request, channel, "nvim_eval", "getpid()")
	if not ok_pid or tonumber(actual_pid) ~= pid then
		close_channel(channel, opts)
		return report_failure(editor, opts, "RPC pid authentication failed (got " .. tostring(actual_pid) .. ")")
	end

	local ok_abort, accepted = pcall(request, channel, "nvim_exec_lua", REMOTE_ABORT, {})
	close_channel(channel, opts)
	if not ok_abort or accepted ~= true then
		return report_failure(editor, opts, "remote abort scheduling failed")
	end
	report_requested(editor, opts)
end

--- Raise #103 from a daemon refusal object. Abort schedules the existing
--- consequence dialog in the recorded editor; Cancel changes nothing.
function M.offer_from_refuse(refuse, opts)
	opts = opts or {}
	if #vim.api.nvim_list_uis() == 0 and not (M._test and M._test.assume_ui) then
		return false
	end
	if M._prompt_open or type(refuse) ~= "table" or refuse.code ~= "review_open" then
		return false
	end
	local title = file_phrase(refuse.files) .. " - " .. editor_phrase(refuse.editor)
	M._prompt_open = true
	local ok = pcall(vim.ui.select, items_for(refuse), { prompt = title }, function(choice)
		M._prompt_open = false
		if type(choice) == "string" and choice:sub(1, 5) == "Abort" then
			abort_refusal(refuse, opts)
		end
	end)
	if not ok then
		M._prompt_open = false
		return false
	end
	return true
end

M._test = {
	items_for = items_for,
	assume_ui = false,
}

return M
