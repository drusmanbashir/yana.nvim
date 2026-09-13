-- One watcher instance coordinates one dependency set across attached buffers.
local diff = require("yana.diff")
local ownership_factory = require("yana.review_watch_ownership")
local batch_factory = require("yana.review_watch_batch")
local register_factory = require("yana.review_watch_register")
local flush_factory = require("yana.review_watch_flush")
local splice = require("yana.hunk_anchor_splice")

local Watcher = {}
Watcher.__index = Watcher

-- ONE BUFFER, ONE OWNING ATTACHMENT, NAMED BY A GENERATION. Neovim installs a
-- new `on_bytes` callback per `nvim_buf_attach` and never replaces the previous
-- one, so a resume, a rebuild and a same-state reload restage leave several
-- live callbacks on the same buffer. A flag on the state cannot arbitrate
-- between them: the older callback ran its ledger write BEFORE reading the
-- flag, which is how one stale `record_buffer_change` still landed after its
-- state was retired -- and, since a resumed ledger now ADOPTS the parked
-- history object, that stale write reaches the LIVE history.
--
-- The generation is the arbitration. `attach` mints one and stores it here;
-- every callback compares its own against the stored one at its FIRST line,
-- before any ledger or history write, and detaches itself when it is not the
-- owner. Park invalidates the entry (no owner at all until an attach installs
-- one) and lifecycle cleanup removes it, so this table holds one small entry
-- per LIVE attachment rather than one state per buffer for the session.
local owner_by_buf = {}
local next_generation = 0

--- Every sequence the buffer's undo tree can still land on, `alt` branches
--- included. Sequence 0 is the empty base state and is always reachable.
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
  end
end

--- MINTING IS NOT OWNING. The callbacks below close over a generation number,
--- so the number must exist before `nvim_buf_attach` is called -- but the
--- OWNERSHIP entry that number names must not, because `nvim_buf_attach` can
--- answer false and can raise. Installing first made ownership a synthetic
--- claim that outlived the failure: `Watcher.resume` consulted it, found this
--- state owning the buffer, and accepted a review with no callback on it at
--- all. Measured on the real watcher with `nvim_buf_attach` stubbed to false:
--- `ATTACH_FALSE pcall=true resume=true reason=reattached owner=true`, and with
--- it stubbed to raise, `owner=true` was left STRANDED behind the throw.
local function mint_generation()
  next_generation = next_generation + 1
  return next_generation
end

--- Take the buffer under an already-minted generation. Called ONLY once the
--- attachment the generation names really exists.
local function install_generation(bufnr, state, generation)
  local previous = owner_by_buf[bufnr]
  -- Same state re-attaching (a reload restage) retires nothing -- but it still
  -- takes a NEW generation, which is what silences the callback it replaces.
  if previous and previous.state and previous.state ~= state then
    previous.state.watch_detached = true
    clear_queue(previous.state)
  end
  owner_by_buf[bufnr] = { generation = generation, state = state }
  return generation
end

--- Cleanup for ONE attachment, named by its generation so a callback that has
--- just retired itself cannot take the live owner's entry with it.
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

--- Park: the buffer stops having an absorbing owner. Queued work dies with the
--- generation, because a change queued before the park would otherwise be
--- interpreted against a ledger the park has already sealed.
--- `state`, when given, is the parking review: a park that arrives AFTER
--- another review has already attached to the same buffer must not silence the
--- live one. Same guard as `release`.
function Watcher.invalidate(bufnr, state)
  local owner = owner_by_buf[bufnr]
  if not owner or (state ~= nil and owner.state ~= state) then
    return false
  end
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
  clear_queue(owner.state)
  owner_by_buf[bufnr] = nil
  return true
end

--- The in-place resume (review_park_snapshot.reactivate_factory) hands the
--- PARKED STATE back without rebuilding it. It must hand back a WATCHED buffer,
--- and that means a real `nvim_buf_attach` with a NEWLY MINTED generation --
--- not the old number written back into the table.
---
--- The old number was a fiction. Park removes the ownership entry, so the
--- callback installed by the parked attachment is foreign from that instant:
--- the first edit made while parked sees a generation it does not own and
--- returns `true`, which is how Neovim uninstalls a callback and is the ONLY
--- way it does. There is then no callback left on the buffer at all, and
--- restoring `state._watch_generation` into `owner_by_buf` reinstated an owner
--- for an attachment that no longer existed: the review came back on screen
--- and every subsequent keystroke went unseen. Measured before this fix --
--- park, edit, resume, edit -- `after_resume_seen=0` changes reached the
--- watcher, against `live_seen=1` before the park.
---
--- So the resume re-runs THIS state's own `attach` (published as
--- `_watch_reattach` when it first ran), which installs a fresh callback,
--- mints the generation that callback quotes, and leaves any older callback
--- still hanging on the buffer to retire itself on its next line. One owner
--- either way, and it still refuses to take a buffer another review has
--- attached to since.
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
  -- `_watch_reattach` is published by `attach`, and ONLY by `attach`. Its
  -- absence therefore means this state has never had an attachment at all --
  -- the park took nothing away, and handing the state back leaves the buffer
  -- exactly as watched as it has always been. That is not a failed re-attach,
  -- and refusing it turned every resume of a never-watched review into an
  -- `M.open` rebuild. Measured: the never-emptied parked twin in
  -- tests/headless/u_removal_parks_before_it_blanks reached here with
  -- `reattach=nil`, and the fast path was dead for it.
  --
  -- A GENUINE failure -- the hook exists, runs, and this state still does not
  -- own the buffer afterwards -- is still a refusal, because there the park DID
  -- silence a real attachment and the review would come back on screen seeing
  -- nothing. Second return value names which of the two answers this is.
  --
  -- BOTH ANSWERS ARE REQUIRED, and this is the second time the unwatched review
  -- came back. `attach` reports whether Neovim really took the callback, and
  -- ownership reports whether this state is the one holding the buffer. Either
  -- alone accepts a dead review: ownership alone accepted a false
  -- `nvim_buf_attach` (`ATTACH_FALSE ... resume=true reason=reattached
  -- owner=true`), and an attachment that succeeded onto a buffer another
  -- review has since claimed is not this state's to resume.
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
  -- The register rows one native sequence carries (`push_buffer_edit`,
  -- `attach_structural`) live in review_watch_register.lua.
  local register_rows = register_factory.new(deps)
  local push_buffer_edit = register_rows.push_buffer_edit
  local attach_structural = register_rows.attach_structural

  --- THE SEQUENCE MARKER: `undotree().seq_cur` as it reads INSIDE the callback.
  ---
  --- It is NOT the sequence the change will end up in, and must never be used
  --- as one. Neovim seals an undo sequence AFTER the change -- an insert-mode
  --- session reports the pre-insert sequence for every keystroke in it -- so a
  --- marker names the state the change is departing FROM. Measured on a raw
  --- attachment: an `:s//g` over 12 rows reported `seq_cur=2` and settled on 2,
  --- while two undo-broken `set_lines` reported 3 and 4.
  ---
  --- What it IS good for, and the only thing the flush asks of it: TELLING TWO
  --- NATIVE SEQUENCES APART. The marker can only change once the previous
  --- sequence has been sealed, so callbacks sharing a marker share a sequence
  --- and a new marker starts a new one. The flush turns those boundaries into
  --- real sequence numbers (`process_pending_watch`).
  ---
  --- `deps.buf_undo_seq` goes through `nvim_buf_call`, which an `on_lines`
  --- callback is not always permitted to make; when the changed buffer is
  --- already the current one, `undotree()` answers directly and needs no
  --- buffer switch.
  local function callback_undo_marker(bufnr)
    if vim.api.nvim_get_current_buf() == bufnr then
      local ok, tree = pcall(vim.fn.undotree)
      if ok and type(tree) == "table" and type(tree.seq_cur) == "number" then
        return tree.seq_cur
      end
    end
    return (deps.buf_undo_seq and bufnr) and deps.buf_undo_seq(bufnr) or nil
  end

  --- Returns TRUE only when Neovim really installed the callback. Every caller
  --- that needs to know a buffer is watched -- `Watcher.resume` above all
  --- -- reads this answer and not the ownership table, because the ownership
  --- table is now written from it.
  local function attach(state)
    local bufnr = state.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end
    -- This attachment's name. Every callback below closes over it and owns the
    -- buffer only while it is still the installed generation. Minted here,
    -- INSTALLED only after `nvim_buf_attach` answers true (see
    -- `mint_generation`).
    local generation = mint_generation()
    -- Published so a callback can be told from the installed owner, and so
    -- `Watcher.resume` can report which attachment it left in place; nothing
    -- else reads it.
    state._watch_generation = generation

    -- It closes over the same `bufnr` and `state` these locals always did.
    local ownership = ownership_factory.new(bufnr, state)
    local edge_line_is_yana_owned = ownership.edge_line_is_yana_owned
    local interior_line_is_yana_owned = ownership.interior_line_is_yana_owned

    -- Published on `state` (like `_flush_paint`) because review_hunk_split's
    -- `try_split` and hunk_extent's `classify` both need it and cannot reach this
    -- attach's upvalues otherwise.
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
    -- The batch flush and the InsertLeave partition live in
    -- review_watch_flush.lua; `owns` is bound to THIS attachment's generation.
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

    state.flush_pending_watch = process_pending_watch
    -- THE re-attach route for an in-place resume (`Watcher.resume`). Park
    -- silences this attachment and the first parked edit uninstalls its
    -- callback outright, so a resume needs a real new attachment and only
    -- `attach` can build one -- the callbacks below close over upvalues no
    -- module-level function can reach.
    state._watch_reattach = function()
      return attach(state)
    end
    local attached_ok, attached = pcall(vim.api.nvim_buf_attach, bufnr, false, {
      -- ONE CALLBACK: `on_bytes` is the only position source (trigger model).
      -- Neovim sends on_lines and on_bytes in no fixed
      -- order (undo sends on_lines first; a charwise delete, four on_lines then
      -- one on_bytes), so nothing pairs them: the line-shaped change the
      -- classifiers read is derived from the same splice (hunk_anchor_splice.lua).
      on_bytes = function(_, _, _, sr, sc, _, oer, oec, _, ner, nec)
        -- FIRST LINE, before the ledger geometry write below. A retired
        -- attachment must not touch a ledger or a history -- adoption means the
        -- history it would write is the live review's own -- and returning true
        -- removes this callback, which is the only way Neovim uninstalls one.
        if not owns(bufnr, generation) then
          return true
        end
        local s = splice.splice(sr, sc, oer, oec, ner, nec)
        if splice.is_noop(s) then
          return
        end
        local first, last_orig, last_new = splice.line_change(s)
        -- STAMPED HERE, not at flush time. This is the only moment at which the
        -- state this change departs from is still the buffer's current one; by
        -- the time the scheduled flush runs, one or more sequences may have
        -- been sealed on top of it. It is a BOUNDARY MARKER, not a sequence
        -- number -- see `callback_undo_marker`. `barrier`: the reload rewrite.
        local change = {
          first = first,
          last_orig = last_orig,
          last_new = last_new,
          splice = s,
          undo_marker = callback_undo_marker(bufnr),
          barrier = state.reload_barrier or nil,
        }
        -- Stamp the rows this splice wrote with the native sequence its edit
        -- DEPARTS FROM (the boundary marker; `false` when unreadable), so
        -- InsertLeave can absorb before the coalesced flush runs and PARTITION
        -- the absorb by sequence (UNDO.md undo-atomicity). Earlier stamps move
        -- through the one transform like every anchor, so a later Return keeps
        -- the first typed row's stamp on that row (first-row orphan).
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
          local moved = ledger:record_buffer_change(change)
          for _, block in ipairs(moved) do
            if state.model_hunks and block.model_index and state.model_hunks[block.model_index] then
              state.model_hunks[block.model_index].new_end_line = block.new_end_line
            end
          end
        end
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
      -- Neovim's own end-of-attachment signal: the buffer was wiped, or the
      -- callback above retired itself by returning true. Either way THIS
      -- attachment is over and its ownership entry goes with it, so a buffer
      -- that no longer exists leaves nothing behind in the table.
      on_detach = function()
        release_generation(bufnr, generation)
      end,
    })
    if not attached_ok or attached ~= true then
      -- Neovim refused, or threw. Nothing is watching this buffer under this
      -- generation, so nothing may own it under this generation either --
      -- including the case where the call raised AFTER doing part of its work,
      -- which is the ordering that used to strand an owner. `release_generation`
      -- is keyed by generation, so a DIFFERENT live attachment on the same
      -- buffer is left exactly as it was.
      release_generation(bufnr, generation)
      clear_queue(state)
      return false
    end
    -- The attachment exists; only now does it get to own the buffer, and only
    -- now does the attachment it replaces get retired.
    --
    -- AND ONLY NOW IS THE ADOPTED HISTORY TOUCHED. `observe_buffer_seq` used to
    -- run at the TOP of `attach`, before `nvim_buf_attach` was even tried, so a
    -- refused or throwing attachment moved the observed sequence of a history
    -- this state had ADOPTED from a parked review and then returned `false`.
    -- The caller unwinds, the review is rebuilt -- and the number the rebuilt
    -- history reasons from was already advanced by an attachment that never
    -- existed. A failure must leave the history exactly as it found it, so the
    -- only write happens on the success path, after the callback is installed.
    if state.hunk_ledger and state.hunk_ledger:is_open() then
      state.hunk_ledger:observe_buffer_seq(deps.buf_undo_seq(bufnr))
    end
    install_generation(bufnr, state, generation)
    return true
  end

  self.attach = attach
  return self
end

return Watcher
