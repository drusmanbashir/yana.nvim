-- Per-row HUNK OWNERSHIP, answered from the live syntax tree.
--
--
-- Why a FACTORY and not a plain module: every one of these predicates closes
-- over exactly two things -- the attached `bufnr` and the review `state`
-- (for `state.hunk_ledger`) -- and there is one instance per attached buffer.
-- That is the same shape `review_watch.attach` already had; only the file
-- boundary moved.
local M = {}

--- new(bufnr, state) -> { edge_line_is_yana_owned, interior_line_is_yana_owned }
--- `interior_line_is_yana_owned` is also what `review_watch` publishes as
--- `state._row_is_yana_owned` -- review_hunk_split's `try_split` classify
--- callback, and the `classify` injected into `hunk_extent`.
function M.new(bufnr, state)
  local function live_tree_root()
    local filetype = vim.bo[bufnr].filetype
    if filetype == "" then
      local ok, matched = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(bufnr) })
      if ok and matched then
        filetype = matched
      end
    end
    local lang = filetype ~= "" and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok or not parser then
      local uname = vim.loop.os_uname()
      local suffix = "/treesitter/" .. uname.sysname .. "-" .. uname.machine .. "/parser/" .. tostring(lang) .. ".so"
      local paths = {}
      if lang then
        paths[#paths + 1] = vim.fn.stdpath("state") .. suffix
        if vim.env.USER and vim.env.USER ~= "" then
          paths[#paths + 1] = "/home/" .. vim.env.USER .. "/.local/state/nvim" .. suffix
        end
      end
      for _, path in ipairs(paths) do
        if vim.fn.filereadable(path) == 1 then
          pcall(vim.treesitter.language.add, lang, { path = path })
          ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
          if ok and parser then
            break
          end
        end
      end
      if not ok or not parser then
        return nil
      end
    end
    local parsed, trees = pcall(parser.parse, parser)
    if not parsed or not trees or not trees[1] then
      return nil
    end
    local root = trees[1]:root()
    if not root then
      return nil
    end
    return root
  end

  -- A half-typed row can have ERROR/MISSING nodes even though its previous
  -- debounce classified it. Keep that prior paint until Treesitter answers
  -- again; a missing parser still follows the explicit no-parser fallbacks.
  local function previous_line_is_yana_owned(line_1)
    local ns = vim.api.nvim_get_namespaces()["YanaInlineDiff"]
    if not ns then
      return false
    end
    local row = line_1 - 1
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
      local details = mark[4] or {}
      if details.hl_group == "YanaDiffIncoming" then
        local end_row = details.end_row or mark[2]
        local last = (details.end_col == 0) and (end_row - 1) or end_row
        if row >= mark[2] and row <= math.max(mark[2], last) then
          return true
        end
      end
    end
    return false
  end

  local function statement_and_container_for_line(root, line_1)
    local line = (vim.api.nvim_buf_get_lines(bufnr, line_1 - 1, line_1, false) or {})[1]
    if line == nil then
      return nil, nil
    end
    local row = line_1 - 1
    local first_col = (line:find("%S") or 1) - 1
    local node = root:named_descendant_for_range(row, first_col, row, first_col + 1)
    if not node then
      return nil, nil
    end
    while node:parent() do
      local parent = node:parent()
      local start_row, _, end_row = parent:range()
      if start_row ~= row or end_row ~= row then
        break
      end
      node = parent
    end
    return node, node:parent()
  end

  -- Return nil for every non-root scope so the ordinary parent rule decides.
  -- Created-file (change.before == nil): module root is yana-owned, including
  -- when the caller is asking about a blank row (contiguous single hunk).
  local function is_created_file()
    local change = state.change
    return type(change) == "table" and change.before == nil
  end

  local function module_scope_is_yana_owned(node)
    if not node or node:parent() ~= nil then
      return nil
    end
    return is_created_file()
  end

  -- A docstring (a bare string literal used as a whole statement) is its own scope
  -- boundary.
  local function is_docstring_statement(node)
    if not node then
      return false
    end
    if node:type() == "expression_statement" then
      local child = node:named_child(0)
      return child ~= nil and child:type() == "string" and node:named_child_count() == 1
    end
    return node:type() == "string"
  end

  local function pending_owns_row(row)
    for _, block in ipairs(state.hunk_ledger:pending()) do
      if state.hunk_ledger:row_is_owned(block, row) then
        return true
      end
    end
    return false
  end

  -- A member no flush claim has made provisional (F-OWN-PROVISION).
  local function pending_settled_owns_row(row)
    for _, block in ipairs(state.hunk_ledger:pending()) do
      for _, owner in ipairs(block.owned_rows or {}) do
        if owner.row == row and not owner.provisional then
          return true
        end
      end
    end
    return false
  end

  -- Geometric containment in a pending hunk's stored band (not ownership).
  local function row_inside_pending_extent(line_1)
    for _, block in ipairs(state.hunk_ledger:pending()) do
      local start_line = block.new_start_line
      local end_line = block.new_end_line or start_line
      if type(start_line) == "number" and type(end_line) == "number"
        and line_1 >= start_line and line_1 <= end_line
      then
        return true
      end
      if state.hunk_ledger:row_is_owned(block, line_1) then
        return true
      end
    end
    return false
  end

  -- WITHIN a pending hunk judged without the row's own identity: the hunk owns
  -- a row above it and a row below it (F-OWN-SHIFT). The no-parser answer for
  -- a re-judged row, whose own anchor cannot vouch for it.
  local function row_between_members(line_1)
    for _, block in ipairs(state.hunk_ledger:pending()) do
      local above, below = false, false
      for _, owner in ipairs(block.owned_rows or {}) do
        if owner.row < line_1 then
          above = true
        elseif owner.row > line_1 then
          below = true
        end
      end
      if above and below then
        return true
      end
    end
    return false
  end

  -- True when some non-block ancestor starts on a pending-owned row.
  -- `block` nodes are skipped: they start at their first statement and would
  -- collapse case 2a (human def, green sibling) into a false positive.
  local function owned_ancestor_start(node)
    while node do
      local t = node:type()
      if t ~= "block" and t ~= "ERROR" and t ~= "module" then
        if pending_owns_row(node:start() + 1) then
          return true
        end
      end
      node = node:parent()
    end
    return false
  end

  -- Nonblank edge text belongs to a hunk only when it shares the hunk row's
  -- direct syntax parent AND some non-block ancestor starts on a hunk-owned
  -- row (case 1 / 2b / nested green if). Case 2a stays human.
  -- Created-file blanks are yana-owned (contiguous single hunk).
  local function edge_line_is_yana_owned(edge_line, adjacent_hunk_line)
    local edge_text = (vim.api.nvim_buf_get_lines(bufnr, edge_line - 1, edge_line, false) or {})[1] or ""
    if edge_text:match("^%s*$") then
      return is_created_file()
    end
    local root = live_tree_root()
    if not root then
      return is_created_file() or false
    end
    local edge_stmt, edge_parent = statement_and_container_for_line(root, edge_line)
    local adjacent_stmt, adjacent_parent = statement_and_container_for_line(root, adjacent_hunk_line)
    local module_owned = module_scope_is_yana_owned(edge_parent)
    if module_owned ~= nil then
      return module_owned
    end
    if edge_parent == nil or adjacent_parent == nil then
      return previous_line_is_yana_owned(edge_line)
    end
    if edge_parent ~= adjacent_parent then
      return false
    end
    if edge_stmt ~= adjacent_stmt and is_docstring_statement(adjacent_stmt) then
      return false
    end
    return owned_ancestor_start(edge_stmt or edge_parent)
  end

  -- `ignore_own_provisional` is the InsertLeave RE-JUDGEMENT switch. When a
  -- partition re-decides whether a touched row is the hunk's or the human's, the
  -- row's OWN provisional ledger anchor must not count as proof of its own
  -- ownership -- that is the very question being asked, and a temporary absorb
  -- extent may have provisionally anchored a human row. Other settled proposal
  -- anchors remain valid parent-rule evidence, so only this row's own identity
  -- is withheld (the `pending_owns_row` short-circuit and its own anchor in the
  -- parent-rule scan). Omitted, every existing caller keeps the prior behaviour.
  local function interior_line_is_yana_owned(line_1, ignore_own_provisional)
    local line = (vim.api.nvim_buf_get_lines(bufnr, line_1 - 1, line_1, false) or {})[1]
    if line == nil or line:match("^%s*$") then
      -- Created file: blanks are yana-owned and must not open hunk boundaries.
      -- Existing file: blank stays human.
      return is_created_file()
    end
    local root = live_tree_root()
    if not root then
      -- No parser: created file stays one contiguous hunk; otherwise only rows
      -- already inside a pending extent stay yana-owned. The re-judgement still
      -- withholds this row's own provisional identity.
      if is_created_file() then
        return true
      end
      if ignore_own_provisional then
        -- A settled member edited in place is still inside its own extent; a
        -- new or provisionally claimed row must lie between other members.
        return pending_settled_owns_row(line_1) or row_between_members(line_1)
      end
      return row_inside_pending_extent(line_1)
    end
    if is_created_file() then
      -- Whole created file is one contiguous green hunk.
      return true
    end
    if pending_owns_row(line_1) and not ignore_own_provisional then
      return true
    end
    if previous_line_is_yana_owned(line_1) then
      local ok_re, root_err = pcall(root.has_error, root)
      if ok_re and root_err then
        return true
      end
    end
    local stmt, parent = statement_and_container_for_line(root, line_1)
    if stmt and stmt:type() == "comment" then
      return true
    end
    local parse_error = false
    if stmt then
      local ok, has_error = pcall(stmt.has_error, stmt)
      parse_error = ok and has_error == true
    end
    if parse_error then
      if previous_line_is_yana_owned(line_1) then
        return true
      end
    end
    if not parent then
      return previous_line_is_yana_owned(line_1)
    end
    -- CONTAINER-HEADER rule (the dual of owned_ancestor_start): a row that OPENS
    -- a named container (def/class/if/for/...) whose body already holds a
    -- pending-owned row is itself owned. This runs BEFORE the module-scope
    -- refinement so a proposed module-level `def` keeps ownership even though a
    -- bare root statement would be human: without it a def header edited in
    -- place (e.g. `A<CR>` appended to it, marking it dirty) loses the ownership
    -- its body keeps, then reads as a non-blank human boundary and a blank gap
    -- splits the hunk (F-OWN-GAP). `ignore_own_provisional` withholds only THIS
    -- row's own anchor, so the body rows still vouch for their header.
    -- It re-affirms a header that is already a SETTLED member and grants
    -- nothing: a new row that happens to open a container over proposal rows
    -- (a human `def` typed above them), even one a flush has provisionally
    -- claimed, is judged by the rules below (F-OWN-DEF 3).
    if pending_settled_owns_row(line_1) then
      local node = stmt or parent
      -- The module root is no container a row opens: a root statement in an
      -- existing file is human (F-OWN-DEF rule 3), even when it is the file's
      -- first row and so starts on the root's own start row.
      while node and node:parent() ~= nil do
        local nsr, _, ner = node:range()
        if nsr == line_1 - 1 and ner > nsr then
          for _, block in ipairs(state.hunk_ledger:pending()) do
            for _, owner in ipairs(block.owned_rows or {}) do
              if owner.row ~= line_1 and owner.row >= nsr + 1 and owner.row <= ner + 1 then
                return true
              end
            end
          end
        end
        if nsr ~= line_1 - 1 then
          break
        end
        node = node:parent()
      end
    end
    local module_owned = module_scope_is_yana_owned(parent)
    if module_owned ~= nil then
      return module_owned
    end
    -- Parent rule: share the direct syntax parent with an owned peer.
    -- Docstring peers do not count as the owned peer.
    --
    -- Scan the block's OWNED-ROW ANCHORS, not the stored [start,end] band. An
    -- interior insert remaps the anchors (the durable ownership record) but does
    -- NOT extend the stored `new_end_line`, so an owned peer displaced past the
    -- stale end is invisible to a band scan — the exact miss that read a green
    -- interior row as human.
    local shared = false
    for _, block in ipairs(state.hunk_ledger:pending()) do
      for _, owner in ipairs(block.owned_rows or {}) do
        local row = owner.row
        if not (ignore_own_provisional and row == line_1) then
        local owned_stmt, owned_parent = statement_and_container_for_line(root, row)
        if owned_parent ~= nil and owned_parent == parent then
          if owned_stmt ~= stmt and is_docstring_statement(owned_stmt) then
            -- skip
          else
            shared = true
            break
          end
        end
        end
      end
      if shared then
        break
      end
    end
    if not shared then
      local ok_root_error, root_has_error = pcall(root.has_error, root)
      if ok_root_error and root_has_error then
        return previous_line_is_yana_owned(line_1)
      end
      return false
    end
    return owned_ancestor_start(stmt or parent)
  end

  return {
    edge_line_is_yana_owned = edge_line_is_yana_owned,
    interior_line_is_yana_owned = interior_line_is_yana_owned,
    previous_line_is_yana_owned = previous_line_is_yana_owned,
  }
end

return M
