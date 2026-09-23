-- One listener group per reviewed buffer.
local M = {}

local next_group_id = 0
local AUTOCMD_EVENTS = {
  "BufReadPost", "BufWinEnter", "BufEnter", "TextChanged", "TextChangedI",
  "CmdlineLeave", "BufWipeout", "BufDelete", "BufUnload",
}

local function schedule_event(group, kind)
  if group.detached or group.pending_set[kind] then
    return
  end
  group.pending_set[kind] = true
  group.pending_kinds[#group.pending_kinds + 1] = kind
  if group.scheduled then
    return
  end
  group.scheduled = true
  vim.schedule(function()
    local kinds = group.pending_kinds
    local ok, err = pcall(function()
      if group.detached then
        return
      end
      for i = 1, #kinds do
        group.handlers.on_buffer_event(group.bufnr, kinds[i])
      end
    end)
    -- Keep the queue live through handler execution. A handler's own edit is
    -- therefore coalesced into this drain instead of rearming another tick.
    group.pending_kinds = {}
    group.pending_set = {}
    group.scheduled = false
    if not ok then
      error(err)
    end
  end)
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and bufnr > 0
    and vim.api.nvim_buf_is_valid(bufnr)
end

function M.attach(bufnr, handlers)
  if not valid_buffer(bufnr) then
    return nil, "invalid buffer"
  end
  if type(handlers) ~= "table" or type(handlers.on_buffer_event) ~= "function" then
    return nil, "on_buffer_event handler required"
  end

  next_group_id = next_group_id + 1
  local group = {
    bufnr = bufnr,
    handlers = handlers,
    pending_kinds = {},
    pending_set = {},
    scheduled = false,
    detached = false,
    augroup = vim.api.nvim_create_augroup("YanaTurnListeners" .. next_group_id, { clear = true }),
  }

  local on_lines = function()
    if group.detached then
      return true
    end
    schedule_event(group, "on_lines")
  end
  local attached, attach_result = pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_lines = on_lines,
  })
  if not attached or attach_result ~= true then
    group.detached = true
    vim.api.nvim_del_augroup_by_id(group.augroup)
    return nil, attached and "nvim_buf_attach returned false" or attach_result
  end

  local autocmd_ok, autocmd_err = pcall(vim.api.nvim_create_autocmd, AUTOCMD_EVENTS, {
    group = group.augroup,
    buffer = bufnr,
    callback = function(args)
      schedule_event(group, args.event)
    end,
  })
  if not autocmd_ok then
    group.detached = true
    pcall(vim.api.nvim_del_augroup_by_id, group.augroup)
    return nil, autocmd_err
  end
  return group
end

function M.detach(group)
  if type(group) ~= "table" or group.detached then
    return true
  end
  group.detached = true
  if group.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, group.augroup)
    group.augroup = nil
  end
  return true
end

return M
