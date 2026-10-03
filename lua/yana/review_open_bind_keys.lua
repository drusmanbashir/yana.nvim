-- Buffer-local review keymaps -- split out of review_open_bind.lua to hold it under the
-- 500-line ceiling (S2 P-C, action 14).
local M = {}

-- Turn-history guard, one owner for every Turn file buffer without live review keys while the Turn lives:
-- `u`/`<C-r>`/`U` go to the Turn walk (a parked member's own review, else any live member's), so raw native
-- history never runs in a file the Turn's history names. A parked member (kind=parked) also guards its
-- decision keys so `c*` cannot edit text; a file that left the Turn (kind=history, e.g. a joined file a
-- follow-up undo withdrew) guards only the history keys. The Turn remembers every attached path.
local queued_maps, queued_group, queued_kind = {}, nil, {}
local HISTORY_KEYS = { u = "undo_key", ["<C-r>"] = "redo_key", U = "undo_turn" }

local function queued_keys(kind)
	local out = {}
	if kind == "parked" then
		local m = require("yana.config").options.mappings
		-- A mapping set to false or "" is disabled: never registered.
		for _, lhs in ipairs({ m.reject_hunk, m.accept_hunk, m.accept_file, m.accept_all, m.reject_file, "cR" }) do
			if type(lhs) == "string" and lhs ~= "" then out[#out + 1] = lhs end
		end
	end
	out[#out + 1], out[#out + 2], out[#out + 3] = "u", "<C-r>", "U"
	return out
end

-- The review selected by the current or previous window; parked members keep
-- a review_state but do not count as live attachments.
local function active_rel_of(_turn)
	local st = require("yana.inline_diff").active_state()
	local change = st and st.change
	return change and (change.rel or change.path) or nil
end

local function drop_queued(bufnr)
	for lhs, handler in pairs(queued_maps[bufnr] or {}) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			for _, mode in ipairs({ "n", "v" }) do
				local cur = vim.api.nvim_buf_call(bufnr, function() return vim.fn.maparg(lhs, mode, false, true) end)
				if cur.buffer == 1 and cur.callback == handler then pcall(vim.keymap.del, mode, lhs, { buffer = bufnr }) end
			end
		end
	end
	queued_maps[bufnr] = nil
	queued_kind[bufnr] = nil
end

local function queued_handler(turn, f, lhs, kind)
	return function()
		local rel, active = (f.change and f.change.rel) or f.path, active_rel_of(turn) or "the active review"
		local hint = "%s's review is parked: press ]x in %s"
		require("yana.notify").one_line(string.format(hint, rel, active), vim.log.levels.INFO)
		require("yana.log").lifecycle_info("review.key_noop", { key = lhs, rel = rel, reason = kind,
			active_rel = active_rel_of(turn), turn_id = f.change and tostring(f.change.turn_id), generation =
			f.change and f.change.turn_gen, panel_id = f.change and f.change.panel_id })
	end
end

-- A history key in a guarded buffer: the parked review's own door, else any live member's (one Turn walk).
local function history_handler(lhs, w)
	return function()
		local state = w.state
		if not state then
			local pool = require("yana.turn.turn_bind").live_pool()
			state = require("yana.review_context").state_for_buf(pool)
		end
		local action = state and state._ops and state._ops[HISTORY_KEYS[lhs]]
		if type(action) ~= "function" then
			return require("yana.notify").one_line("yana: no review of this turn is open to walk", vim.log.levels.INFO)
		end
		require("yana.log").guard("yana.inline_diff turn history", action)
	end
end

--- Map guarded buffers (parked members, files that left the live Turn), unmap the rest; no live Turn unmaps all.
function M.sync_queued()
	local turn = require("yana.turn.turn_bind").get()
	local live = turn ~= nil and turn:is_live()
	local want = {}
	for _, f in ipairs(live and turn.files or {}) do
		local bufnr = f.path and vim.fn.bufnr(f.path) or -1
		if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and f.change ~= nil then
			local parked = f.change._parked_state
			if type(parked) == "table" and not parked.closed then
				want[bufnr] = { f = f, kind = "parked", state = parked }
			end
		end
	end
	local pool = live and require("yana.turn.turn_bind").live_pool() or nil
	for path in pairs(pool and turn:reviewed_paths() or {}) do
		local bufnr = vim.fn.bufnr(path)
		if bufnr > 0 and want[bufnr] == nil and vim.api.nvim_buf_is_loaded(bufnr)
			and require("yana.review_context").state_for_buf(pool, bufnr) == nil then
			want[bufnr] = { kind = "history" }
		end
	end
	for bufnr in pairs(queued_maps) do
		if not want[bufnr] or queued_kind[bufnr] ~= want[bufnr].kind then drop_queued(bufnr) end
	end
	for bufnr, w in pairs(want) do
		local f, kind = w.f, w.kind
		if queued_maps[bufnr] == nil then
			queued_kind[bufnr] = kind
			queued_maps[bufnr] = {}
			for _, lhs in ipairs(queued_keys(kind)) do
				local handler = HISTORY_KEYS[lhs] and history_handler(lhs, w) or queued_handler(turn, f, lhs, kind)
				vim.keymap.set({ "n", "v" }, lhs, handler, { buffer = bufnr, nowait = true, silent = true,
					desc = kind == "parked" and "yana: this file's review is parked" or "yana: walk this turn's history" })
				queued_maps[bufnr][lhs] = handler
			end
		end
	end
	if live and not queued_group then
		queued_group = vim.api.nvim_create_augroup("YanaQueuedReviewKeys", { clear = true })
		vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, { group = queued_group,
			callback = function() M.sync_queued() end })
		turn:register({ name = "queued_keys", turn_end = function()
			for bufnr in pairs(queued_maps) do drop_queued(bufnr) end
			pcall(vim.api.nvim_del_augroup_by_id, queued_group)
			queued_group = nil
		end })
	end
end

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
      require("yana.review_undo_trace").capture(point .. "_before", state, { key = key })
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
  vim.schedule(M.sync_queued)
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
