-- yana: structural edit zone for a visual selection + diff validation.
local diff = require("yana.diff")
local config = require("yana.config")

local M = {}

local BLOCK_NODE_TYPES = {
  function_definition = "function",
  class_definition = "class",
  method_definition = "method",
  decorated_definition = "definition",
}

local function line_count(text)
  if text == nil or text == "" then
    return 0
  end
  return #vim.split(text, "\n", { plain = true })
end

local function normalize_path(path)
  if not path or path == "" then
    return ""
  end
  return vim.fs.normalize(diff.abs_path(path))
end

local function paths_match(a, b)
  if a == "" or b == "" then
    return false
  end
  return normalize_path(a) == normalize_path(b)
end

local function node_label(node_type, name)
  local kind = BLOCK_NODE_TYPES[node_type] or node_type
  if name and name ~= "" then
    return kind .. " " .. name
  end
  return kind
end

local function node_name_from_tsnode(node, buf)
  for child in node:iter_children() do
    if child:type() == "identifier" or child:type() == "name" or child:type() == "property_name" then
      return vim.treesitter.get_node_text(child, buf)
    end
    if child:type() == "attribute" then
      local ident = child:child(0)
      if ident then
        return vim.treesitter.get_node_text(ident, buf)
      end
    end
  end
  return nil
end

local function block_body_start(node)
  for child in node:iter_children() do
    local t = child:type()
    if t == "block" or t == "class_body" or t == "statement_block" or t == "declaration_list" then
      return child:start() + 1
    end
  end
  return node:start() + 2
end

local function resolve_block_node(node)
  if not node then
    return nil
  end
  if BLOCK_NODE_TYPES[node:type()] then
    return node
  end
  if node:type() == "decorated_definition" then
    for child in node:iter_children() do
      if BLOCK_NODE_TYPES[child:type()] then
        return child
      end
    end
  end
  local parent = node:parent()
  while parent do
    if BLOCK_NODE_TYPES[parent:type()] or parent:type() == "decorated_definition" then
      return resolve_block_node(parent)
    end
    parent = parent:parent()
  end
  return nil
end

local function scope_opts()
  return config.options.selection_scope or {}
end

local function line_matches_marker(line, marker)
  local trimmed = line:match("^%s*(.*)$") or line
  if trimmed == marker then
    return true
  end
  return trimmed:sub(1, #marker + 1) == marker .. " "
end

local function cell_scope(buf, selection)
  local markers = scope_opts().cell_markers or { "# %%", "#%%" }
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local l1 = selection.l1
  local cell_start = nil
  for ln = l1, 1, -1 do
    local line = lines[ln] or ""
    for _, marker in ipairs(markers) do
      if line_matches_marker(line, marker) then
        cell_start = ln
        break
      end
    end
    if cell_start then
      break
    end
  end
  if not cell_start then
    return nil
  end

  local cell_end = #lines
  for ln = cell_start + 1, #lines do
    local line = lines[ln] or ""
    for _, marker in ipairs(markers) do
      if line_matches_marker(line, marker) then
        cell_end = ln - 1
        break
      end
    end
    if cell_end < #lines then
      break
    end
  end
  if cell_end < cell_start then
    cell_end = cell_start
  end

  local body_l1 = cell_start
  for ln = cell_start, cell_end do
    local line = lines[ln] or ""
    for _, marker in ipairs(markers) do
      if line_matches_marker(line, marker) then
        body_l1 = ln + 1
      end
    end
  end
  if body_l1 > cell_end then
    body_l1 = cell_start
  end

  return {
    path = selection.name,
    selection_l1 = selection.l1,
    selection_l2 = selection.l2,
    zone_l1 = cell_start,
    zone_l2 = cell_end,
    body_l1 = body_l1,
    node_kind = "cell",
    node_name = nil,
    node_end = cell_end,
    header_l1 = cell_start,
  }
end

local function module_statement_scope(buf, selection, node)
  if not node then
    return nil
  end
  local stmt = node
  while stmt do
    local parent = stmt:parent()
    if parent and parent:type() == "module" then
      local header_l1 = stmt:start() + 1
      local _, _, erow, ecol = stmt:range()
      local node_end = (ecol == 0) and erow or (erow + 1)
      return {
        path = selection.name,
        selection_l1 = selection.l1,
        selection_l2 = selection.l2,
        zone_l1 = header_l1,
        zone_l2 = node_end,
        body_l1 = header_l1,
        node_kind = "statement",
        node_name = nil,
        node_end = node_end,
        header_l1 = header_l1,
      }
    end
    stmt = parent
  end
  return nil
end

local function bare_selection_scope(selection, enforce)
  local l1, l2 = selection.l1, selection.l2
  return {
    path = selection.name,
    selection_l1 = l1,
    selection_l2 = l2,
    zone_l1 = l1,
    zone_l2 = l2,
    body_l1 = l1,
    node_kind = "selection",
    node_name = nil,
    node_end = l2,
    enforce = enforce,
  }
end

local function widen_unstructured_scope(buf, selection, node)
  local cell = cell_scope(buf, selection)
  if cell then
    return cell
  end
  local stmt = module_statement_scope(buf, selection, node)
  if stmt then
    return stmt
  end
  return bare_selection_scope(selection, scope_opts().unstructured or "warn")
end

local function line_indent_col(buf, lnum)
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local ws = line:match("^(%s*)")
  return ws and #ws or 0
end

local function treesitter_scope(buf, selection)
  if not vim.treesitter then
    return nil
  end
  local ft = selection.filetype or vim.bo[buf].filetype
  if ft == "" then
    return nil
  end
  local lang = ft
  if vim.treesitter.language and vim.treesitter.language.get_lang then
    lang = vim.treesitter.language.get_lang(ft) or ft
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return nil
  end
  local root = tree:root()
  local l1, l2 = selection.l1, selection.l2
  -- Column 0 is often leading whitespace belonging to an enclosing block
  -- (e.g. class body), which makes descendant_for_range pick the class
  -- instead of a nested function. Use the indent column of each line.
  local c1 = line_indent_col(buf, l1)
  local c2 = line_indent_col(buf, l2)
  local node = root:descendant_for_range(l1 - 1, c1, l2 - 1, c2)
  if not node then
    return nil
  end
  local block = resolve_block_node(node)
  if not block then
    return widen_unstructured_scope(buf, selection, node)
  end

  local header_l1 = block:start() + 1
  local body_l1 = block_body_start(block)
  if body_l1 <= header_l1 then
    body_l1 = header_l1 + 1
  end
  -- TSNode:range() is 0-based; end_col is exclusive. Convert to inclusive 1-based.
  local _, _, erow, ecol = block:range()
  local node_end = (ecol == 0) and erow or (erow + 1)
  local name = node_name_from_tsnode(block, buf)

  local zone_l1, zone_l2
  if l1 <= header_l1 and header_l1 <= l2 then
    zone_l1 = math.max(body_l1, l1)
    zone_l2 = math.min(node_end, l2)
  else
    zone_l1 = l1
    zone_l2 = math.min(node_end, l2)
  end
  if zone_l1 > zone_l2 then
    zone_l1 = l1
    zone_l2 = l2
    body_l1 = l1
  end

  return {
    path = selection.name,
    selection_l1 = l1,
    selection_l2 = l2,
    zone_l1 = zone_l1,
    zone_l2 = zone_l2,
    body_l1 = body_l1,
    node_kind = BLOCK_NODE_TYPES[block:type()] or block:type(),
    node_name = name,
    node_end = node_end,
    header_l1 = header_l1,
  }
end

local function indent_of_line(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

local function indent_scope(buf, selection)
  local l1, l2 = selection.l1, selection.l2
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local header_l1 = nil
  local header_indent = nil

  for ln = l1, 1, -1 do
    local line = lines[ln] or ""
    local indent, def_name = line:match("^(%s*)def%s+([%w_]+)")
    local class_indent, class_name = line:match("^(%s*)class%s+([%w_]+)")
    if def_name or class_name then
      header_l1 = ln
      header_indent = indent_of_line(line)
      local name = def_name or class_name
      local kind = def_name and "function" or "class"
      local body_l1 = ln + 1
      local node_end = l2
      for i = ln + 1, #lines do
        local body = lines[i] or ""
        if body:match("%S") and indent_of_line(body) <= header_indent then
          node_end = i - 1
          break
        end
        node_end = i
      end

      local zone_l1, zone_l2
      if l1 <= header_l1 and header_l1 <= l2 then
        zone_l1 = math.max(body_l1, l1)
        zone_l2 = math.min(node_end, l2)
      else
        zone_l1 = l1
        zone_l2 = math.min(node_end, l2)
      end
      if zone_l1 > zone_l2 then
        zone_l1 = l1
        zone_l2 = l2
        body_l1 = l1
      end

      return {
        path = selection.name,
        selection_l1 = l1,
        selection_l2 = l2,
        zone_l1 = zone_l1,
        zone_l2 = zone_l2,
        body_l1 = body_l1,
        node_kind = kind,
        node_name = name,
        node_end = node_end,
        header_l1 = header_l1,
      }
    end
  end

  return widen_unstructured_scope(buf, selection, nil)
end

function M.compute(buf, selection)
  if not selection or not selection.l1 or not selection.l2 then
    return nil
  end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  -- Treesitter is optional; any failure falls back to indent heuristics.
  local ok, scope = pcall(treesitter_scope, buf, selection)
  if ok and scope then
    return scope
  end
  return indent_scope(buf, selection)
end

function M.enforcement_for(scope)
  local cfg = scope_opts()
  if cfg.enforce == "off" then
    return "off"
  end
  if scope and scope.enforce then
    return scope.enforce
  end
  return cfg.enforce or "reject"
end

function M.describe(scope)
  if not scope then
    return nil
  end
  local label = node_label(scope.node_kind, scope.node_name)
  local mode = M.enforcement_for(scope)
  if mode == "reject" then
    return string.format(
      "Edit zone: %s, lines L%d–L%d. Plugin rejects edits outside this range.",
      label,
      scope.zone_l1,
      scope.zone_l2
    )
  end
  if mode == "warn" then
    return string.format(
      "Advisory edit zone: %s, lines L%d–L%d. Out-of-zone edits are flagged but still reviewable.",
      label,
      scope.zone_l1,
      scope.zone_l2
    )
  end
  return string.format("Context: %s, lines L%d–L%d.", label, scope.zone_l1, scope.zone_l2)
end

function M.changed_regions(before, after)
  local old_str = before or ""
  local new_str = after or ""
  if old_str == new_str then
    return {}
  end
  local patch = vim.diff(old_str, new_str, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  })
  local regions = {}
  for _, hunk in ipairs(patch) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    table.insert(regions, {
      before_line = start_a,
      before_count = count_a,
      after_line = start_b,
      after_count = count_b,
      kind = count_a == 0 and "insert" or (count_b == 0 and "delete" or "modify"),
    })
  end
  return regions
end

local function violation_message(scope, region, detail)
  return string.format(
    "edit at before:L%d (%s) outside zone L%d–L%d for %s — %s",
    region.before_line,
    region.kind,
    scope.zone_l1,
    scope.zone_l2,
    node_label(scope.node_kind, scope.node_name),
    detail
  )
end

function M.validate(change)
  if not change then
    return true
  end
  if not change.scope then
    if change.turn_gen == nil or change.turn_scope_missing then
      return false, "scope enforcement unavailable: turn identity or scope record missing"
    end
    if change.turn_had_scope then
      return false, "scope lost for scoped turn"
    end
    return true
  end
  if change.scope.path and change.scope.path ~= "" then
    if not paths_match(change.path, change.scope.path) then
      return true
    end
  end
  local scope = change.scope
  local before = change.before or ""
  local after = change.after or ""
  if before == after then
    return true
  end

  if M.enforcement_for(scope) == "off" then
    return true
  end

  local regions = M.changed_regions(before, after)
  if #regions == 0 then
    return true
  end

  for _, region in ipairs(regions) do
    if region.kind == "insert" then
      -- vim.diff indices: for pure inserts, before_line is one less than the
      -- 1-indexed line before which text is inserted (matches inline_diff).
      local insert_at = region.before_line + 1
      if insert_at < scope.body_l1 then
        local mode = M.enforcement_for(scope)
        local msg = violation_message(scope, region, "insert before block body")
        if mode == "warn" then
          return true, msg
        end
        return false, msg
      end
      if insert_at > scope.zone_l2 + 1 then
        local mode = M.enforcement_for(scope)
        local msg = violation_message(scope, region, "insert below zone")
        if mode == "warn" then
          return true, msg
        end
        return false, msg
      end
      if insert_at < scope.zone_l1 then
        local mode = M.enforcement_for(scope)
        local msg = violation_message(scope, region, "insert above zone")
        if mode == "warn" then
          return true, msg
        end
        return false, msg
      end
    else
      local start = region.before_line
      local finish = region.before_count > 0 and (start + region.before_count - 1) or start
      if finish < scope.zone_l1 or start > scope.zone_l2 then
        local mode = M.enforcement_for(scope)
        local msg = violation_message(scope, region, "change outside zone")
        if mode == "warn" then
          return true, msg
        end
        return false, msg
      end
    end
  end

  return true
end

function M.validate_or_raise(change)
  local ok, reason = M.validate(change)
  return ok, reason
end

return M
