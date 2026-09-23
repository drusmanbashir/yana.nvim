-- Attachment lifetime for ONE inline review state: who owns a buffer's review
-- resources, what a park may release, and what a close may touch.
--
-- A buffer number is not an identity: a closing Turn must not strip a NEWER
-- review's marks/maps/highlighting on the same buffer, so every shared resource
-- is released only while `is_current(state)` holds.
--   claim      takes the buffer and mints the augroup FIRST.
--   is_current guard for immediate repaint and scheduled `Ledger:on_dirty`.
--   park       NONTERMINAL: keeps ownership and save handlers; releases keys,
--              preview tab and watcher attachment.
--   close      terminal, idempotent.
-- `close` always deletes the state's own augroup (it holds only this state's
-- handlers). Hooks carry the ACTUAL resources; never rediscover them via
-- `vim.fn.bufnr(file.path)` (a path resolves to whatever buffer holds the name).

local M = {}

--- Buffer-owner table: `owners[bufnr] = { state, hooks, augroup, name }`.
--- Not `review_watch`'s table: park drops the watcher's entry while this review
--- still owns its keys, marks and save handlers.
local owners = {}

--- Augroup names are unique per STATE: a rebuild reopens the same change and
--- `clear = true` would hand the replacement the retired group.
local next_claim = 0

local function buf_valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Nil-safe: `owners[nil]` reads nil.
local function owner_for(state)
  local owner = owners[state.bufnr]
  if owner ~= nil and owner.state == state then
    return owner
  end
  return nil
end

local function key_spec(spec)
  if type(spec) ~= "table" then
    return nil, nil
  end
  local lhs = spec.lhs or spec[1]
  local modes = spec.modes or (spec.mode ~= nil and { spec.mode }) or nil
  return lhs, modes
end

--- Malformed hooks are refused at claim time (else a silent leak at close).
local function validate_hooks(hooks)
  if type(hooks) ~= "table" then
    return false, "claim refused: hooks must be a table of {keys, namespaces, restore_windows, forget_rewind}"
  end
  if hooks.keys ~= nil and type(hooks.keys) ~= "table" then
    return false, "claim refused: hooks.keys must be a list of key specifications"
  end
  for i, spec in ipairs(hooks.keys or {}) do
    local lhs, modes = key_spec(spec)
    if type(lhs) ~= "string" or lhs == "" then
      return false, string.format("claim refused: hooks.keys[%d] names no lhs", i)
    end
    if type(modes) ~= "table" or #modes == 0 then
      return false, string.format("claim refused: hooks.keys[%d] (%s) names no modes", i, lhs)
    end
    for _, mode in ipairs(modes) do
      if type(mode) ~= "string" or mode == "" then
        return false, string.format("claim refused: hooks.keys[%d] (%s) has a non-string mode", i, lhs)
      end
    end
  end
  if hooks.namespaces ~= nil and type(hooks.namespaces) ~= "table" then
    return false, "claim refused: hooks.namespaces must be a list of namespace ids"
  end
  for i, ns in ipairs(hooks.namespaces or {}) do
    if type(ns) ~= "number" then
      return false, string.format("claim refused: hooks.namespaces[%d] is not a namespace id", i)
    end
  end
  for _, name in ipairs({ "restore_windows", "forget_rewind" }) do
    if hooks[name] ~= nil and type(hooks[name]) ~= "function" then
      return false, string.format("claim refused: hooks.%s must be a function bound to this state", name)
    end
  end
  return true
end

local function unbind_keys(bufnr, keys)
  if not buf_valid(bufnr) then
    return
  end
  for _, spec in ipairs(keys or {}) do
    local lhs, modes = key_spec(spec)
    if lhs and modes then
      for _, mode in ipairs(modes) do
        pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
      end
    end
  end
end

--- The preview tab/scratch belong to THIS state; a leaked scratch keeps
--- "yana://diff-theme-preview" and breaks the next `nvim_buf_set_name`. Resolve the
--- tab number at teardown; never close the last tab (E784).
local function release_preview(state)
  if state.preview_tab and vim.api.nvim_tabpage_is_valid(state.preview_tab) then
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose! " .. vim.api.nvim_tabpage_get_number(state.preview_tab))
    end
    state.preview_tab = nil
  end
  if state.opts and state.opts.preview and buf_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
end

--- The strip is the SIDEBAR's; park and close only re-render it.
local function refresh_button_strip()
  pcall(function()
    require("yana.panel.ui_review_buttons").refresh()
  end)
end

--- Windows this state put highlighting on (`state.winhl_restore`) that are still
--- valid and still show this state's buffer.
local function owned_windows(state)
  local out = {}
  if type(state.winhl_restore) ~= "table" then
    return out
  end
  for win, previous in pairs(state.winhl_restore) do
    if type(win) == "number" and vim.api.nvim_win_is_valid(win) then
      local ok, wbuf = pcall(vim.api.nvim_win_get_buf, win)
      if ok and wbuf == state.bufnr then
        out[#out + 1] = { win = win, winhl = previous }
      end
    end
  end
  return out
end

--- The shared palette dies with the LAST live owner.
local function another_live_owner()
  for _, owner in pairs(owners) do
    if owner.state ~= nil and not owner.state.closed then
      return true
    end
  end
  return false
end

--- Take `state.bufnr` for `state` and mint its augroup.
--- hooks = { keys = {{lhs, modes}}, namespaces = {ids}, restore_windows =
---   function(request{windows, clear_palette}), forget_rewind = function() }
--- Hooks restore editor state only; no disk writes.
--- Returns `true`, or `false, reason` for malformed hooks or a DIFFERENT live
--- owner. Re-claim by the same state retires its previous group.
function M.claim(state, hooks)
  if type(state) ~= "table" then
    return false, "claim refused: a review state is required"
  end
  if state.closed then
    return false, "claim refused: this review state is already closed"
  end
  local bufnr = state.bufnr
  if not buf_valid(bufnr) then
    return false, "claim refused: this review state names no live buffer"
  end
  local ok, reason = validate_hooks(hooks)
  if not ok then
    return false, reason
  end
  local live = owners[bufnr]
  if live ~= nil and live.state ~= state and not live.state.closed then
    return false,
      string.format("claim refused: buffer %d is owned by a live review (%s)", bufnr, tostring(live.name))
  end

  -- Augroup first: every handler goes in this group so `close` can delete them all.
  next_claim = next_claim + 1
  local name = string.format("YanaReviewResources%d", next_claim)
  local created, group = pcall(vim.api.nvim_create_augroup, name, { clear = true })
  if not created then
    return false, "claim refused: could not create the review augroup: " .. tostring(group)
  end
  if live ~= nil and live.state == state and live.augroup ~= nil and live.augroup ~= group then
    pcall(vim.api.nvim_del_augroup_by_id, live.augroup)
  end
  state.augroup = group
  owners[bufnr] = { state = state, hooks = hooks, augroup = group, name = name }
  return true
end

--- Deny by default: an unclaimed buffer has no owner. Parking keeps ownership.
function M.is_current(state)
  if type(state) ~= "table" or state.closed then
    return false
  end
  if not buf_valid(state.bufnr) then
    return false
  end
  return owner_for(state) ~= nil
end

--- Park: navigation away while the review stays alive. Retains owner entry,
--- augroup (save handlers), ledger, marks, winhl. Releases the watcher
--- attachment (and its queued work), buffer-local keys and preview tab.
--- Never sets `state.closed`, deletes the augroup or gives up ownership.
function M.park(state)
  if type(state) ~= "table" then
    return false, "park refused: a review state is required"
  end
  if state.closed then
    return false, "park refused: this review state is closed"
  end
  local owner = owner_for(state)
  if state.bufnr then
    local watch = require("yana.review_watch")
    local finalized, reason = watch.finalize(state.bufnr, state)
    if not finalized then return false, "park refused: " .. tostring(reason) end
    local invalidated, invalidate_reason = watch.invalidate(state.bufnr, state)
    if invalidated == false and invalidate_reason then
      return false, "park refused: " .. tostring(invalidate_reason)
    end
  end
  refresh_button_strip()
  release_preview(state)
  -- Only the owner unbinds keys: a newer review's maps share the same lhs.
  if owner ~= nil then
    unbind_keys(state.bufnr, owner.hooks.keys)
  end
  return true
end

--- Close: terminal, idempotent, and RETRYABLE. `state.closed` is the answer to
--- "is every required resource released", so it is set at the END and only when
--- they are. Setting it first, then suppressing the teardown failures with
--- `pcall`, made a refused close look complete: the retry hit the `closed`
--- guard, returned true, and the leaked resource was never released
--- and a failed ordered step must remain repairable.
---
--- `watch_detached` is what stops the scheduled render, and it still happens
--- first -- that is the job the early `closed` was really doing.
---
--- Shared resources are released ONLY while this state is the owner; the
--- state's own augroup is released either way. Best-effort teardown stays
--- best-effort and is named as such; only the releases a leak depends on can
--- refuse the close.
--- Each release runs AT MOST ONCE across retries. A step that succeeded is
--- recorded on the state and skipped by the next call: retrying an augroup
--- delete that already worked raises E367, which would make a retry fail on
--- work it had finished rather than on the resource still held.
---
--- The teardown is ordered against the ANSWER, not just against itself. Only
--- the releases that can refuse the close run before it; unbinding the review's
--- keys, retiring the undo trace and dropping the owner entry run after, so a
--- refusal leaves the operator a review they can still answer and retry.
local function release_once(state, name, fn)
  state.released = state.released or {}
  if state.released[name] then return true end
  local ok, err = pcall(fn)
  if not ok then return false, err end
  state.released[name] = true
  return true
end

function M.close(state)
  if type(state) ~= "table" then
    return false, "close refused: a review state is required"
  end
  if state.closed then
    return true
  end
  local bufnr = state.bufnr
  local owner = owner_for(state)
  if bufnr then
    local watch = require("yana.review_watch")
    local finalized, reason = watch.finalize(bufnr, state)
    if not finalized then return false, "close refused: " .. tostring(reason) end
    local released, release_reason = watch.release(bufnr, state)
    if released == false and release_reason then
      return false, "close refused: " .. tostring(release_reason)
    end
  end

  -- Stops the watcher's scheduled render before teardown.
  state.watch_detached = true
  local unreleased = {}
  local function try(name, fn)
    local ok, err = release_once(state, name, fn)
    if not ok then unreleased[#unreleased + 1] = name .. ": " .. tostring(err) end
  end
  refresh_button_strip()
  release_preview(state)

  -- ONLY the required releases run before the answer. Everything that gives the
  -- buffer back to the operator waits until the answer is yes.
  if owner ~= nil then
    local hooks = owner.hooks
    -- Path-keyed: forget even if the buffer is gone, else plain undo reads as a review action.
    if hooks.forget_rewind then
      try("rewind", hooks.forget_rewind)
    end
    if buf_valid(bufnr) then
      for i, ns in ipairs(hooks.namespaces or {}) do
        try("namespace[" .. i .. "]", function()
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end)
      end
    end
  end

  -- Always: this group holds only this state's handlers.
  if state.augroup then
    try("augroup", function()
      vim.api.nvim_del_augroup_by_id(state.augroup)
    end)
  end

  -- THE ANSWER, and the owner goes with it. A leaked namespace, augroup or
  -- rewind hook means the close is NOT done: `closed` stays false AND the
  -- owner entry is retained, because dropping it would make the next call skip
  -- the very hook that failed and report a success nobody earned. The caller
  -- may call again; only the steps still owed run.
  if #unreleased > 0 then
    return false, "close incomplete, resources still held -- " .. table.concat(unreleased, "; ")
  end

  if owner ~= nil then
    local hooks = owner.hooks
    if buf_valid(bufnr) then
      -- The End keys go LAST. A refused close leaves the review live, and a
      -- live review the operator cannot answer -- no `cR`, no `cA` -- is worse
      -- than the leak that refused it. They are released on the retry that
      -- earns it, with the rest of the teardown.
      unbind_keys(bufnr, hooks.keys)
      -- Returns `u`/`U`/`<C-r>` to Neovim; keyed by state.
      pcall(function()
        require("yana.review_undo_trace").close(state)
      end)
    end
    -- A reused buffer number must not inherit the old highlighting profile.
    if bufnr then
      pcall(require("yana.review_reread_highlight").forget, bufnr)
    end
    -- owner_for proved the entry is ours; never drop a newer owner's entry.
    owners[bufnr] = nil
    if hooks.restore_windows then
      pcall(owner.hooks.restore_windows, {
        windows = owned_windows(state),
        clear_palette = not another_live_owner(),
      })
    end
  end
  state.closed = true
  return true
end

return M
