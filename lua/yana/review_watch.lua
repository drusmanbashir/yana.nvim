-- One watcher instance coordinates one dependency set across attached buffers.
local diff = require("yana.diff")
local ownership_factory = require("yana.review_watch_ownership")
local batch_factory = require("yana.review_watch_batch")
local register_factory = require("yana.review_watch_register")
local flush_factory = require("yana.review_watch_flush")
local splice = require("yana.hunk_anchor_splice")
local timeline = require("yana.review_watch_timeline")

local Watcher = {}
Watcher.__index = Watcher

-- ONE BUFFER, ONE OWNING ATTACHMENT, NAMED BY A GENERATION. `nvim_buf_attach`
-- never replaces an earlier `on_bytes` callback, and a state flag cannot
-- arbitrate: the older one writes its ledger row first, onto a history a resumed
-- ledger has adopted. Every callback checks its generation here at its FIRST
-- line and detaches when it is not owner.
local owner_by_buf = {}
local next_generation = 0

--- Every sequence the undo tree can still land on, `alt` branches included.
--- Sequence 0 is the empty base state and is always reachable.
local function reachable_seqs(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, tree = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.undotree()
  end)
  if not ok or type(tree) ~= "table" then
    return nil
  end
  local seen = { [0] = true }
  local function walk(entries)
    for _, entry in ipairs(entries or {}) do
      if type(entry.seq) == "number" then
        seen[entry.seq] = true
      end
      walk(entry.alt)
    end
  end
  walk(tree.entries)
  return seen
end

local function clear_queue(state)
  if state then
    state.watch_pending = false
    state.watch_changes = {}
    state.watch_timeline = nil
    state._watch_in_insert = false
  end
end

--- One splice of Yana's own on `bufnr`, run with this buffer's watcher
--- suspended: the ledger still transports its geometry exactly once, only
--- interpretation is muted. The door for a caller outside the review holding no
--- `state`. Suspension is restored on both legs; a failure re-raises unchanged.
function Watcher.own_splice(bufnr, fn)
  local owner = bufnr and owner_by_buf[bufnr]
  local state = owner and owner.state
  if type(state) ~= "table" then
    return fn()
  end
  local previous = state.watch_suspended
  state.watch_suspended = true
  local ok, result = pcall(fn)
  state.watch_suspended = previous
  if not ok then
    error(result, 0)
  end
  return result
end

function Watcher.finalize(bufnr, state)
  if type(state) ~= "table" or not state.watch_timeline then return true end
  local owner = owner_by_buf[bufnr]
  if not owner or owner.state ~= state or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "watch timeline cannot finalize without its live buffer owner"
  end
  local finish = state.on_insert_leave_ownership
  if type(finish) ~= "function" then return false, "watch timeline has no finalizer" end
  local ok, err = pcall(finish)
  if not ok then return false, tostring(err) end
  if state.watch_timeline then return false, "watch timeline remained open after finalizer" end
  return true
end

--- MINTING IS NOT OWNING. The callbacks close over a generation number, so it
--- must exist before `nvim_buf_attach`; the OWNERSHIP entry it names must not,
--- because that call can answer false or raise.
local function mint_generation()
  next_generation = next_generation + 1
  return next_generation
end

--- Take the buffer under an already-minted generation, ONLY once the attachment
--- that generation names really exists.
local function install_generation(bufnr, state, generation)
  local previous = owner_by_buf[bufnr]
  -- Same state re-attaching (a reload restage) retires nothing, but still takes
  -- a NEW generation, which is what silences the callback it replaces.
  if previous and previous.state and previous.state ~= state then
    local done, err = Watcher.finalize(bufnr, previous.state)
    if not done then return false, err end
    previous.state.watch_detached = true
    clear_queue(previous.state)
  end
  owner_by_buf[bufnr] = { generation = generation, state = state }
  return true
end

--- Cleanup for ONE attachment, named by its generation so a callback that has
--- just retired cannot take the live owner's entry with it.
local function release_generation(bufnr, generation)
  local owner = owner_by_buf[bufnr]
  if owner and owner.generation == generation then
    clear_queue(owner.state)
    owner_by_buf[bufnr] = nil
    return true
  end
  return false
end

local function owns(bufnr, generation)
  local owner = owner_by_buf[bufnr]
  return owner ~= nil and owner.generation == generation
end

--- Park: the buffer stops having an absorbing owner and queued work dies with
--- the generation, having been queued against a ledger the park has sealed. A
--- park arriving after another review attached must not silence the live one.
function Watcher.invalidate(bufnr, state)
  local owner = owner_by_buf[bufnr]
  if not owner or (state ~= nil and owner.state ~= state) then
    return false
  end
  local done, err = Watcher.finalize(bufnr, owner.state)
  if not done then return false, err end
  clear_queue(owner.state)
  owner_by_buf[bufnr] = nil
  return true
end

--- Lifecycle teardown: THE cleanup path for the entry itself.
function Watcher.release(bufnr, state)
  local owner = owner_by_buf[bufnr]
  if not owner or (state ~= nil and owner.state ~= state) then
    return false
  end
  local done, err = Watcher.finalize(bufnr, owner.state)
  if not done then return false, err end
  clear_queue(owner.state)
  owner_by_buf[bufnr] = nil
  return true
end

--- The in-place resume hands the PARKED STATE back without rebuilding it, so it
--- must re-attach for real under a NEWLY MINTED generation: park removed the
--- ownership entry and the first parked edit uninstalled that callback. Only
--- `attach` mints what a fresh callback quotes; a buffer another review has
--- claimed is refused.
function Watcher.resume(bufnr, state)
  if not bufnr or type(state) ~= "table" then
    return false
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local owner = owner_by_buf[bufnr]
  if owner and owner.state ~= state then
    return false
  end
    -- `_watch_reattach` is published by `attach` alone, so its absence means the
    -- park took nothing away. A hook that runs and still leaves this state not
    -- owning the buffer IS a refusal. Both signals are needed; either alone
    -- accepts a dead review.
  local reattach = state._watch_reattach
  if type(reattach) ~= "function" then
    return true, "never-attached"
  end
  clear_queue(state)
  local ok, attached = pcall(reattach)
  if not ok or attached ~= true then
    return false, "reattach-failed"
  end
  if owns(bufnr, state._watch_generation) then
    return true, "reattached"
  end
  return false, "reattach-failed"
end

function Watcher._owner(bufnr)
  return owner_by_buf[bufnr]
end

function Watcher.new(deps)
  local self = setmetatable({ deps = deps }, Watcher)
  local register_rows = register_factory.new(deps)
  local push_buffer_edit = register_rows.push_buffer_edit
  local attach_structural = register_rows.attach_structural

  --- THE SEQUENCE MARKER: `undotree().seq_cur` read INSIDE the callback. Neovim
  --- seals a sequence AFTER the change, so this names the state the edit departs
  --- FROM, never the one it lands in; its only use is telling two native
  --- sequences apart. `deps.buf_undo_seq` needs `nvim_buf_call`, which a callback
  --- may not always make.
  local function callback_undo_marker(bufnr)
    if vim.api.nvim_get_current_buf() == bufnr then
      local ok, tree = pcall(vim.fn.undotree)
      if ok and type(tree) == "table" and type(tree.seq_cur) == "number" then
        return tree.seq_cur
      end
    end
    return (deps.buf_undo_seq and bufnr) and deps.buf_undo_seq(bufnr) or nil
  end

  --- Returns TRUE only when Neovim really installed the callback; callers read
  --- this, not the ownership table, which is written from it.
  local function attach(state)
    local bufnr = state.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    -- This attachment's name; INSTALLED only after `nvim_buf_attach` answers
    -- true.
    local generation = mint_generation()
    -- Published so `Watcher.resume` can name the attachment it left.
    state._watch_generation = generation

    local ownership = ownership_factory.new(bufnr, state)
    local edge_line_is_yana_owned = ownership.edge_line_is_yana_owned
    local interior_line_is_yana_owned = ownership.interior_line_is_yana_owned

    -- Published on `state` because review_hunk_split's `try_split` and
    -- hunk_extent's `classify` cannot reach this attach's upvalues.
    state._row_is_yana_owned = interior_line_is_yana_owned
    local batch = batch_factory.new({
      deps = deps,
      state = state,
      bufnr = bufnr,
      edge_line_is_yana_owned = edge_line_is_yana_owned,
      interior_line_is_yana_owned = interior_line_is_yana_owned,
    })
    state.watch_pending = false
    state.watch_detached = false
    -- `owns` binds the flush to THIS attachment's generation.
    local flush = flush_factory.new({
      deps = deps,
      state = state,
      owns = function()
        return owns(bufnr, generation)
      end,
      batch = batch,
      push_buffer_edit = push_buffer_edit,
      attach_structural = attach_structural,
      reachable_seqs = reachable_seqs,
      clear_queue = clear_queue,
      diff = diff,
    })
    local process_pending_watch = flush.process_pending_watch
    local on_insert_leave_ownership = flush.on_insert_leave_ownership
    state.on_insert_leave_ownership = on_insert_leave_ownership
    -- An `o` edit reaches on_bytes while Neovim still reports Normal mode, so
    -- InsertEnter seals that first callback into the same Insert session.
    state.on_insert_enter_ownership = function()
      if not owns(bufnr, generation) then return end
      state._watch_in_insert = true
      if state.watch_timeline then state.watch_timeline.insert_session = true end
    end

    state.flush_pending_watch = process_pending_watch
    -- THE re-attach route for an in-place resume: only `attach` reaches the
    -- upvalues a new attachment closes over.
    state._watch_reattach = function()
      return attach(state)
    end
    local attached_ok, attached = pcall(vim.api.nvim_buf_attach, bufnr, false, {
      -- ONE CALLBACK: `on_bytes` is the only position source. Neovim orders
      -- on_lines and on_bytes freely, so nothing pairs them; the classifiers
      -- read the same splice.
      on_bytes = function(_, _, _, sr, sc, _, oer, oec, _, ner, nec)
        -- FIRST LINE, before the ledger geometry write: a retired attachment
        -- must not touch a ledger or an adopted history, and returning true
        -- uninstalls this callback.
        if not owns(bufnr, generation) then
          return true
        end
        local s = splice.splice(sr, sc, oer, oec, ner, nec)
        if splice.is_noop(s) then
          return
        end
        local first, last_orig, last_new = splice.line_change(s)
        -- STAMPED HERE, not at flush time: only now is the state this change
        -- departs from still current. A BOUNDARY MARKER, not a sequence number.
        -- `barrier`: the reload rewrite.
        local change = {
          first = first,
          last_orig = last_orig,
          last_new = last_new,
          splice = s,
          undo_marker = callback_undo_marker(bufnr),
          barrier = state.reload_barrier or nil,
        }
        if not state.watch_suspended then
          if not state.watch_timeline then
            state.watch_timeline = timeline.new(state.staged_text, {
              fileformat = vim.bo[bufnr].fileformat,
              endofline = vim.bo[bufnr].endofline,
              bomb = vim.bo[bufnr].bomb,
            })
            state.watch_timeline.insert_session = state._watch_in_insert == true
            state.watch_timeline.generation = generation
            local ledger = state.hunk_ledger
            if ledger and ledger:is_open() then
              state.watch_timeline.ledger_before = vim.deepcopy(ledger)
              state.watch_timeline.members_before = state.watch_timeline.ledger_before.hunks
              state.watch_timeline.real_members = ledger:members()
              state.watch_timeline.seq_before = ledger:observed_buffer_seq()
              state.watch_timeline.history_before = ledger.buffer_history:batch_baseline()
              state.watch_timeline.model_before = vim.deepcopy(state.model_hunks)
              local workspace = state.change.review_workspace
                or (state.opts and state.opts.workspace) or vim.fn.getcwd()
              local register = require("yana.turn.turn_register").for_workspace(workspace)
              state.watch_timeline.register_before = {
                actions = register.actions, cursor = register.cursor, owed = register.owed,
              }
              state.watch_timeline.live_before = {}
            end
          end
          local mode = vim.api.nvim_get_mode().mode
          if type(mode) == "string" and mode:sub(1, 1) == "i" then
            state.watch_timeline.insert_session = true
          end
        else
          state.watch_timeline = nil
        end
        -- Stamp the rows this splice wrote with the sequence its edit DEPARTS
        -- FROM (`false` when unreadable), so InsertLeave can absorb before the
        -- coalesced flush and PARTITION that absorb by sequence (UNDO.md).
        local marker = change.undo_marker
        if marker == nil then marker = false end
        local dirty = splice.rows(s, state._ownership_dirty_rows)
        local lo, hi = splice.touched(s)
        for row = lo or 1, hi or 0 do
          dirty[row] = marker
        end
        state._ownership_dirty_rows = dirty
        local ledger = state.hunk_ledger
        if ledger and ledger:is_open() then
          -- The observed endpoints are interpretation's: only the timeline reads
          -- them. Transport through `record_buffer_change` stays unconditional.
          if state.watch_timeline then
            change._timeline_live_before = {}
            for i, block in ipairs(ledger:members()) do
              -- New text is visible, but Neovim has not moved extmarks when it
              -- invokes on_bytes. This is the actual PRE mark even for deletion.
              local first, last = deps.live_block_range(bufnr, block)
              assert(first ~= nil and last ~= nil,
                "watch timeline: no observed pre-edit authority range")
              local observed = { first = first, last = last,
                authority_id = block.authority_extmark_id,
                incoming_id = block.incoming_extmark_id }
              change._timeline_live_before[block] = observed
              if #state.watch_timeline.changes == 0 then
                state.watch_timeline.live_before[i] = observed
              else
                local previous = state.watch_timeline.changes[#state.watch_timeline.changes]
                local old = previous._timeline_live_before[block]
                assert(old and old.authority_id == observed.authority_id
                    and old.incoming_id == observed.incoming_id,
                  "watch timeline: authority mark rebound within queued batch")
                previous._timeline_live_after = previous._timeline_live_after or {}
                local sealed = previous._timeline_live_after[block]
                if sealed then
                  assert(sealed.first == observed.first and sealed.last == observed.last
                      and sealed.authority_id == observed.authority_id
                      and sealed.incoming_id == observed.incoming_id,
                    "watch timeline: prior endpoint mark changed between flushes")
                else
                  previous._timeline_live_after[block] = observed
                end
              end
            end
            state.watch_timeline:capture(change, bufnr)
          end
          local moved = ledger:record_buffer_change(change)
          for _, block in ipairs(moved) do
            if state.model_hunks and block.model_index and state.model_hunks[block.model_index] then
              state.model_hunks[block.model_index].new_end_line = block.new_end_line
            end
          end
        end
        require("yana.review_undo_trace").capture("bytes_transported", state, {
          marker = change.undo_marker, splice = change.splice, suspended = state.watch_suspended == true })
        -- Suspension mutes interpretation only. The ledger geometry callback
        -- above already consumed the edit, including native undo's inverse.
        if state.watch_suspended then
          return
        end
        state.watch_changes = state.watch_changes or {}
        state.watch_changes[#state.watch_changes + 1] = change
        if not state.restoring_reload then
          state.reload_redo_guard = nil
          state.reload_restore_seq = nil
        end
        if state.watch_detached or state.closed then
          return true
        end
        if state.watch_pending then
          return
        end
        state.watch_pending = true
        vim.schedule(process_pending_watch)
      end,
      -- Neovim's own end-of-attachment signal: wiped buffer, or the callback
      -- above retired itself. Either way the ownership entry goes with it.
      on_detach = function()
        release_generation(bufnr, generation)
      end,
    })
    if not attached_ok or attached ~= true then
      -- Neovim refused, or threw after part of its work, so nothing may own this
      -- buffer under this generation. `release_generation` is keyed by
      -- generation: a DIFFERENT live attachment here is left as it was.
      release_generation(bufnr, generation)
      clear_queue(state)
      return false
    end
    -- The attachment exists: only now does it own the buffer, only now is the one
    -- it replaces retired, and only now is the ADOPTED history touched -- an
    -- earlier `observe_buffer_seq` would advance it and then return false.
    if state.hunk_ledger and state.hunk_ledger:is_open() then
      state.hunk_ledger:observe_buffer_seq(deps.buf_undo_seq(bufnr))
    end
    local installed, install_err = install_generation(bufnr, state, generation)
    if not installed then
      clear_queue(state)
      require("yana.log").write("WARN", "watch attach: " .. tostring(install_err))
      return false
    end
    return true
  end

  self.attach = attach
  return self
end

return Watcher
