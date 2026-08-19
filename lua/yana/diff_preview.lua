-- Live playground for yana inline diff_highlight themes.
local config = require("yana.config")
local inline = require("yana.inline_diff")
local notify_one_line = require("yana.notify").one_line
local log = require("yana.log")

local M = {}

-- Dedicated review pool for the theme picker. Explicit workspace keeps preview
-- lifecycle out of the panel/CWD pool and avoids no-option global scans (M3).
local PREVIEW_WORKSPACE = vim.fn.stdpath("cache") .. "/yana/diff-theme-preview"

local function preview_opts(extra)
  return vim.tbl_extend("force", {
    workspace = PREVIEW_WORKSPACE,
    preview = true,
  }, extra or {})
end

local PRESETS = {
  {
    name = "1 shared git+yana (DiffAdd/DiffDelete)",
    highlights = {
      incoming = { link = "DiffAdd" },
      deleted = { link = "DiffDelete" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "2 cursor Dark Modern opaque (no link)",
    highlights = {
      incoming = { bg = "#383e2a" },
      deleted = { bg = "#4a2927", fg = "#ffc9c5" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "3 github-dark",
    highlights = {
      incoming = { bg = "#0d2818", fg = "#7ee787" },
      deleted = { bg = "#3f1d1d", fg = "#ffa198" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "4 github-dark subtle",
    highlights = {
      incoming = { bg = "#12261e", fg = "#56d364" },
      deleted = { bg = "#2d1517", fg = "#f97583" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "5 github-light",
    highlights = {
      incoming = { bg = "#dafbe1", fg = "#116329" },
      deleted = { bg = "#ffebe9", fg = "#82071e" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "6 dim (fg only)",
    highlights = {
      incoming = { fg = "#7ee787" },
      deleted = { fg = "#ffa198" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "7 bright",
    highlights = {
      incoming = { bg = "#1a4d2e", fg = "#aff5b4" },
      deleted = { bg = "#5c1a1a", fg = "#ffdcd7" },
      hint = { fg = "#e5c07b" },
    },
  },
  {
    name = "8 mauve incoming",
    highlights = {
      incoming = { bg = "#937caa", fg = "#f0ebf5" },
      deleted = { bg = "#3f1d1d", fg = "#ffa198" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "9 nord",
    highlights = {
      incoming = { bg = "#2e4d3e", fg = "#a3be8c" },
      deleted = { bg = "#4c2f35", fg = "#bf616a" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "10 solarized-dark",
    highlights = {
      incoming = { bg = "#073642", fg = "#859900" },
      deleted = { bg = "#4a1010", fg = "#dc322f" },
      hint = { link = "Comment" },
    },
  },
  {
    name = "11 high-contrast",
    highlights = {
      incoming = { bg = "#003300", fg = "#00ff00" },
      deleted = { bg = "#330000", fg = "#ff6666" },
      hint = { fg = "#ffff00" },
    },
  },
}

local SAMPLE_BEFORE = table.concat({
  'def greet(name):',
  '    print("hello")',
  "",
  "# unchanged context",
  "value = 1",
  "",
}, "\n")

local SAMPLE_AFTER = table.concat({
  'def greet(name):',
  '    print("hello, " + name)',
  "",
  "# unchanged context",
  "value = 42",
  "",
}, "\n")

local preview = {
  state = nil,
  index = 1,
  saved = nil,
  float_win = nil,
  float_buf = nil,
}

local function spec_text(spec)
  if spec.link then
    return '{ link = "' .. spec.link .. '" }'
  end
  local parts = {}
  if spec.bg then
    table.insert(parts, 'bg = "' .. spec.bg .. '"')
  end
  if spec.fg then
    table.insert(parts, 'fg = "' .. spec.fg .. '"')
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function snippet(highlights)
  return table.concat({
    "diff_highlights = {",
    "  incoming = " .. spec_text(highlights.incoming) .. ",",
    "  deleted = " .. spec_text(highlights.deleted) .. ",",
    "  hint = " .. spec_text(highlights.hint or { link = "Comment" }) .. ",",
    "},",
  }, "\n")
end

local function close_float()
  if preview.float_win and vim.api.nvim_win_is_valid(preview.float_win) then
    pcall(vim.api.nvim_win_close, preview.float_win, true)
  end
  preview.float_win = nil
  preview.float_buf = nil
end

local function show_panel(preset)
  close_float()
  preview.float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[preview.float_buf].buftype = "nofile"
  vim.bo[preview.float_buf].bufhidden = "wipe"
  vim.bo[preview.float_buf].modifiable = true

  local h = preset.highlights
  local lines = {
    preset.name,
    "",
    "incoming " .. spec_text(h.incoming),
    "deleted  " .. spec_text(h.deleted),
    "hint     " .. spec_text(h.hint or { link = "Comment" }),
    "",
    "]t next · [t prev · yt yank · 1-9/]t jump · q close",
    "",
  }
  -- snippet() is the multi-line config block. nvim_buf_set_lines rejects any
  -- list element containing a newline ("'replacement string' item contains
  -- newlines"), so it has to be split, not appended whole.
  vim.list_extend(lines, vim.split(snippet(h), "\n", { plain = true }))
  vim.api.nvim_buf_set_lines(preview.float_buf, 0, -1, false, lines)
  vim.bo[preview.float_buf].modifiable = false

  local width = math.min(72, vim.o.columns - 4)
  local height = #lines + 1
  preview.float_win = vim.api.nvim_open_win(preview.float_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, vim.o.columns - width - 2),
    row = 2,
    style = "minimal",
    border = "rounded",
    title = " diff themes ",
    title_pos = "center",
  })
end

local function apply_preset(index)
  local preset = PRESETS[index]
  if not preset then
    return
  end
  preview.index = index
  config.options.diff_highlights = vim.deepcopy(preset.highlights)
  inline.rerender(preview.state)
  show_panel(preset)
  notify_one_line("yana theme: " .. preset.name, vim.log.levels.INFO)
end

local function yank_snippet()
  local preset = PRESETS[preview.index]
  if not preset then
    return
  end
  vim.fn.setreg("+", snippet(preset.highlights), "c")
  notify_one_line("Yanked diff_highlights to clipboard (+)", vim.log.levels.INFO)
end

local function cleanup_preview()
  close_float()
  if preview.state then
    inline.close_active(preview.state.opts or {})
  end
  if preview.saved then
    config.options.diff_highlights = preview.saved
  end
  preview.state = nil
end

local function setup_keys(bufnr)
  local km = { buffer = bufnr, nowait = true, silent = true }
  local theme_keys = { "]t", "[t", "yt", "q" }
  for i = 1, 9 do
    table.insert(theme_keys, tostring(i))
  end
  preview.state.keys = vim.list_extend(preview.state.keys or {}, theme_keys)

  -- Wrap only at the keymap.set call, not the underlying functions, so
  -- callers of yank_snippet/apply_preset/cleanup_preview elsewhere keep
  -- getting their real return values.
  local function guarded(ctx, fn)
    return function(...)
      log.guard(ctx, fn, ...)
    end
  end

  vim.keymap.set("n", "]t", function()
    log.guard("yana.diff_preview next theme", function()
      apply_preset((preview.index % #PRESETS) + 1)
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: next diff theme" }))

  vim.keymap.set("n", "[t", function()
    log.guard("yana.diff_preview prev theme", function()
      apply_preset(((preview.index - 2) % #PRESETS) + 1)
    end)
  end, vim.tbl_extend("force", km, { desc = "yana: prev diff theme" }))

  vim.keymap.set("n", "yt", guarded("yana.diff_preview yank_snippet", yank_snippet), vim.tbl_extend("force", km, { desc = "yana: yank theme snippet" }))

  vim.keymap.set("n", "q", function()
    log.guard("yana.diff_preview close", cleanup_preview)
  end, vim.tbl_extend("force", km, { desc = "yana: close diff theme preview" }))

  for i = 1, 9 do
    local idx = i
    vim.keymap.set("n", tostring(i), function()
      log.guard("yana.diff_preview theme " .. i, function()
        if PRESETS[idx] then
          apply_preset(idx)
        end
      end)
    end, vim.tbl_extend("force", km, { desc = "yana: diff theme " .. i }))
  end
end

function M.open()
  if inline.active_state(preview_opts()) and not preview.state then
    notify_one_line("yana: close active inline review first", vim.log.levels.WARN)
    return
  end
  if preview.state then
    cleanup_preview()
  end

  preview.saved = vim.deepcopy(config.options.diff_highlights or {})
  local change = {
    id = -9001,
    status = "pending",
    path = "yana://diff-theme-preview",
    rel = "diff-theme-preview",
    before = SAMPLE_BEFORE,
    after = SAMPLE_AFTER,
  }

  -- open_guarded, never inline.open: a raw call that throws after the engine
  -- has set `active` leaves the singleton pointing at a dead session, which
  -- stalls the review queue for the rest of the session.
  local ok, state = inline.open_guarded(change, preview_opts({
    on_close = function()
      close_float()
      if preview.saved then
        config.options.diff_highlights = preview.saved
      end
      preview.state = nil
    end,
  }))
  if not ok or not state then
    notify_one_line("yana: could not open diff theme preview", vim.log.levels.ERROR)
    return
  end

  preview.state = state

  -- Everything past this point runs with a LIVE review owned by the engine.
  -- A throw here (the float renderer has already produced one) would leave
  -- `active` set with no way to close it, stalling every later review with
  -- "close active inline review first" for the rest of the session. Hand the
  -- review back instead and report.
  local ok_setup, err = pcall(function()
    setup_keys(state.bufnr)

    local start = 1
    for i, preset in ipairs(PRESETS) do
      if vim.deep_equal(preset.highlights, preview.saved) then
        start = i
        break
      end
    end
    apply_preset(start)
  end)
  if not ok_setup then
    cleanup_preview()
    notify_one_line("yana: diff theme preview failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.presets()
  return PRESETS
end

M._test = {
  preview_workspace = PREVIEW_WORKSPACE,
  preview_opts = preview_opts,
}

return M
