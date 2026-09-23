-- Per-backend model catalogue: --list-models spawn, parse, session-scoped
-- cache with stale-while-refresh TTL (modes.md §5 vendor model hierarchy).
-- Split out of lua/yana/agent/agent.lua.
local config = require("yana.config")
local dependencies = require("yana.runtime.dependencies")
local log = require("yana.log")

local M = {}

-- Default 5 minutes; tests shorten via set_model_list_ttl_ms.
local model_list_ttl_ms = 5 * 60 * 1000

-- A vendor CLI with no listing surface still gets asked (list_models_args
-- IS declared for it); a login prompt it never answers must not hang this
-- forever. Deadline and cap are test-seamed so a row need not wait for real.
local DEFAULT_LIST_TIMEOUT_MS = 10000
local list_timeout_ms = DEFAULT_LIST_TIMEOUT_MS

-- Bounds the stdout this module retains from one --list-models spawn. A
-- model list is at most a few KB; a CLI that streams megabytes (misfired
-- flag, a login TUI redrawing) must not grow this process's memory without
-- limit while the timeout above is still ticking.
local MAX_LIST_OUTPUT_BYTES = 1024 * 1024

local function now_ms()
	return vim.uv.hrtime() / 1e6
end

function M.set_model_list_ttl_ms(ms)
	assert(type(ms) == "number" and ms >= 0, "model_list_ttl_ms must be a non-negative number")
	model_list_ttl_ms = ms
end

function M.model_list_ttl_ms()
	return model_list_ttl_ms
end

local function parse_lines_models(out)
	local models = {}
	local seen = {}
	for _, line in ipairs(out) do
		local id, label = line:match("^(%S+)%s+%-%s+(.+)$")
		if id and not seen[id] then
			seen[id] = true
			local current = label:match("%(current%)") ~= nil
			local default = label:match("%(default%)") ~= nil
			label = label:gsub("%s*%(current%)%s*$", ""):gsub("%s*%(default%)%s*$", "")
			table.insert(models, { id = id, label = label, current = current, default = default })
		end
	end
	return models
end

-- json_models parser. Keeps visibility=="list" only. Never reads
-- model_messages. Capability fields (reasoning levels, speed tiers) are
-- forwarded for the hierarchy loader; they are not prompt payloads.
local function parse_json_models(out)
	local ok, decoded = pcall(vim.json.decode, table.concat(out, "\n"))
	if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
		return {}
	end
	local models = {}
	for _, m in ipairs(decoded.models) do
		if type(m) == "table" and m.visibility == "list" and type(m.slug) == "string" and m.slug ~= "" then
			local label = m.display_name
			if type(label) ~= "string" or label == "" then
				label = m.slug
			end
			table.insert(models, {
				id = m.slug,
				label = label,
				identity = m.slug,
				supported_reasoning_levels = m.supported_reasoning_levels,
				additional_speed_tiers = m.additional_speed_tiers,
			})
		end
	end
	return models
end

-- Entry shapes:
--   { status = "ready", models, code, reason, fetched_at, refreshing? }
--   { status = "pending", waiters = { cb, ... } }
local model_list_cache = {}

local function cache_notify_waiters(entry, models, code, reason)
	local waiters = entry.waiters or {}
	entry.waiters = nil
	for _, w in ipairs(waiters) do
		w(models, code, reason)
	end
end

local function entry_fresh(entry)
	if not entry or entry.status ~= "ready" then
		return false
	end
	-- Unsupported / empty static degrade entries do not auto-refresh.
	if entry.code ~= 0 then
		return true
	end
	if type(entry.fetched_at) ~= "number" then
		return true
	end
	return (now_ms() - entry.fetched_at) < model_list_ttl_ms
end

function M.cached_model_list(backend)
	local entry = model_list_cache[backend]
	if entry and entry.status == "ready" then
		return entry.models, entry.code, entry.reason
	end
	return nil
end

--- Non-blocking refresh marker for the hierarchy table title.
function M.model_list_refreshing(backend)
	local entry = model_list_cache[backend]
	return entry and entry.status == "ready" and entry.refreshing == true
end

function M.clear_model_list_cache(backend)
	if backend then
		model_list_cache[backend] = nil
	else
		model_list_cache = {}
	end
end

local function spawn_list_models(backend, bd, pending, retain_on_fail)
	pending = pending or { status = "pending", waiters = {} }
	local ready = model_list_cache[backend]
	if retain_on_fail and ready and ready.status == "ready" then
		-- Keep last-known-good visible while the refresh runs.
		ready.refreshing = true
	else
		model_list_cache[backend] = pending
	end

	local command = config.cmd(backend)
	local desktop_refusal = dependencies.desktop_cursor_refusal(command, backend)
	if desktop_refusal then
		local entry = model_list_cache[backend]
		if retain_on_fail and entry and entry.status == "ready" then
			entry.refreshing = nil
			cache_notify_waiters(pending, entry.models, entry.code, entry.reason)
		else
			model_list_cache[backend] = nil
			cache_notify_waiters(pending, {}, -1, desktop_refusal)
		end
		return
	end

	local out = {}
	local out_bytes = 0
	local timed_out = false
	local resolved = false
	local timer = nil
	local job

	local function stop_timer()
		if timer then
			pcall(timer.stop, timer)
			pcall(timer.close, timer)
			timer = nil
		end
	end

	-- The single place this spawn's outcome is decided, called exactly once:
	-- either from a normal on_exit, or from the timeout firing. Whichever
	-- gets there first wins; the other is a no-op (`resolved` guard) so a
	-- child that eventually dies after being timed out cannot overwrite the
	-- timeout verdict with a late, coincidental "success".
	local function resolve(models, code, reason)
		if resolved then
			return
		end
		resolved = true
		local entry = model_list_cache[backend]
		if code == 0 and #models > 0 then
			model_list_cache[backend] = {
				status = "ready",
				models = models,
				code = 0,
				reason = nil,
				fetched_at = now_ms(),
			}
			cache_notify_waiters(pending, models, code, nil)
		elseif retain_on_fail and entry and entry.status == "ready" then
			entry.fetched_at = now_ms()
			entry.refreshing = nil
			cache_notify_waiters(pending, entry.models, entry.code, entry.reason)
		elseif entry and entry.status == "pending" then
			model_list_cache[backend] = nil
			cache_notify_waiters(pending, models, code, reason)
		else
			if entry and entry.status == "ready" then
				entry.refreshing = nil
			end
			cache_notify_waiters(pending, models, code, reason)
		end
	end

	local argv = { command }
	vim.list_extend(argv, bd.list_models_args)
	job = vim.fn.jobstart(argv, {
		env = { LC_ALL = "C" },
		-- No prompt of ours will ever answer one of the CLI's; give it
		-- nothing to wait on rather than an open pipe nobody writes to.
		stdin = "null",
		on_stdout = function(_, data)
			if timed_out or not data then
				return
			end
			for _, line in ipairs(data) do
				if out_bytes >= MAX_LIST_OUTPUT_BYTES then
					break
				end
				out[#out + 1] = line
				out_bytes = out_bytes + #line + 1
			end
		end,
		on_exit = function(_, code)
			stop_timer()
			if timed_out then
				-- The timeout already resolved this spawn; a straggling exit
				-- (the kill finally took effect) has nothing left to decide.
				return
			end
			vim.schedule(function()
				log.guard("yana.agent list_models on_exit", function()
					local models
					if bd.list_models_format == "json_models" then
						models = parse_json_models(out)
					else
						models = parse_lines_models(out)
					end
					resolve(models, code, nil)
				end)
			end)
		end,
	})

	if job <= 0 then
		local entry = model_list_cache[backend]
		if retain_on_fail and entry and entry.status == "ready" then
			entry.refreshing = nil
			cache_notify_waiters(pending, entry.models, entry.code, entry.reason)
		else
			model_list_cache[backend] = nil
			cache_notify_waiters(pending, {}, -1, nil)
		end
		return
	end

	timer = (vim.uv or vim.loop).new_timer()
	timer:start(list_timeout_ms, 0, function()
		if timed_out then
			return
		end
		timed_out = true
		-- timer:stop/close are libuv-native and safe here; vim.fn.jobstop is
		-- a Vimscript function call and is NOT -- it must not run in this
		-- fast event context (E5560), so it moves into the same
		-- vim.schedule as the rest of the resolution.
		stop_timer()
		vim.schedule(function()
			pcall(vim.fn.jobstop, job)
			local reason = string.format(
				"model list from %s timed out after %d s; if the CLI is waiting for a login, run it once in a terminal",
				command,
				math.floor(list_timeout_ms / 1000)
			)
			log.guard("yana.agent list_models timeout", function()
				resolve({}, -3, reason)
			end)
		end)
	end)
end

function M.list_models(cb, opts)
	opts = opts or {}
	local backend = opts.backend or config.options.backend
	local bd = config.backend_descriptor(backend) or {}

	if not opts.force then
		local cached = model_list_cache[backend]
		if cached and cached.status == "ready" then
			cb(cached.models, cached.code, cached.reason)
			-- Stale-while-refresh: kick one background probe when TTL elapsed
			-- and this vendor actually has a listing surface.
			if not entry_fresh(cached) and not cached.refreshing and bd.list_models_args then
				spawn_list_models(backend, bd, { status = "pending", waiters = {} }, true)
			end
			return
		end
		if cached and cached.status == "pending" then
			cached.waiters[#cached.waiters + 1] = cb
			return
		end
	end

	if not bd.list_models_args then
		if bd.models and #bd.models > 0 then
			local models = {}
			for _, m in ipairs(bd.models) do
				models[#models + 1] = { id = m.id, label = m.label, identity = m.id }
			end
			model_list_cache[backend] = {
				status = "ready",
				models = models,
				code = 0,
				reason = nil,
				fetched_at = now_ms(),
			}
			cb(models, 0, nil)
			return
		end
		local reason = backend .. " does not support listing models"
		model_list_cache[backend] = {
			status = "ready",
			models = {},
			code = -2,
			reason = reason,
			fetched_at = now_ms(),
		}
		cb({}, -2, reason)
		return
	end

	local pending = { status = "pending", waiters = { cb } }
	spawn_list_models(backend, bd, pending, false)
end

-- Test seam: shorten the --list-models deadline so a row can prove the
-- timeout without waiting 10 real seconds. nil restores the shipped default.
M._test = {}

function M._test.set_list_timeout_ms(ms)
	if ms == nil then
		list_timeout_ms = DEFAULT_LIST_TIMEOUT_MS
		return
	end
	assert(type(ms) == "number" and ms > 0, "list_timeout_ms must be a positive number")
	list_timeout_ms = ms
end

function M._test.list_timeout_ms()
	return list_timeout_ms
end

return M
