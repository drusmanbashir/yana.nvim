-- F-REVIEW-THEME: consumer-owned grid highlights, independent of widget APIs.
local M = {}
local names = { "native", "dark", "light" }
local groups = { live = "YanaReviewBtn", dim = "YanaReviewBtnDim",
  hover = "YanaReviewBtnHover", flash = "YanaReviewBtnFlash",
  marked = "YanaReviewBtnMarked", key = "YanaReviewBtnKey" }
local native = { live = "Pmenu", dim = "Comment", hover = "PmenuSel",
  flash = "IncSearch", key = "Special" }
local presets = {
  dark = { fg = 0xabb2bf, bg = 0x282c34, dim = 0x7f848e,
    hover = 0x3e4451, accent = 0xe5c07b, accent_text = 0x21252b, key = 0x61afef },
  light = { fg = 0x24292f, bg = 0xe5e7eb, dim = 0x6e7781,
    hover = 0xcce5ff, accent = 0x8250df, accent_text = 0xffffff, key = 0x0969da },
}
local applied, installed
function M.check(name)
  assert(name == "native" or presets[name], "yana: ui.review_buttons.theme must be native, dark or light")
  return name
end
function M.names() return vim.deepcopy(names) end
function M.current() return M.check(require("yana.config").options.ui.review_buttons.theme) end
function M.hl_groups() return groups end
function M.apply()
  local name = M.current()
  local p = presets[name]
  for role, group in pairs(groups) do
    local attrs
    if not p then
      attrs = role == "marked" and { underline = true, sp = "Orange" } or { link = native[role] }
      attrs.default = applied == nil or applied == "native"
    else
      attrs = { fg = p.fg, bg = p.bg }
      if role == "dim" then attrs.fg = p.dim
      elseif role == "hover" then attrs.bg = p.hover
      elseif role == "flash" then attrs.fg, attrs.bg = p.accent_text, p.accent
      elseif role == "key" then attrs.fg = p.key
      elseif role == "marked" then attrs.underline, attrs.sp = true, p.accent end
    end
    vim.api.nvim_set_hl(0, group, attrs)
  end
  applied = name
  if not installed then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("YanaReviewButtonTheme", { clear = true }),
      callback = function() M.apply() end,
    })
    installed = true
  end
  return name
end
function M.set(name)
  if name == nil or name == "" then
    local current = M.current()
    for i, value in ipairs(names) do
      if value == current then name = names[i % #names + 1]; break end
    end
  end
  M.check(name)
  require("yana.config").options.ui.review_buttons.theme = name
  M.apply()
  vim.cmd.redraw()
  return name
end
return M
