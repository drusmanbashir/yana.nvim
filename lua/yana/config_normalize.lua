-- yana: option / path / mapping normalizers (facade: yana.config).
local M = {}

function M.new(deps)
  local defaults = deps.defaults

  local ENFORCE_MODES = { reject = true, warn = true, off = true }

  local function normalize_enforce(value, fallback)
    if type(value) == "string" and ENFORCE_MODES[value] then
      return value
    end
    return fallback
  end

  -- Merge scope over defaults; sanitize enforce, markers, zone/cap fields.
  local function normalize_selection_scope(scope)
    local base = vim.deepcopy(defaults.selection_scope)
    if type(scope) ~= "table" then
      return base
    end
    local out = vim.tbl_deep_extend("force", base, scope)
    out.enforce = normalize_enforce(out.enforce, base.enforce)
    out.unstructured = normalize_enforce(out.unstructured, base.unstructured)
    if type(out.cell_markers) ~= "table" or #out.cell_markers == 0 then
      out.cell_markers = vim.deepcopy(base.cell_markers)
    else
      local markers = {}
      for _, marker in ipairs(out.cell_markers) do
        if type(marker) == "string" and marker ~= "" then
          markers[#markers + 1] = marker
        end
      end
      if #markers == 0 then
        out.cell_markers = vim.deepcopy(base.cell_markers)
      else
        out.cell_markers = markers
      end
    end
    if type(out.min_zone_lines) ~= "number" or out.min_zone_lines < 1 then
      out.min_zone_lines = base.min_zone_lines
    end
    if type(out.rejection_cap) ~= "number" or out.rejection_cap < 1 then
      out.rejection_cap = base.rejection_cap
    end
    return out
  end

  -- Merge ip over defaults; normalize enable flag, key(s) into a list, keep.
  local function normalize_image_paste(ip)
    local base = vim.deepcopy(defaults.image_paste)
    if type(ip) ~= "table" then
      return base
    end
    local out = vim.tbl_deep_extend("force", base, ip)
    if type(out.enable) ~= "boolean" then
      out.enable = base.enable
    end
    -- Accept a bare string or a list; always hand callers a list so the keymap
    -- site never has to branch on the type.
    local keys = {}
    if type(out.key) == "string" then
      if out.key ~= "" then
        keys[1] = out.key
      end
    elseif type(out.key) == "table" then
      for _, k in ipairs(out.key) do
        if type(k) == "string" and k ~= "" then
          keys[#keys + 1] = k
        end
      end
    end
    if #keys == 0 then
      keys = vim.deepcopy(base.key)
    end
    out.key = keys
    if type(out.keep) ~= "number" or out.keep < 1 then
      out.keep = base.keep
    end
    return out
  end

  -- Merge r over defaults; sanitize timeout, kill-grace, and marker fields.
  local function normalize_redirect(r)
    local base = vim.deepcopy(defaults.redirect)
    if type(r) ~= "table" then
      return base
    end
    local out = vim.tbl_deep_extend("force", base, r)
    if type(out.confirm_exit_timeout_ms) ~= "number" or out.confirm_exit_timeout_ms < 50 then
      out.confirm_exit_timeout_ms = base.confirm_exit_timeout_ms
    end
    if type(out.kill_grace_ms) ~= "number" or out.kill_grace_ms < 50 then
      out.kill_grace_ms = base.kill_grace_ms
    end
    if type(out.marker) ~= "string" then
      out.marker = base.marker
    end
    return out
  end

  -- Merge ie over defaults; sanitize enable, size and history.
  local function normalize_inline_edit(ie)
    local base = vim.deepcopy(defaults.inline_edit)
    if type(ie) ~= "table" then
      return base
    end
    local out = vim.tbl_deep_extend("force", base, ie)
    if type(out.enable) ~= "boolean" then
      out.enable = base.enable
    end
    -- width follows the ui.width convention: <= 1 is a fraction, > 1 absolute.
    -- Anything else (0, negative, non-number) falls back rather than producing a
    -- zero-width float the user cannot type into.
    if type(out.width) ~= "number" or out.width <= 0 then
      out.width = base.width
    end
    if type(out.max_height) ~= "number" or out.max_height < 1 then
      out.max_height = base.max_height
    end
    if type(out.history) ~= "number" or out.history < 0 then
      out.history = base.history
    end
    -- Float keys live in the flat `mappings` table; a legacy keymaps sub-table
    -- was translated there by config_mappings and is not kept.
    out.keymaps = nil
    return out
  end

  --- Returns the canonical lowercase name. `nil` falls back to defaults.log_level
  --- ("info"). Anything else — including legacy vim.lsp names like TRACE/OFF — is
  --- refused BY NAME at setup, listing the closed set.
  local function normalize_log_level(value)
    if value == nil then
      return defaults.log_level
    end
    local log = require("yana.log")
    local name = type(value) == "string" and log.canonicalize_config_level(value) or nil
    if not name then
      error(
        "yana: invalid config.log_level "
          .. vim.inspect(value)
          .. " -- valid levels: "
          .. table.concat(log.config_level_names(), ", "),
        0
      )
    end
    return name
  end

  -- Vendor sandbox levels: the operator chooses
  -- one Yana level per editing surface. Vendor spellings never enter config.
  local SANDBOX_LEVELS = {
    full = true,
    workspace = true,
    ["read-only"] = true,
    ["vendor-default"] = true,
  }

  local function normalize_sandbox(value)
    if type(value) ~= "table" then
      error("yana: config.sandbox must be a table with inline and agentic levels", 0)
    end
    for surface in pairs(value) do
      if surface ~= "inline" and surface ~= "agentic" then
        error("yana: config.sandbox." .. tostring(surface) .. " is unknown -- only inline and agentic are valid", 0)
      end
    end
    local out = {}
    for _, surface in ipairs({ "inline", "agentic" }) do
      local level = value[surface]
      if type(level) ~= "string" or not SANDBOX_LEVELS[level] then
        error(
          "yana: config.sandbox." .. surface .. " " .. vim.inspect(level)
            .. " is invalid -- must be full, workspace, read-only, or vendor-default",
          0
        )
      end
      out[surface] = level
    end
    return out
  end

  -- Merge review over defaults; error if not a table; sanitize tabs flag.
  --
  -- `ignore` ERRORS rather than being sanitized away, unlike `tabs`. Same atomic
  -- contract as `artifact_dir_prefixes`: the whole `setup()` call is rejected and
  -- `config.options` is left exactly as it was.
  local function normalize_review(review)
    local base = vim.deepcopy(defaults.review or { tabs = true, ignore = {} })
    if review == nil then
      return base
    end
    if type(review) ~= "table" then
      error("review must be a table")
    end
    if review.ignore ~= nil then
      if type(review.ignore) ~= "table" or (next(review.ignore) ~= nil and #review.ignore == 0) then
        error("review.ignore must be a list of gitignore-syntax pattern strings")
      end
      for _, entry in ipairs(review.ignore) do
        if type(entry) ~= "string" or vim.trim(entry) == "" then
          error("review.ignore entries must be non-empty gitignore-syntax pattern strings")
        end
      end
    end
    local out = vim.tbl_deep_extend("force", base, review)
    if type(out.tabs) ~= "boolean" then
      out.tabs = base.tabs
    end
    out.ignore = {}
    for _, entry in ipairs((review.ignore ~= nil) and review.ignore or (base.ignore or {})) do
      out.ignore[#out.ignore + 1] = entry
    end
    return out
  end

  -- Expand each dir string via vim.fn.expand; fall back to defaults if empty.
  local function normalize_skill_dirs(dirs)
    local base = vim.deepcopy(defaults.skill_dirs)
    if type(dirs) ~= "table" then
      return base
    end
    local out = {}
    for _, d in ipairs(dirs) do
      if type(d) == "string" and d ~= "" then
        out[#out + 1] = vim.fn.expand(d)
      end
    end
    if #out == 0 then
      return base
    end
    return out
  end

  --- Shape only. A `write_roots` entry that does not exist or lands inside the
  --- state root is a TURN-START refusal naming the root (`shadow/preview.lua`'s
  --- resolve_roots), not a setup error: the directory may legitimately appear
  --- after the editor started, and a refusal that names the offending root at the
  --- moment a turn needs it is the actionable one.
  ---
  --- Overlap is set arithmetic: turn start unions the opened workspace with every
  --- declared root and keeps only maximal canonical paths before claims or mounts
  --- exist. An ancestor root absorbs the opened workspace and becomes root 1.
  ---
  --- Entries are sorted here. Acquisition order is fixed after maximal-set
  --- reduction, so two editors racing for the same final root set attempt claims
  --- in the same sequence and neither ends up holding half.
  local function normalize_write_roots(roots)
    if roots == nil then
      return {}
    end
    if type(roots) ~= "table" then
      error("write_roots must be a list of absolute directory paths")
    end
    local out, seen = {}, {}
    for _, entry in ipairs(roots) do
      if type(entry) ~= "string" or entry == "" then
        error("write_roots entries must be non-empty absolute directory paths")
      end
      local expanded = vim.fn.expand(entry)
      if type(expanded) ~= "string" or expanded == "" then
        error("write_roots entry could not be expanded: " .. entry)
      end
      if expanded:sub(1, 1) ~= "/" then
        error("write_roots entries must be absolute paths (a leading ~ is expanded): " .. entry)
      end
      expanded = expanded:gsub("/+$", "")
      if expanded == "" then
        error("write_roots may not declare the filesystem root")
      end
      if not seen[expanded] then
        seen[expanded] = true
        out[#out + 1] = expanded
      end
    end
    table.sort(out)
    return out
  end

  -- Merge value over defaults; error if not a table; validate max_entries.
  local function normalize_single_file(value)
    local base = vim.deepcopy(defaults.single_file)
    if value == nil then
      return base
    end
    if type(value) ~= "table" then
      error("single_file must be a table")
    end
    local out = vim.tbl_deep_extend("force", base, value)
    out.enabled = out.enabled ~= false
    if type(out.max_entries) ~= "number" or out.max_entries < 0 then
      error("single_file.max_entries must be a non-negative number")
    end
    out.max_entries = math.floor(out.max_entries)
    return out
  end

  --- Shape only, with the same delayed-validation pattern as write_roots:
  --- existence and ancestor/state-root questions are TURN-START refusals naming the directory
  --- (`shadow/preview.lua`'s `workspace_for_turn`/`broad_root_for`), because the
  --- directory may legitimately appear after the editor started.
  local function normalize_workspace_roots(roots)
    if roots == nil then
      return {}
    end
    if type(roots) ~= "table" then
      error("workspace_roots must be a list of absolute directory paths")
    end
    local out, seen = {}, {}
    for _, entry in ipairs(roots) do
      if type(entry) ~= "string" or entry == "" then
        error("workspace_roots entries must be non-empty absolute directory paths")
      end
      local expanded = vim.fn.expand(entry)
      if type(expanded) ~= "string" or expanded == "" then
        error("workspace_roots entry could not be expanded: " .. entry)
      end
      if expanded:sub(1, 1) ~= "/" then
        error("workspace_roots entries must be absolute paths (a leading ~ is expanded): " .. entry)
      end
      expanded = expanded:gsub("/+$", "")
      if expanded == "" then
        error("workspace_roots may not declare the filesystem root")
      end
      if not seen[expanded] then
        seen[expanded] = true
        out[#out + 1] = expanded
      end
    end
    -- Longest first: the NEAREST configured root wins when two of them nest,
    -- which is the same "nearest wins" rule the `.git` walk already uses.
    table.sort(out, function(a, b)
      if #a == #b then
        return a < b
      end
      return #a > #b
    end)
    return out
  end

  --- Shape only. One absolute directory or nil; everything else is a TURN-START
  --- refusal naming it.
  local function normalize_capture_root(root)
    if root == nil or root == "" then
      return nil
    end
    if type(root) ~= "string" then
      error("capture_root must be an absolute directory path, or nil")
    end
    local expanded = vim.fn.expand(root)
    if type(expanded) ~= "string" or expanded == "" then
      error("capture_root could not be expanded: " .. root)
    end
    if expanded:sub(1, 1) ~= "/" then
      error("capture_root must be an absolute path (a leading ~ is expanded): " .. root)
    end
    expanded = expanded:gsub("/+$", "")
    if expanded == "" then
      error("capture_root may not be the filesystem root")
    end
    return expanded
  end

  --- Ordered broad-root candidate paths. Shape is fixed at setup; existence,
  --- ancestry, and state-root containment are turn-start filesystem facts.
  local function normalize_capture_root_candidates(roots)
    if roots == nil then
      return {}
    end
    if type(roots) ~= "table" then
      error("capture_root_candidates must be a list of absolute directory paths")
    end
    local out, seen = {}, {}
    for _, entry in ipairs(roots) do
      if type(entry) ~= "string" or entry == "" then
        error("capture_root_candidates entries must be non-empty absolute directory paths")
      end
      local expanded = vim.fn.expand(entry)
      if type(expanded) ~= "string" or expanded == "" then
        error("capture_root_candidates entry could not be expanded: " .. entry)
      end
      if expanded:sub(1, 1) ~= "/" then
        error("capture_root_candidates entries must be absolute paths (a leading ~ is expanded): " .. entry)
      end
      expanded = expanded:gsub("/+$", "")
      if expanded == "" then
        error("capture_root_candidates may not declare the filesystem root")
      end
      if not seen[expanded] then
        seen[expanded] = true
        out[#out + 1] = expanded
      end
    end
    return out
  end

  -- Validate/dedupe single-component prefix names; error on separators.
  local function normalize_artifact_dir_prefixes(prefixes)
    if prefixes == nil then
      return {}
    end
    if type(prefixes) ~= "table" then
      error("artifact_dir_prefixes must be a list of directory component names or globs")
    end
    local out, seen = {}, {}
    for _, name in ipairs(prefixes) do
      if type(name) ~= "string"
        or name == ""
        or name == "."
        or name == ".."
        or name:find("/", 1, true)
        or name:find("\\", 1, true)
        or name:find("\0", 1, true)
      then
        error("artifact_dir_prefixes entries must be single directory component names or globs")
      end
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
    table.sort(out)
    return out
  end

  -- Resolve each entry to a real executable path; dedupe, sort, or error.
  local function normalize_inline_exec_allowlist(list)
    if list == nil then
      return nil
    end
    if type(list) ~= "table" then
      error("inline_exec_allowlist must be nil or a list of executable basenames/paths")
    end
    local out, seen = {}, {}
    for _, entry in ipairs(list) do
      if type(entry) ~= "string" or entry == "" or entry:find("\0", 1, true) then
        error("inline_exec_allowlist entries must be non-empty executable basenames/paths")
      end
      local resolved
      if entry:sub(1, 1) == "/" or entry:sub(1, 1) == "~" then
        resolved = vim.fn.expand(entry)
      else
        resolved = vim.fn.exepath(entry)
        if resolved == "" then
          error("inline_exec_allowlist entry is not executable on PATH: " .. entry)
        end
      end
      resolved = vim.loop.fs_realpath(resolved) or vim.fn.fnamemodify(resolved, ":p")
      if vim.fn.executable(resolved) ~= 1 then
        error("inline_exec_allowlist entry is not executable: " .. resolved)
      end
      if not seen[resolved] then
        seen[resolved] = true
        out[#out + 1] = resolved
      end
    end
    table.sort(out)
    return out
  end

  return {
    normalize_selection_scope = normalize_selection_scope,
    normalize_image_paste = normalize_image_paste,
    normalize_redirect = normalize_redirect,
    normalize_inline_edit = normalize_inline_edit,
    normalize_log_level = normalize_log_level,
    normalize_sandbox = normalize_sandbox,
    normalize_review = normalize_review,
    normalize_skill_dirs = normalize_skill_dirs,
    normalize_write_roots = normalize_write_roots,
    normalize_single_file = normalize_single_file,
    normalize_workspace_roots = normalize_workspace_roots,
    normalize_capture_root = normalize_capture_root,
    normalize_capture_root_candidates = normalize_capture_root_candidates,
    normalize_artifact_dir_prefixes = normalize_artifact_dir_prefixes,
    normalize_inline_exec_allowlist = normalize_inline_exec_allowlist,
  }
end

return M
