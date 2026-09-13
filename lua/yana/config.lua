-- yana: configuration defaults and merge logic.
local M = {}

M.defaults = require("yana.config_defaults")

M.options = vim.deepcopy(M.defaults)
M._setup_done = false

function M.home_dir()
  return vim.fn.expand("~")
end


local _backends = require("yana.config_backends").new({
  defaults = M.defaults,
  home_dir = M.home_dir,
  get_options = function()
    return M.options
  end,
})
M.normalize_backends = _backends.normalize_backends
M.normalize_backend = _backends.normalize_backend
M.backend_descriptor = _backends.backend_descriptor


local _resolve = require("yana.config_resolve").new({
  defaults = M.defaults,
  get_options = function()
    return M.options
  end,
  backend_descriptor = function(name)
    return M.backend_descriptor(name)
  end,
})
M.mode_hl_groups = _resolve.mode_hl_groups
M.model_hl_group = _resolve.model_hl_group
M.normalize_mode = _resolve.normalize_mode
M.resolve_mode = _resolve.resolve_mode
M.overlay_mode = _resolve.overlay_mode
M.review_mode_active = _resolve.review_mode_active
M.agent_permission_mode = _resolve.agent_permission_mode
M.agent_needs_permission_flag = _resolve.agent_needs_permission_flag
M.normalize_cmd_env = _resolve.normalize_cmd_env
M.resolve_cmd = _resolve.resolve_cmd
M.cmd = _resolve.cmd
M.normalize_modes = _resolve.normalize_modes
M.mode_enabled = _resolve.mode_enabled



local _normalize = require("yana.config_normalize").new({
  defaults = M.defaults,
})
M.normalize_selection_scope = _normalize.normalize_selection_scope
M.normalize_image_paste = _normalize.normalize_image_paste
M.normalize_redirect = _normalize.normalize_redirect
M.normalize_inline_edit = _normalize.normalize_inline_edit
M.normalize_log_level = _normalize.normalize_log_level
M.normalize_sandbox = _normalize.normalize_sandbox
M.normalize_review = _normalize.normalize_review
M.normalize_skill_dirs = _normalize.normalize_skill_dirs
M.normalize_write_roots = _normalize.normalize_write_roots
M.normalize_single_file = _normalize.normalize_single_file
M.normalize_workspace_roots = _normalize.normalize_workspace_roots
M.normalize_capture_root = _normalize.normalize_capture_root
M.normalize_capture_root_candidates = _normalize.normalize_capture_root_candidates
M.normalize_artifact_dir_prefixes = _normalize.normalize_artifact_dir_prefixes
M.normalize_inline_exec_allowlist = _normalize.normalize_inline_exec_allowlist

local _mappings = require("yana.config_mappings")

-- Runtime facts derived from the resolved options, written only here: the
-- current mode starts at the first listed mode, enable_agentic reports whether
-- agentic is listed, and the three old keymap tables mirror `mappings`.
local function derive(options)
  options.mode = options.modes[1]
  options.enable_agentic = vim.tbl_contains(options.modes, "agentic")
  options.diff_keymaps, options.keymaps, options.global_keymaps = _mappings.mirrors(options.mappings)
end
derive(M.options)


function M.setup_done()
  return M._setup_done == true
end


-- THE COMPOSITION ROOT'S ONE CHOICE, and it is closed. Two values, no third,
-- and no "on"/"off"/truthy spelling of either: a profile the operator typed
-- wrong must refuse at setup, not silently run the factory build while he
-- believes he is recording a debugger one.
local PROFILES = { factory = true, debugger = true }

function M.normalize_profile(value)
  if value == nil then
    return M.defaults.profile
  end
  if type(value) ~= "string" or not PROFILES[value] then
    local names = {}
    for name in pairs(PROFILES) do
      names[#names + 1] = name
    end
    table.sort(names)
    error(
      "yana: invalid config.profile "
        .. vim.inspect(value)
        .. " -- valid profiles: "
        .. table.concat(names, ", "),
      0
    )
  end
  return value
end

function M.normalize_multi_panel_layout(value)
  local policy = require("yana.ui_panel_layout_policy")
  if value == nil then
    return M.defaults.ui.multi_panel_layout
  end
  if not policy.is_accepted(value) then
    error(
      "yana: invalid ui.multi_panel_layout "
        .. vim.inspect(value)
        .. " -- accepted values: "
        .. table.concat(policy.accepted_values(), ", "),
      0
    )
  end
  return value
end

--- The debug modules this session attaches, as a list of names.
---
--- SHAPE ONLY. Whether a name resolves to a module is decided by the
--- composition root in `yana.init`, which is the only place allowed to
--- `require` one -- so a `factory` profile never loads a single byte of debug
--- code, not even to validate a list it is going to ignore. A name listed twice
--- is refused here: attaching one module twice would double every line it
--- writes, and a doubled key stream is silently wrong evidence rather than a
--- visible failure.
function M.normalize_debug_modules(value, profile)
  if profile ~= "debugger" then
    return {}
  end
  if value == nil then
    return {}
  end
  if type(value) ~= "table" or not vim.islist(value) then
    error("yana: config.debug_modules must be a list of module names, got " .. vim.inspect(value), 0)
  end
  local out, seen = {}, {}
  for _, name in ipairs(value) do
    if type(name) ~= "string" or name == "" or name:match("[^%w_]") then
      error(
        "yana: invalid config.debug_modules entry "
          .. vim.inspect(name)
          .. " -- each entry names a module loaded as `yana.debug_<name>`",
        0
      )
    end
    if seen[name] then
      error("yana: config.debug_modules lists " .. vim.inspect(name) .. " twice", 0)
    end
    seen[name] = true
    out[#out + 1] = name
  end
  return out
end


function M.setup(opts)
  -- A private copy: nothing below writes into the caller's table, so a second
  -- setup() with the same table resolves to the same options.
  opts = vim.deepcopy(opts or {})
  local next_options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Replace (do not deep-merge) each highlight role so a custom bg/fg does not
  -- keep a leftover defaults.link (e.g. DiffAdd) that would win at apply time.
  if opts.diff_highlights then
    next_options.diff_highlights = vim.deepcopy(M.defaults.diff_highlights)
    for role, spec in pairs(opts.diff_highlights) do
      next_options.diff_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.mode_highlights then
    next_options.mode_highlights = vim.deepcopy(M.defaults.mode_highlights)
    for role, spec in pairs(opts.mode_highlights) do
      next_options.mode_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.model_highlight then
    next_options.model_highlight = vim.deepcopy(opts.model_highlight)
  end
  -- The flat mappings come from the raw opts, so every legacy spelling
  -- translates in one place (config_mappings.resolve).
  next_options.mappings = _mappings.resolve(M.defaults.mappings, opts)
  -- Every validator runs against the candidate. Any of them may raise; none of
  -- them can leave a half-installed configuration behind.
  next_options.selection_scope = M.normalize_selection_scope(next_options.selection_scope)
  next_options.image_paste = M.normalize_image_paste(next_options.image_paste)
  next_options.redirect = M.normalize_redirect(next_options.redirect)
  next_options.inline_edit = M.normalize_inline_edit(next_options.inline_edit)
  next_options.review = M.normalize_review(next_options.review)
  next_options.skill_dirs = M.normalize_skill_dirs(next_options.skill_dirs)
  next_options.artifact_dir_prefixes = M.normalize_artifact_dir_prefixes(next_options.artifact_dir_prefixes)
  next_options.write_roots = M.normalize_write_roots(next_options.write_roots)
  next_options.single_file = M.normalize_single_file(next_options.single_file)
  next_options.workspace_roots = M.normalize_workspace_roots(next_options.workspace_roots)
  next_options.capture_root = M.normalize_capture_root(next_options.capture_root)
  next_options.capture_root_candidates = M.normalize_capture_root_candidates(next_options.capture_root_candidates)
  next_options.inline_exec_allowlist = M.normalize_inline_exec_allowlist(next_options.inline_exec_allowlist)
  next_options.cmd_env = M.normalize_cmd_env(next_options.cmd_env)
  next_options.sandbox = M.normalize_sandbox(next_options.sandbox)
  next_options.backends = M.normalize_backends(next_options.backends)
  next_options.backend = M.normalize_backend(next_options.backend, next_options.backends)
  next_options.modes = M.normalize_modes(opts)
  derive(next_options)
  next_options.log_level = M.normalize_log_level(next_options.log_level)
  next_options.profile = M.normalize_profile(next_options.profile)
  next_options.debug_modules = M.normalize_debug_modules(next_options.debug_modules, next_options.profile)
  next_options.ui = next_options.ui or {}
  next_options.ui.multi_panel_layout = M.normalize_multi_panel_layout(next_options.ui.multi_panel_layout)
  -- Only now does anything become effective.
  M.options = next_options
  M._setup_done = true
  M.apply_mode_highlights()
  -- The ignore matcher compiles `review.ignore` once and caches it. A setup()
  -- that changed the list must not be answered by the previous compile.
  pcall(function()
    require("yana.ignore").reset()
  end)
  require("yana.log").set_level(next_options.log_level)
  return M.options
end

--- Apply winbar chip highlights from `mode_highlights` and `model_highlight`.
function M.apply_mode_highlights()
  local h = M.options.mode_highlights or M.defaults.mode_highlights
  for mode, group in pairs(M.mode_hl_groups) do
    local spec = h[mode] or {}
    if spec.link and not spec.bg and not spec.fg then
      vim.api.nvim_set_hl(0, group, { link = spec.link, default = true, force = true })
    else
      local hl = vim.tbl_extend("force", spec, { force = true })
      hl.link = nil
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
  local ms = M.options.model_highlight or M.defaults.model_highlight or {}
  if ms.link and not ms.bg and not ms.fg then
    vim.api.nvim_set_hl(0, M.model_hl_group, { link = ms.link, default = true, force = true })
  else
    local hl = vim.tbl_extend("force", ms, { force = true })
    hl.link = nil
    vim.api.nvim_set_hl(0, M.model_hl_group, hl)
  end
  vim.api.nvim_set_hl(0, "YanaSingleFileBanner", { link = "WarningMsg", bold = true, default = true, force = true })
  -- Carried here instead, as underline on top of the banner's own warning colour,
  -- applied only to that one word.
  vim.api.nvim_set_hl(
    0,
    "YanaSingleFileBannerEmphasis",
    { link = "WarningMsg", bold = true, underline = true, default = true, force = true }
  )
end

-- The cursor-agent permission mode for this turn.
function M.panel_mode(panel_mode)
  return M.resolve_mode(panel_mode)
end

return M
