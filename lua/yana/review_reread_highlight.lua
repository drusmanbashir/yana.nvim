--- HIGHLIGHTING ACROSS A SWALLOWED READ.
---
--- yana installs a `BufReadCmd` on every review buffer
--- (review_open_watchers.lua) so a re-read jumps back to the exact live review
--- -- `:edit!` clears the buffer before `BufReadPost` and the review's undo
--- branch dies with it, so `BufReadCmd` is the last point at which Neovim can
--- still be handed the review's own bytes. That protection is why the read is
--- swallowed, and swallowing it is what loses the colour: `:edit` still frees
--- the buffer (`buf_freeall`) first, but `BufReadPost` -> filetype detect ->
--- `FileType` -> `Syntax` never runs, so nothing re-highlights.
---
--- WHY NOT LET NEOVIM DO THE READ AND RE-APPLY THE PROTECTION AFTER. Because
--- the thing being protected is the undo branch, and a real read destroys it
--- before any autocmd of ours can run: after `BufReadPost` there is no
--- `silent undo` left to jump back to. The BufReadCmd is not a decoration over
--- a default read, it is the only ordering in which the review survives at all.
---
--- WHY A CAPTURE, AND WHY HERE. Measured on this tree (nvim 0.12.4): by the
--- time `BufUnload` fires the treesitter highlighter is ALREADY destroyed
--- (`vim.treesitter.highlighter.active[buf]` is false), `BufReadPre` never
--- fires under a `BufReadCmd`, and 0.12's `vim.treesitter.start` leaves no
--- buffer variable behind (runtime/lua/vim/treesitter.lua:450 -- it only calls
--- `highlighter.new`). So NOTHING observable from inside the handler can tell
--- treesitter-was-on from treesitter-was-never-on, and a handler that guessed
--- from the surviving parser would switch treesitter ON for every operator who
--- never had it -- yana creates parsers of its own for hunk ownership
--- (review_watch_ownership.lua:25).
---
--- CAPTURE CANNOT BE ONE CALL SITE. `diff.reload_file` covers the re-reads yana
--- issues, but the operator issues reads of his own through the same swallowed
--- path, and each of them loses the colour with no capture to honour:
---   * `<C-^>` away under `set nohidden` (or `bufhidden=unload`) UNLOADS the
---     review buffer, so `<C-^>` back is a read;
---   * `:e` and `:e!` on the reviewed file.
--- So the profile is MAINTAINED for every buffer under review: `M.track`
--- installs cheap re-records on `BufLeave` (the operator is leaving, and under
--- `nohidden`/`bufhidden=unload` that is the last moment the buffer is whole)
--- and on `CmdlineEnter` (he is about to type `:e`). `diff.reload_file` keeps
--- its own record as one more refresh point.
---
--- THE PROFILE IS THE BUFFER'S CURRENT TRUTH, NEVER A MEMORY OF IT. Every event
--- above fires while the buffer is whole -- measured on this tree: at `BufLeave`
--- for `^` under `nohidden`, and at `CmdlineEnter` for a typed `:e`,
--- `vim.treesitter.highlighter.active[buf]` is still live. So a record NEVER
--- falls back to a previously observed language: if treesitter is off now, it is
--- off because the operator turned it off (`vim.treesitter.stop`,
--- `:TSBufDisable`, `:setlocal filetype=text`), and a restore that started it
--- again would overrule him. That is also why `FileType` and `Syntax` are NOT
--- tracked: measured here, the swallowed read fires its own `Syntax` with the
--- highlighter already destroyed, so tracking it would record "no treesitter"
--- over the language the profile is holding for exactly that read -- and the
--- previous-value fallback that used to paper over it is what overruled the
--- operator. Not listening to the read's own events removes both.
---
--- A PROFILE DOES NOT GO STALE WITH THE CONTENTS. Highlighting is a property of
--- the buffer's language and engine, not of its text, so a profile recorded many
--- `changedtick`s ago is still the right thing to restore; there is deliberately
--- no epoch or generation check here. What DOES invalidate it is the buffer
--- ceasing to be the buffer -- so `M.forget` runs on `BufWipeout` and when the
--- review is torn down (review_lifecycle.lua), and a reused bufnr can never
--- inherit the previous buffer's colours.
---
--- ONE WRITER: `M.record`. `M.note_visible` only refines the language of an
--- existing profile at handler entry, and `M.restore` re-records once both
--- engines are back. The profile is refreshed rather than consumed, because a
--- second read can follow the first with no event in between.
local log = require("yana.log")

local M = {}

-- bufnr -> profile, written only by M.record / M.note_visible.
local profiles = {}
-- bufnr -> true while a swallowed read is in flight. Between the handler's entry
-- and its restore the buffer is loaded again but NOT yet re-highlighted, and
-- what it reports about itself there is the read's doing, not the operator's --
-- so `M.record` refuses to write in that window and the profile taken while the
-- buffer was whole stands. It is the guard that makes "every record is taken
-- outside a read" true by construction, for the sites that exist and for any
-- added later.
local reading = {}

local function skipped(name)
  local ok, inline = pcall(require, "yana.inline_diff")
  local fault = ok and type(inline) == "table" and inline._fault or nil
  return fault ~= nil and fault[name] == true
end

--- What was painting this buffer, read while it is still whole.
function M.record(bufnr)
  if skipped("skip_rehighlight_profile") then
    -- The seam disables the MAINTAINED PROFILE as a whole, the record taken at
    -- review open included. Leaving that one behind would hand an armed row a
    -- stale profile, so the no-capture branch would never be reached and a guess
    -- planted there would go unmeasured.
    profiles[bufnr] = nil
    return
  end
  if reading[bufnr] then
    return
  end
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local ts_lang = nil
  local hl = vim.treesitter.highlighter.active[bufnr]
  if hl then
    -- The highlighter's own tree names the language it is highlighting; asking
    -- `get_parser` again could answer with a parser yana made for ownership.
    local ok, lang = pcall(function()
      return hl.tree:lang()
    end)
    ts_lang = ok and lang or nil
    if ts_lang == nil then
      local ok2, lang2 = pcall(function()
        local p = vim.treesitter.get_parser(bufnr, nil, { error = false })
        return p and p:lang() or nil
      end)
      ts_lang = ok2 and lang2 or nil
    end
  end
  -- WHAT IS OBSERVED NOW IS WHAT IS RECORDED. `ts_lang` stays nil when no
  -- highlighter is live, because every site that records is outside the read
  -- window (see the header): a nil here means the operator switched treesitter
  -- off, and remembering the language he switched off is how a restore comes to
  -- overrule him.
  profiles[bufnr] = {
    ts_lang = ts_lang,
    syntax = vim.bo[bufnr].syntax,
    current_syntax = vim.b[bufnr].current_syntax,
    filetype = vim.bo[bufnr].filetype,
  }
end

--- `diff.reload_file`'s name for the same thing: one more refresh point, at the
--- one read site yana owns end to end.
M.capture = M.record

--- The handler's FIRST act: mark the read window open, and take the ONE thing a
--- read can still be asked about.
---
--- NOTHING ELSE IS READ OFF THE BUFFER HERE. Measured on this tree: by the time
--- the handler runs, `:edit` has freed the buffer AND
--- `TSHighlighter:destroy()` has fired the `syntaxset` FileType autocmd on the
--- way out (runtime/lua/vim/treesitter/highlighter.lua:194), which runs
--- `set syntax=<filetype>` -- so a buffer whose operator had ONLY treesitter
--- reports `syntax=python` in this window. Believing that turned the legacy
--- engine on behind him. The maintained profile, taken while the buffer was
--- whole, is the only trustworthy description of it, so the read window refines
--- it and never overwrites it.
function M.note_visible(bufnr)
  if skipped("skip_rehighlight_profile") then
    profiles[bufnr] = nil
    return
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  reading[bufnr] = true
  local p = profiles[bufnr]
  if p == nil then
    -- A read on a buffer no review is maintaining. There is nothing to refine
    -- and the freed buffer is no basis for a guess; `M.restore` logs it.
    return
  end
  -- Additive only: a highlighter still standing here names its own language.
  local hl = vim.treesitter.highlighter.active[bufnr]
  if hl then
    local ok, lang = pcall(function()
      return hl.tree:lang()
    end)
    p.ts_lang = ok and lang or p.ts_lang
  end
end

--- Stop maintaining this buffer's profile. A bufnr is reused, colours are not.
function M.forget(bufnr)
  profiles[bufnr] = nil
  reading[bufnr] = nil
end

--- Maintain the profile for a buffer under review, on the review's own augroup
--- so it dies with the review.
function M.track(bufnr, group)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  M.record(bufnr)
  -- ONLY EVENTS A HUMAN GESTURE REACHES, AND ONLY ONES THAT FIRE WHILE THE
  -- BUFFER IS WHOLE. `BufWinLeave` was measured to fire only alongside
  -- `BufLeave` (and always after it) for every gesture that unloads a review
  -- buffer, so it could not be pinned by any row and is gone; `FileType` and
  -- `Syntax` are the read's OWN events and are gone for the reason in the
  -- header.
  vim.api.nvim_create_autocmd({ "BufLeave" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      M.record(bufnr)
    end,
  })
  -- `CmdlineEnter` has no buffer form: the operator is about to type something,
  -- possibly `:e`, and this is the last moment before it runs.
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    callback = function()
      if vim.api.nvim_get_current_buf() == bufnr then
        M.record(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = group,
    callback = function()
      M.forget(bufnr)
    end,
  })
end

--- True when a `syntax/<name>.vim` exists to be re-sourced. A name with no file
--- behind it was painted by a plugin in the buffer itself, and there is nothing
--- to re-run.
local function syntax_file_exists(name)
  if name == nil or name == "" then
    return false
  end
  local ok, found = pcall(vim.api.nvim_get_runtime_file, "syntax/" .. name .. ".vim", false)
  return ok and type(found) == "table" and #found > 0
end

local function unrestored(bufnr, reason)
  log.write(
    "DEBUG",
    "yana.review: review.reread_highlight_unrestored "
      .. vim.inspect({ bufnr = bufnr, reason = reason }, { newline = " ", indent = "" })
  )
end

--- The engines the profile holds, put back in the order Neovim builds them.
--- Returns once nothing more is left to apply; `M.restore` re-records after it,
--- so a second read still finds a truthful profile.
local function apply(bufnr, profile, fault)
  -- BOTH ENGINES, NOT THE FIRST ONE FOUND. A buffer can carry a treesitter
  -- highlighter and a legacy syntax at once, and returning after the treesitter
  -- start left the operator's `'syntax'` blanked by the read.
  local ts_restored = false
  if profile.ts_lang then
    if fault and fault.skip_rehighlight_treesitter then
      return
    end
    local ok = pcall(vim.treesitter.start, bufnr, profile.ts_lang)
    if not ok or vim.treesitter.highlighter.active[bufnr] == nil then
      unrestored(bufnr, "treesitter_start_failed")
    end
    ts_restored = true
  end

  -- With treesitter restored, only an EXPLICIT 'syntax' counts as a second
  -- engine: falling back to the filetype there would switch legacy highlighting
  -- on for an operator who only ever had treesitter.
  local name = (profile.syntax ~= "" and profile.syntax) or (not ts_restored and profile.filetype) or nil
  if name == nil or name == "" then
    return
  end

  if syntax_file_exists(name) then
    if fault and fault.skip_rehighlight_legacy then
      return
    end
    if ts_restored then
      -- ON A TREESITTER BUFFER THE FileType HOOK REFUSES. Neovim's own
      -- connection between FileType and Syntax is
      -- `au FileType * if !exists('b:ts_highlight') | exe "set syntax=" ...`
      -- (runtime/syntax/syntax.vim:35), and `vim.treesitter.start` stamps
      -- `b:ts_highlight` -- so firing FileType here would leave the operator's
      -- legacy engine off for good. The explicit `set syntax=` is the gesture he
      -- made himself to have both engines at once, so it is the one replayed.
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("setlocal syntax=" .. vim.fn.fnameescape(name))
      end)
    else
      -- What the read itself would have run. `:set syntax=<name>` inside the
      -- FileType handler does its own `syntax clear` and fires `Syntax` even when
      -- the value is unchanged (measured: 1 event for a same-value set), so the
      -- surviving `b:current_syntax` never has to be cleared here -- and clearing
      -- it is exactly what destroyed a plugin-owned syntax before.
      pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr, modeline = false })
    end
    if vim.b[bufnr].current_syntax == nil then
      unrestored(bufnr, "filetype_left_no_syntax")
    end
    return
  end

  if profile.current_syntax ~= nil then
    if fault and fault.skip_rehighlight_plugin then
      return
    end
    -- Plugin-owned: the items lived only in the buffer that was just freed and
    -- no `syntax/<name>.vim` can rebuild them. `Syntax` is the documented hook
    -- for a plugin to re-paint on; firing `FileType` instead would run
    -- `set syntax=`, whose own `syntax clear` guarantees the loss.
    -- `Syntax` matches on the syntax NAME, and nvim_exec_autocmds refuses
    -- `buffer` and `pattern` together -- so the event is raised with the name as
    -- its pattern from inside the buffer, which is how Neovim raises it too.
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.api.nvim_exec_autocmds("Syntax", { modeline = false, pattern = name })
    end)
    if vim.b[bufnr].current_syntax == nil then
      unrestored(bufnr, "plugin_owned_syntax")
    end
    return
  end
end

--- Put back exactly what the maintained profile last saw, and nothing else.
function M.restore(bufnr)
  -- The seam disables the MAINTAINED PROFILE as a whole, including the record
  -- `M.track` took at review open -- otherwise a row arming it would still be
  -- handed that stale record and would never reach `apply`'s no-capture branch,
  -- leaving that branch free for a guess nobody measures.
  local profile = profiles[bufnr]
  reading[bufnr] = nil
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local fault = nil
  do
    local ok, inline = pcall(require, "yana.inline_diff")
    fault = ok and type(inline) == "table" and inline._fault or nil
  end
  if profile == nil then
    -- A read yana did not issue (the operator's own `:e`). There is no capture
    -- to honour and no way to tell what was on, so say so rather than guess.
    unrestored(bufnr, "no_capture")
    return
  end
  apply(bufnr, profile, fault)
  -- ONE refresh, after BOTH engines are back. Recording between them would
  -- store the half-restored buffer -- 'syntax' still blanked by the read -- and
  -- the NEXT read would then restore only treesitter.
  M.record(bufnr)
end

M._test = { profiles = profiles }

return M
