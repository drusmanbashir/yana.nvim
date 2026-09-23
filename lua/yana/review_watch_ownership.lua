-- Per-row HUNK OWNERSHIP, answered from the live syntax tree.
--
--
-- Why a FACTORY and not a plain module: every one of these predicates closes
-- over exactly two things -- the attached `bufnr` and the review `state`
-- (for `state.hunk_ledger`) -- and there is one instance per attached buffer.
-- That is the same shape `review_watch.attach` already had; only the file
-- boundary moved.
local M = {}

--- The live syntax tree root for `bufnr`, or a LOUD FAILURE. A buffer whose
--- language has no parser has no ownership answer, only a guess: the fallback
--- that used to stand here judged an operator-typed row "owned" and hid a
--- treesitter-rule bug for hours.
--- No caller may catch this and substitute an answer. `state` carries the
--- notify latch, so the operator sees it once per buffer per review rather
--- than once per keystroke; `review_hunk_split` shares this one raiser.
function M.tree_root(bufnr, state)
  local filetype = vim.bo[bufnr].filetype
  if filetype == "" then
    local ok, matched = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(bufnr) })
    if ok and matched then
      filetype = matched
    end
  end
  local lang = filetype ~= "" and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
  local function fail()
    local msg = ("yana: hunk ownership cannot be resolved for %s: filetype %q (treesitter language %q) has no parser")
      :format(vim.api.nvim_buf_get_name(bufnr), filetype, lang or filetype)
    if type(state) == "table" and not state.no_parser_notified then
      state.no_parser_notified = true
      vim.notify(msg, vim.log.levels.ERROR)
    end
    error(msg, 0)
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    fail()
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    fail()
  end
  local root = trees[1]:root()
  if not root then
    fail()
  end
  return root
end

-- The smallest named node at a row's first non-blank column: where every
-- question below starts.
local function node_at(bufnr, root, line_1)
  local line = (vim.api.nvim_buf_get_lines(bufnr, line_1 - 1, line_1, false) or {})[1]
  if line == nil then
    return nil
  end
  local row = line_1 - 1
  local first_col = (line:find("%S") or 1) - 1
  return root:named_descendant_for_range(row, first_col, row, first_col + 1)
end

--- MERGE GEOMETRY's question, which is NOT the ownership question: not "whose
--- row is this" but "are these two rows on opposite sides of a CLASS boundary".
--- `review_hunk_split` asks it here so this module stays the only one that
--- walks the tree. The veto fires only when both rows resolve to a class and
--- those classes differ; no parser fails loud through the one raiser above.
function M.same_class_scope(bufnr, line_a, line_b, state)
  local root = M.tree_root(bufnr, state)
  local node_a, node_b = node_at(bufnr, root, line_a), node_at(bufnr, root, line_b)
  if node_a == nil or node_b == nil then
    return true
  end
  local function nearest_class(node)
    while node do
      if node:type() == "class_definition" then
        return node
      end
      node = node:parent()
    end
    return nil
  end
  local class_a, class_b = nearest_class(node_a), nearest_class(node_b)
  if class_a == nil and class_b == nil then
    return true
  end
  return class_a == class_b
end

--- new(bufnr, state) -> { edge_line_is_yana_owned, interior_line_is_yana_owned }
--- Both are thin wrappers over ONE classifier, `row_is_yana_owned`: the rule
--- below is the whole rule, and no caller gets a second one.
--- `interior_line_is_yana_owned` is also what `review_watch` publishes as
--- `state._row_is_yana_owned` -- review_hunk_split's `try_split` classify
--- callback, and the `classify` injected into `hunk_extent`.
function M.new(bufnr, state)
  local function text_at(line_1)
    return (vim.api.nvim_buf_get_lines(bufnr, line_1 - 1, line_1, false) or {})[1]
  end

  -- Created-file (change.before == nil): the whole file is one contiguous hunk,
  -- every row owned, blanks included, and the tree is never asked.
  local function is_created_file()
    local change = state.change
    return type(change) == "table" and change.before == nil
  end

  -- A member no flush claim has made provisional (F-OWN-PROVISION). A
  -- provisional anchor is a claim, not an owner: it settles nothing, so a row a
  -- flush has claimed can neither prove its own ownership nor vouch for a row
  -- nested under it.
  local function settled_owns_row(row)
    -- A row the running leave-insert pass has already judged the hunk's. Rows
    -- are judged top-down, so a header typed in the same insert session as its
    -- body is settled before the body asks; `review_watch_batch_insert_leave`
    -- owns this table and drops it when the pass ends.
    local pass = state.pass_settled_rows
    if type(pass) == "table" and pass[row] then
      return true
    end
    for _, block in ipairs(state.hunk_ledger:pending()) do
      for _, owner in ipairs(block.owned_rows or {}) do
        if owner.row == row and not owner.provisional then
          return true
        end
      end
    end
    return false
  end

  -- The recorded source text of a SETTLED anchor for this exact row, or nil.
  -- Anchors carry `{ row, source, provisional }` (`hunk_extent_anchor.lua`), and
  -- only the text can say that the row under an anchor is still the row the
  -- anchor was taken from.
  local function settled_anchor_source(row)
    for _, block in ipairs(state.hunk_ledger:pending()) do
      for _, owner in ipairs(block.owned_rows or {}) do
        if owner.row == row and not owner.provisional then
          return owner.source
        end
      end
    end
    return nil
  end

  -- The nearest CONTAINER holding `line_1`: the first ancestor that is neither a
  -- `block`/`module` wrapper nor an `ERROR` (rule 6 -- a half-typed row is
  -- judged from its nearest clean ancestor) and that does not START on the row
  -- itself, because a row cannot vouch for itself.
  local function container_above(root, line_1)
    local node = node_at(bufnr, root, line_1)
    if node == nil then
      -- A parsed buffer with no node under a non-blank row is the no-parser
      -- case again: no answer exists, so none is invented.
      error(("yana: hunk ownership cannot be resolved for %s: row %d has no syntax node")
        :format(vim.api.nvim_buf_get_name(bufnr), line_1), 0)
    end
    local row = line_1 - 1
    while node do
      local t = node:type()
      if t ~= "block" and t ~= "ERROR" and t ~= "module" and node:start() ~= row then
        return node
      end
      node = node:parent()
    end
    return nil
  end

  -- THE RULE. A row inherits from the container it sits in: the NEAREST
  -- container above decides and nothing above that. Its header row settled as a
  -- hunk member makes the row the hunk's; base text or the operator's own text
  -- makes it the operator's. No container at all is module scope, which in an
  -- existing file is the operator's (F-OWN-DEF rule 3).
  local function container_owner(root, line_1)
    local node = container_above(root, line_1)
    if node == nil then
      return false
    end
    return settled_owns_row(node:start() + 1)
  end

  -- THE ONE CLASSIFIER. Paint is never evidence here: a colour is this rule's
  -- output, and reading it back made a row's answer depend on the debounce that
  -- painted it.
  local function row_is_yana_owned(line_1)
    if is_created_file() then
      return true
    end
    local line = text_at(line_1)
    if line == nil or line:match("^%s*$") then
      -- Existing file: a blank row is the operator's UNLESS the ledger already
      -- holds a SETTLED ANCHOR for this exact row whose recorded source is this
      -- exact text -- the proposal's own separator, transported onto this row and
      -- unedited. Without that the row the agent proposed stops being anybody's
      -- the moment a partition runs past it. The proof is the anchor's own text:
      -- a provisional anchor is a claim (F-OWN-PROVISION) and the running pass's
      -- settled-row table is a boolean with nothing behind it, so neither may
      -- vouch for a blank -- the same distinction the InsertLeave judge draws.
      return line ~= nil and settled_anchor_source(line_1) == line
    end
    -- The tree is asked for FIRST, before any ledger answer: an existing file
    -- whose language has no parser gets the loud raise and never a verdict
    -- (u_no_parser_ownership_fails_loud).
    local root = M.tree_root(bufnr, state)
    -- The ledger's own settled record of a member, which no syntax question
    -- overturns (F-OWN-DEF 1).
    if settled_owns_row(line_1) then
      return true
    end
    return container_owner(root, line_1)
  end

  -- The adjacent hunk row is not part of the question any more: an edge row is
  -- judged by its own container, exactly like an interior one. The parameter
  -- stays so the two call sites in `review_watch_batch` read unchanged.
  local function edge_line_is_yana_owned(edge_line, _adjacent_hunk_line)
    return row_is_yana_owned(edge_line)
  end

  -- `ignore_own_provisional` is the InsertLeave re-judgement switch and is now a
  -- NO-OP: under the rule above a provisional anchor is ignored for every row,
  -- so there is nothing left for the flag to withhold. It is kept only so
  -- `review_watch_batch_insert_leave`'s call site needs no edit.
  local function interior_line_is_yana_owned(line_1, _ignore_own_provisional)
    return row_is_yana_owned(line_1)
  end

  return {
    edge_line_is_yana_owned = edge_line_is_yana_owned,
    interior_line_is_yana_owned = interior_line_is_yana_owned,
  }
end

return M
