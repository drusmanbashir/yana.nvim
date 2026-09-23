-- yana: the flat `mappings` table (facade: yana.config). Sole writer of
-- options.mappings and of its three derived mirrors (options.diff_keymaps,
-- options.keymaps, options.global_keymaps); consumers read, never write.
local M = {}

--- Where each key binds. prompt keys bind in the panel prompt and in the
--- inline-edit float; float keys bind in the float only.
M.CONTEXTS = {
  review = { "accept_hunk", "reject_hunk", "accept_file", "reject_file", "accept_all", "next_hunk", "prev_hunk" },
  prompt = { "submit", "stop" },
  panel = {
    "model", "new_chat", "toggle_mode", "resend", "review", "reject", "focus_prompt", "close",
    "next_panel", "prev_panel", "completion_menu", "new_panel", "queue", "steer",
  },
  float = { "history_prev", "history_next" },
  global = { "toggle", "ask", "inline_edit" },
}

-- Old review-key names, as the diff_keymaps mirror still spells them.
local DIFF_NAMES = {
  theirs = "accept_hunk",
  ours = "reject_hunk",
  all_theirs = "accept_file",
  all_changes = "accept_all",
  reject_file = "reject_file",
  next = "next_hunk",
  prev = "prev_hunk",
}
-- inline_edit.keymaps: the float closes with `stop` in insert mode.
local FLOAT_NAMES = { cancel = "stop" }

local KNOWN = {}
for _, names in pairs(M.CONTEXTS) do
  for _, name in ipairs(names) do
    KNOWN[name] = true
  end
end

-- Once per session, not once per setup(): a config that re-runs setup on
-- every reload must not turn one old habit into a repeated nag.
local warned_both = false

-- Copy one legacy or grouped table onto `out` under the flat names. A name
-- with no flat counterpart (submit_normal, stop_normal, backend, the panel
-- `diff` alias, cancel_normal, inline_edit_normal) is dropped.
local function apply(out, tbl, names)
  if type(tbl) ~= "table" then
    return
  end
  if names == DIFF_NAMES and tbl.both ~= nil then
    if not warned_both then
      warned_both = true
      vim.notify("yana: diff_keymaps.both is deprecated; use mappings.reject_file", vim.log.levels.WARN)
    end
    if tbl.reject_file == nil then
      out.reject_file = tbl.both
    end
  end
  for name, key in pairs(tbl) do
    local flat = (names and names[name]) or name
    if KNOWN[flat] then
      out[flat] = key
    end
  end
end

--- The flat table from the caller's raw opts. Precedence, lowest first:
--- inline_edit.keymaps, global_keymaps, keymaps, diff_keymaps, mappings.global,
--- mappings.panel, mappings.diff, then the flat keys of mappings.
--- A value that is neither a string nor false falls back to its default, and a
--- review key cannot be disabled: false and "" both restore its default (an
--- empty lhs is not a disable -- Neovim refuses it when the review binds).
function M.resolve(defaults, opts)
  local out = vim.deepcopy(defaults)
  local user = type(opts.mappings) == "table" and opts.mappings or {}
  local inline_edit = type(opts.inline_edit) == "table" and opts.inline_edit or {}
  apply(out, inline_edit.keymaps, FLOAT_NAMES)
  apply(out, opts.global_keymaps)
  apply(out, opts.keymaps)
  apply(out, opts.diff_keymaps, DIFF_NAMES)
  apply(out, user.global)
  apply(out, user.panel)
  apply(out, user.diff, DIFF_NAMES)
  for name, key in pairs(user) do
    if KNOWN[name] then
      out[name] = key
    end
  end
  for name, key in pairs(out) do
    if key ~= false and type(key) ~= "string" then
      out[name] = defaults[name]
    end
  end
  for _, name in ipairs(M.CONTEXTS.review) do
    if out[name] == false or out[name] == "" then
      out[name] = defaults[name]
    end
  end
  return out
end

--- The derived mirrors, for readers of the old tables: diff_keymaps keeps the
--- old review names, keymaps holds the prompt and panel keys, global_keymaps
--- the global ones.
function M.mirrors(flat)
  local diff = {}
  for old, new in pairs(DIFF_NAMES) do
    diff[old] = flat[new]
  end
  local panel = {}
  for _, context in ipairs({ "prompt", "panel" }) do
    for _, name in ipairs(M.CONTEXTS[context]) do
      panel[name] = flat[name]
    end
  end
  local global = {}
  for _, name in ipairs(M.CONTEXTS.global) do
    global[name] = flat[name]
  end
  return diff, panel, global
end

return M
