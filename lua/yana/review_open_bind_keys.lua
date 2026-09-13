-- Buffer-local review keymaps -- split out of review_open_bind.lua to hold it under the
-- 500-line ceiling (S2 P-C, action 14).
local M = {}

--- `deps`: { state, opts, maps, km, log, facade, reject_hunk, accept_hunk,
--- accept_all, accept_everything, reject_all, undo_key, undo_turn, redo_key }
function M.bind(deps)
  local state = deps.state
  local opts = deps.opts
  local maps = deps.maps
  local km = deps.km
  local log = deps.log
  local facade = deps.facade

  -- Wrap only at the keymap.set call, not the underlying functions: those
  -- (reject_hunk, accept_hunk, ...) are also exposed unwrapped via M._test,
  -- and must keep returning their real values there.
  local function guarded(ctx, fn)
    return function(...)
      log.guard(ctx, fn, ...)
    end
  end
  local function traced(point, key, fn)
    return function(...)
      local result = fn(...)
      require("yana.review_undo_trace").capture(point, state, { key = key })
      return result
    end
  end
  state._key_defs = {}
  local function bound_set(modes, key, handler, kmopts)
    vim.keymap.set(modes, key, handler, kmopts)
    state._key_defs[#state._key_defs + 1] = { modes = modes, key = key, handler = handler, kmopts = kmopts }
  end
  if opts.preview then
    return
  end
  bound_set({ "n", "v" }, maps.reject_hunk, guarded("yana.inline_diff reject_hunk", deps.reject_hunk), vim.tbl_extend("force", km, { desc = "yana: reject hunk (ours)" }))
  bound_set({ "n", "v" }, maps.accept_hunk, guarded("yana.inline_diff accept_hunk", deps.accept_hunk), vim.tbl_extend("force", km, { desc = "yana: accept hunk (theirs)" }))
  bound_set({ "n", "v" }, maps.accept_file, guarded("yana.inline_diff accept_all", deps.accept_all), vim.tbl_extend("force", km, { desc = "yana: accept all hunks" }))
  bound_set({ "n", "v" }, maps.accept_all, guarded("yana.inline_diff accept_everything", deps.accept_everything), vim.tbl_extend("force", km, { desc = "yana: accept ALL changes (whole turn)" }))
  bound_set({ "n", "v" }, maps.reject_file, guarded("yana.inline_diff reject_all", deps.reject_all), vim.tbl_extend("force", km, { desc = "yana: reject file" }))
  -- cR: whole-review abort. Hardcoded, not a `maps.xxx` dial (see the `keys` table in
  -- review_open_bind.lua); not wrapped by `guarded()` above either: M.abort_active
  -- needs `opts` (this review's pool), which none of the zero-argument decision
  -- primitives above carry.
  bound_set({ "n", "v" }, "cR", function()
    log.guard("yana.inline_diff abort_active", function()
      facade.abort_active(opts)
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: abort the whole review (undo everything, confirmed first)" }))
  bound_set({ "n", "v" }, "cU", function()
    log.guard("yana.inline_diff reset_active_review", function()
      facade.reset_active_review()
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: reset the whole turn to the state the review opened in" }))
  -- `u` and `U`, buffer-local and only while this review is open. `u` hands
  -- to Neovim's own undo whenever the newest thing in the tree is the
  -- human's edit, and takes a decision back only when the newest thing is
  -- one of this review's own. Both are released by M.cleanup with the rest
  -- of state.keys, after which the buffer has the editor's `u` and `U` back.
  bound_set({ "n", "v" }, "u", guarded("yana.inline_diff undo_key", traced("key_u", "u", deps.undo_key)), vim.tbl_extend("force", km, { desc = "yana: undo (human edit, else take back the last hunk decision)" }))
  bound_set({ "n", "v" }, "U", guarded("yana.inline_diff undo_turn", deps.undo_turn), vim.tbl_extend("force", km, { desc = "yana: take back every hunk decision in this review" }))
  bound_set({ "n", "v" }, "<C-r>", guarded("yana.inline_diff redo_key", traced("key_redo", "<C-r>", deps.redo_key)), vim.tbl_extend("force", km, { desc = "yana: redo (repaints the review afterwards)" }))
  bound_set({ "n", "v" }, maps.next_hunk, function()
    log.guard("yana.inline_diff next hunk", function()
      facade._navigate_or_park_state(state, "next")
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: next hunk" }))
  bound_set({ "n", "v" }, maps.prev_hunk, function()
    log.guard("yana.inline_diff prev hunk", function()
      facade._navigate_or_park_state(state, "prev")
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: prev hunk" }))
end

return M
