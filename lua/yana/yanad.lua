-- The plugin's yanad client.
local M = {}
local uv = vim.uv or vim.loop
M.timeout_ms, M.retry_ms, M.retries = 5000, 200, 10
-- How long a daemon THIS client autostarted may take to bind its socket before
-- the dial gives up with `no_daemon`. A cold yanad in the release container
-- needs longer than retries * retry_ms; failing at that point parked the first
-- turn behind a refusal nothing re-fired (tests/headless/u_yanad_autostart_slow_daemon.lua).
M.autostart_timeout_ms = 15000
local function repo_root()
	return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
end
local function read_version()
	local f = io.open(repo_root() .. "/VERSION", "r")
	if not f then return "" end
	local v = (f:read("*a") or ""):gsub("%s+$", "")
	f:close()
	return v
end
local function owner_identity()
	local boot, ticks = "", 0
	local bf = io.open("/proc/sys/kernel/random/boot_id", "r")
	if bf then boot = (bf:read("*l") or ""):gsub("%s+$", ""); bf:close() end
	local sf = io.open("/proc/self/stat", "r")
	if sf then
		local after = (sf:read("*a") or ""):match("%)%s+(.*)"); sf:close()
		if after then ticks = tonumber(vim.split(after, "%s+", { trimempty = true })[20]) or 0 end
	end
	return { pid = vim.fn.getpid(), boot_id = boot, start_ticks = ticks }
end
local function state_root() return require("yana.shadow.preview").state_root() end
local function sha8_of(root) return vim.fn.sha256(uv.fs_realpath(root) or root):sub(1, 8) end
function M.sock_path()
	local root = state_root()
	local pf = io.open(root .. "/yanad.sock.path", "r")
	if pf then
		local p = (pf:read("*l") or ""):gsub("%s+$", ""); pf:close()
		if p ~= "" then return p end
	end
	local sha8, xdg = sha8_of(root), vim.env.XDG_RUNTIME_DIR
	if xdg and xdg ~= "" then return xdg .. "/yana/" .. sha8 .. ".sock" end
	return string.format("/tmp/yana-%d/%s.sock", uv.getuid(), sha8)
end
-- Starter contract: return true/false for an immediate verdict, or nil and call
-- done(ok) later. Never block the loop.
M.starters = {
	systemd_run = function(unit, cmd, done)
		if vim.fn.executable("systemd-run") ~= 1 then return false end
		local argv = { "systemd-run", "--user", "--unit", unit, "--collect" }
		vim.list_extend(argv, cmd)
		local j = vim.fn.jobstart(argv, { detach = true, on_exit = function(_, code) done(code == 0) end })
		if type(j) ~= "number" or j <= 0 then return false end
		return nil
	end,
	setsid = function(cmd)
		local argv = { "setsid", "-f" }
		vim.list_extend(argv, cmd)
		local j = vim.fn.jobstart(argv, { detach = true })
		return type(j) == "number" and j > 0
	end,
}
function M.render_error(text)
	local ok, ui = pcall(require, "yana.ui")
	if not ok then return end -- no yana.ui at all: nothing to render into
	return ui.render_error(text)
end
function M.dial(mode, path, opts) return vim.fn.sockconnect(mode, path, opts or {}) end
local Client = {}
Client.__index = Client
-- One connection per request is the model here, so a connection that nobody is
-- waiting on any more must be handed back to the OS. Without this every yanad
-- command left a live unix socket in Neovim's fd table: a long session reached
-- the 1024-fd cap, after which no shell-out and no job could spawn anywhere in
-- that Neovim -- surfacing as "Could not find kitty REPL window", a REPL bug
-- that was never a REPL bug. chanclose is the only fd release for `sockconnect`.
function Client:_close()
	local chan = self.chan
	self.chan, self._done = nil, true
	if chan then pcall(vim.fn.chanclose, chan) end
end
-- Close once hello has settled and no reply is outstanding. Reconnect re-sends
-- pending ids, so a client with pending work must keep its socket.
function Client:_settle()
	if self._hello_cb or next(self.pending) ~= nil then return end
	self:_close()
end
function Client:_arm_timeout(id, entry)
	local ms = M.timeout_ms
	if ms <= 0 then return end
	local timer = uv.new_timer()
	entry.timer = timer
	timer:start(ms, 0, function()
		timer:stop(); timer:close()
		if self.pending[id] ~= entry then return end
		self.pending[id] = nil
		-- Third argument for the same reason as `wrap` above.
		vim.schedule(function() entry.cb(false, "timeout", { reason_code = "timeout", unreachable = true }) end)
		self:_settle()
	end)
end
function Client:_send(frame)
	if not self.chan then return false end
	return pcall(vim.fn.chansend, self.chan, vim.json.encode(frame) .. "\n")
end
-- Plain decode makes it `vim.NIL`, a USERDATA sentinel that is TRUTHY, so every `if
-- row.field then` downstream reads "recorded" for what the daemon recorded as absent.
-- `store.py` materialises every optional bundle key, so a content-only edit ships
-- `"after_mode": null`; as `vim.NIL` it passed review_turn's guard and blew up in
-- `mode_perm`'s `% 4096`, aborting a resumed review (hunks 1 -> 0). Settled HERE, once,
-- not in each of the dozens of readers.
function Client:_dispatch(line)
	local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true } })
	if not ok or type(msg) ~= "table" then return end
	local id = msg.id
	if self._hello_id and id == self._hello_id then
		local cb = self._hello_cb; self._hello_cb = nil
		if cb then
			local hello_ok = msg.ok and true or false
			local hello_result = msg.ok and self or (msg.code or "hello_refused")
			if hello_ok then self._accepted = true end
			vim.schedule(function() cb(hello_ok, hello_result) end)
		end
		-- A refused hello is final (version_mismatch, identity_mismatch, ...): no
		-- request will ever follow, so release the socket now. An accepted hello
		-- must stay open -- `request` is sent from the scheduled callback below.
		if not msg.ok then self:_close() end
		return
	end
	local entry = id and self.pending[id]
	if not entry then return end
	if entry.timer then pcall(function() entry.timer:stop(); entry.timer:close() end); entry.timer = nil end
	self.pending[id] = nil
	if msg.ok then
		local result = msg.result or {}
		vim.schedule(function() entry.cb(true, result, nil) end)
	else
		local code = msg.code or "error"
		local refusal = type(msg.result) == "table" and msg.result or {}
		vim.schedule(function() entry.cb(false, code, refusal) end)
	end
	self:_settle()
end
function Client:_on_data(_chan, data, _name)
	if data == nil or (type(data) == "table" and #data == 1 and data[1] == "") then
		self:_on_eof(); return
	end
	self.buf = (self.buf or "") .. table.concat(data, "\n")
	while true do
		local line, rest = self.buf:match("([^\n]*)\n(.*)")
		if not line then break end
		self.buf = rest
		if line ~= "" then self:_dispatch(line) end
	end
end
local function autostart_once()
	local root = state_root()
	local sha8 = sha8_of(root)
	local xdg = vim.env.XDG_RUNTIME_DIR
	vim.fn.mkdir(xdg and xdg ~= "" and (xdg .. "/yana") or string.format("/tmp/yana-%d", uv.getuid()), "p")
	local cmd = { repo_root() .. "/bin/yanad", "--root", root }
	local settled = false
	local function verdict(ok)
		if settled then return end
		settled = true
		if not ok then M.starters.setsid(cmd) end
	end
	local sync = M.starters.systemd_run("yanad-" .. sha8, cmd, verdict)
	if sync ~= nil then verdict(sync) end
end
function Client:_on_eof()
	local chan = self.chan
	self.chan, self.buf = nil, ""
	if chan then pcall(vim.fn.chanclose, chan) end
	if self._done then return end -- settled client: nothing to re-send, nothing to revive
	if not self._accepted then return end -- hello never succeeded: no reconnect, no autostart
	if self._reconnecting then return end
	self._reconnecting = true
	vim.defer_fn(function()
		self._reconnecting = false
		self:_reconnect()
	end, M.retry_ms)
end
function Client:_reconnect()
	if self._done then return end
	if self._reconnecting then return end
	self._reconnecting = true
	if self.chan then local stale = self.chan; self.chan = nil; pcall(vim.fn.chanclose, stale) end
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", M.sock_path(), {
		rpc = false,
		on_data = function(c, d, n) self:_on_data(c, d, n) end,
	})
	if not ok or type(chan) ~= "number" or chan == 0 then
		self._reconnect_failures = (self._reconnect_failures or 0) + 1
		-- Give an externally supervised daemon time to rebind before starting a
		-- replacement. Three failed dials still autostart quickly (60-600 ms under
		-- the tested retry seams) and prevents two servers racing for one socket.
		if self._reconnect_failures >= 3 and not self._eof_started then
			self._eof_started = true
			autostart_once()
		end
		self._reconnecting = false
		vim.defer_fn(function() self:_reconnect() end, M.retry_ms)
		return
	end
	self.chan = chan
	self._reconnect_failures = 0
	self.version = read_version()
	self._hello_id = "hello:" .. tostring(self.owner.pid) .. ":" .. tostring(uv.hrtime())
	self._hello_cb = function(hok)
		self._reconnecting = false
		if not hok then return end
		self._eof_started = false -- next EOF may autostart again
		for id, entry in pairs(self.pending) do
			self:_send({ v = 1, id = id, cmd = entry.cmd, args = entry.args or {}, owner = self.owner, version = self.version })
		end
	end
	self:_send({
		v = 1, id = self._hello_id, cmd = "hello",
		args = { kind = "nvim", servername = tostring(vim.v.servername or "") },
		owner = self.owner, version = self.version,
	})
end
function Client:request(cmd, args, id, cb)
	local entry = { cmd = cmd, args = args or {}, cb = cb }
	self.pending[id] = entry
	self:_send({ v = 1, id = id, cmd = cmd, args = entry.args, owner = self.owner, version = self.version })
	self:_arm_timeout(id, entry)
end
function M.connect(cb)
	local owner, version = owner_identity(), read_version()
	local hello_id = "hello:" .. tostring(owner.pid) .. ":" .. tostring(uv.hrtime())
	local client = setmetatable({
		owner = owner, version = version, pending = {}, buf = "", _hello_id = hello_id, _hello_cb = cb,
	}, Client)
	client._hello_cb = function(hok, res)
		if hok then client._accepted = true end
		cb(hok, res)
	end
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", M.sock_path(), {
		rpc = false,
		on_data = function(c, d, n) client:_on_data(c, d, n) end,
	})
	if not ok or type(chan) ~= "number" or chan == 0 then return cb(false, "connect_failed") end
	client.chan = chan
	client:_send({
		v = 1, id = hello_id, cmd = "hello",
		args = { kind = "nvim", servername = tostring(vim.v.servername or "") },
		owner = owner, version = version,
	})
end
function M.ensure(cb)
	local started_at = nil
	local function attempt(n)
		M.connect(function(ok, res)
			if ok then return cb(true, res) end
			-- Only a socket that is absent or refuses the connection may start a daemon;
			-- a hello refusal (version_mismatch, identity_mismatch, ...) is final.
			if res ~= "connect_failed" then return cb(false, res) end
			if not started_at then started_at = uv.now(); autostart_once() end
			-- The daemon we just started is still booting until its socket answers:
			-- keep dialling on the retry cadence until autostart_timeout_ms, and only
			-- then call it missing.
			if n >= M.retries and uv.now() - started_at >= M.autostart_timeout_ms then
				return cb(false, "no_daemon")
			end
			vim.defer_fn(function() attempt(n + 1) end, M.retry_ms)
		end)
	end
	attempt(0)
end
local function wrap(cmd)
	return function(args, id, cb)
		M.ensure(function(ok, client)
			-- THIRD ARGUMENT, ALWAYS. `client` here is the REASON ("no_daemon",
			-- "version_mismatch", ...), which the operator never saw. Carry it in the table so
			-- the refusal can name what actually happened.
			if not ok then return cb(false, client, { reason_code = client, unreachable = true }) end
			client:request(cmd, args or {}, id, cb)
		end)
	end
end
for _,_c in ipairs({"session.create","session.attach","session.delete","review.open","review.none","review.close","review.abort","file.claim","status","shutdown"}) do M[(_c:gsub("%.","_"))]=wrap(_c) end
function M.render_refusal(stderr_text, answer, prompt_opts)
	M.render_error(stderr_text)
	local refuse = type(answer) == "table" and answer.refuse
	if type(refuse) ~= "table" then return end
	local opts = {}
	for key, value in pairs(prompt_opts or {}) do opts[key] = value end
	if type(opts.dial) ~= "function" then
		opts.dial = function(path) return M.dial("pipe", path, { rpc = true }) end
	end
	require("yana.review_open_prompt").offer_from_refuse(refuse, opts)
end

return M
