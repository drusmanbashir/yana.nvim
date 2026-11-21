-- Own one live Run's restricted MCP socket and authenticate its descendants.
local M = {}
local uv = vim.uv or vim.loop
local ffi = require("ffi")

ffi.cdef[[
typedef unsigned int yana_socklen_t;
struct yana_ucred { int pid; unsigned int uid; unsigned int gid; };
int getsockopt(int, int, int, void *, yana_socklen_t *);
unsigned int getuid(void);
]]

local SOL_SOCKET, SO_PEERCRED = 1, 17

local process_identity = require("yana.runtime.yanad").process_identity

local function peer_credentials(client)
  local fd = client:fileno()
  if not fd then return nil end
  local cred = ffi.new("struct yana_ucred[1]")
  local size = ffi.new("yana_socklen_t[1]", ffi.sizeof(cred[0]))
  if ffi.C.getsockopt(fd, SOL_SOCKET, SO_PEERCRED, cred, size) ~= 0 then return nil end
  local pid, uid = tonumber(cred[0].pid), tonumber(cred[0].uid)
  local identity = process_identity(pid)
  if not identity or identity.uid ~= uid then return nil end
  return { pid = pid, uid = uid, start = identity.start }
end

local function root_matches(root)
  local live = process_identity(root.pid)
  return live and live.start == root.start and live.uid == root.uid
end

local function authorized(peer, root)
  if not (peer and root) or peer.uid ~= root.uid or peer.uid ~= tonumber(ffi.C.getuid()) or not root_matches(root) then
    return false
  end
  local peer_identity = process_identity(peer.pid)
  if not peer_identity or peer_identity.start ~= peer.start then return false end
  local pid, seen = peer.pid, {}
  while pid and pid > 1 and not seen[pid] do
    if pid == root.pid then return root_matches(root) end
    seen[pid] = true
    local current = process_identity(pid)
    if not current or (pid == peer.pid and current.start ~= peer.start) then return false end
    pid = current.ppid
  end
  return false
end

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

function M.new(context, runtime_dir)
  local nonce = vim.fn.sha256(tostring(uv.os_getpid()) .. tostring(uv.hrtime())):sub(1, 6)
  local tag = context.yanad_session_id and context.turn_id
    and vim.fn.sha256(context.yanad_session_id .. "/" .. context.turn_id):sub(1, 16) or ""
  local dir = (runtime_dir or uv.os_tmpdir()) .. "/ym" .. tag .. nonce
  local path = dir .. "/m.sock"
  -- A Unix socket path holds at most 107 bytes; past that the agent's MCP server
  -- cannot connect and the Run fails with no proposal. Say why instead.
  if #path > 107 then
    return nil, "MCP socket path is " .. #path .. " bytes, over the 107-byte Unix limit; use a shorter state root: " .. path
  end
  local created, err = uv.fs_mkdir(dir, 448)
  if not created then return nil, err end
  local server = uv.new_pipe(false)
  local owner = { context = context, server = server, clients = {}, dir = dir, path = path, closed = false }

  local function close_clients()
    for client in pairs(owner.clients) do
      owner.clients[client] = nil
      close_handle(client)
    end
  end

  function owner:bind_root(pid)
    if self.closed or self.root or pid == uv.os_getpid() then return false end
    local identity = process_identity(pid)
    if not identity then return false end
    self.root = { pid = pid, start = identity.start, uid = identity.uid }
    return true
  end

  function owner:start()
    if self.closed then return nil, "socket host is closed" end
    local ok, why = server:bind(path)
    if not ok then self:close(); return nil, why end
    uv.fs_chmod(path, 384)
    local listening, listen_err = server:listen(32, function(listen_error)
      if listen_error or owner.closed then return end
      local client = uv.new_pipe(false)
      local accepted = server:accept(client)
      if not accepted then close_handle(client); return end
      owner.clients[client] = true
      local peer = peer_credentials(client)
      local input = ""
      uv.read_start(client, function(read_error, chunk)
        if read_error or chunk == nil then
          owner.clients[client] = nil
          close_handle(client)
          return
        end
        input = input .. chunk
        while true do
          local line, rest = input:match("^([^\n]*)\n(.*)$")
          if not line then break end
          input = rest
          local ok_json, request = pcall(vim.json.decode, line)
          vim.schedule(function()
            local response
            if owner.closed or not authorized(peer, owner.root) then
              response = { id = type(request) == "table" and request.id or -1,
                error = { code = "unauthorized_peer", message = "MCP client is not a live descendant of this run" } }
            elseif not ok_json or type(request) ~= "table" then
              response = { id = -1, error = { code = "invalid_request", message = "host request is not valid JSON" } }
            else
              context:handle(request, function(reply)
                if owner.closed or not owner.clients[client] or not authorized(peer, owner.root) then return end
                client:write(vim.json.encode(reply) .. "\n")
              end)
              return
            end
            if not client:is_closing() then client:write(vim.json.encode(response) .. "\n") end
          end)
        end
      end)
    end)
    if not listening then self:close(); return nil, listen_err end
    return true
  end

  function owner:close()
    if self.closed then return false end
    self.closed = true
    self.root = nil
    close_clients()
    close_handle(server)
    uv.fs_unlink(path)
    uv.fs_rmdir(dir)
    return true
  end

  return owner
end

return M
