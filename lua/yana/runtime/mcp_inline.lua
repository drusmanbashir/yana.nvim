-- One Run's proposal copy; the panel owns publication at agent exit.
local M = {}
local uv = vim.uv or vim.loop
local diff = require("yana.diff")
local view = require("yana.turn.turn_cycle_view")
local artifacts = require("yana.shadow.ops_artifacts")
local control_plane = require("yana.safety.control_plane")
local BOM = "\239\187\191"
-- Keep the original bytes available if another Run is given the same snapshot.
local snapshot_bytes = setmetatable({}, { __mode = "k" })
local next_owner = 0
local function failure(code, message) return { code = code, message = message } end
local function only_keys(value, allowed)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

-- Lua's character index accepts malformed bytes. Match only UTF-8 Unicode
-- scalar values, including the restricted ranges adjacent to surrogates and
-- the shortest and longest encodings. Skip ASCII runs in one search.
local utf8_sequences = {
  "^[\194-\223][\128-\191]",
  "^\224[\160-\191][\128-\191]",
  "^[\225-\236\238-\239][\128-\191][\128-\191]",
  "^\237[\128-\159][\128-\191]",
  "^\240[\144-\191][\128-\191][\128-\191]",
  "^[\241-\243][\128-\191][\128-\191][\128-\191]",
  "^\244[\128-\143][\128-\191][\128-\191]",
}
local function valid_utf8(bytes)
  local pos = bytes:find("[\128-\255]")
  while pos do
    local last
    for _, sequence in ipairs(utf8_sequences) do
      local _, stop = bytes:find(sequence, pos)
      if stop then last = stop; break end
    end
    if not last then return false end
    pos = bytes:find("[\128-\255]", last + 1)
  end
  return true
end

local function admission(context, path, lexical, bytes, unloaded)
  if lexical then
    -- Check the spelling first so a symlink named .git stays protected, then
    -- check where it leads so an alias cannot reach protected contents.
    for _, name in ipairs({ lexical, path }) do
      local git_rel = context.open_git and vim.fs.relpath(context.open_git, name)
      local reason = control_plane.refusal(git_rel == "." and name or git_rel or name, { short = true })
      if reason then return failure("control_plane", reason) end
      local rel = context.workspace and vim.fs.relpath(context.workspace, name) or name
      local artifact = artifacts.named_artifact_root(rel)
      if artifact then return failure("artifact_root", name .. ": refused — named artifact root " .. artifact) end
    end
    if context.snapshot_refusals[path] == diff.NUL_BUFFER_ERROR then
      return failure("nul_text", path .. ": refused — text contains NUL bytes")
    end
  elseif artifacts.contains_nul(bytes) then
    return failure("nul_text", path .. ": refused — text contains NUL bytes")
  elseif unloaded and not valid_utf8(bytes) then
    return failure("invalid_utf8", path .. ": refused — unloaded text must be valid UTF-8")
  end
end

local function text_format(bytes)
  local separator = bytes:find("\n", 1, true)
  local dos = separator and separator > 1 and bytes:sub(separator - 1, separator - 1) == "\r" and not bytes:find("[^\r]\n")
  local mac = not separator and bytes:find("\r", 1, true)
  return {
    fileformat = dos and "dos" or (mac and "mac" or "unix"),
    bomb = vim.startswith(bytes, BOM),
  }
end

local function proposal_rows(entry, bytes)
  local format = text_format(bytes)
  -- A single leading BOM can be a literal character in the first row.
  if format.bomb and vim.startswith(entry.before_rows[1] or "", BOM) and not vim.startswith(bytes, BOM .. BOM) then
    format.bomb = false
  end
  local rows = view.rows_of(bytes, format)
  if #rows == 0 and not entry.unloaded then return { "" } end
  return rows
end

local function rows_text(rows, bytes)
  return (bytes == "" or #rows == 0) and "" or table.concat(rows, "\n") .. "\n"
end
function M.close_review(turn, settled)
  local cycles = turn:cycles()
  local pass, session_id
  for i = #(cycles and cycles.runs or {}), 1, -1 do
    local run = cycles.runs[i]
    if run.acked then pass, session_id = run.pass, run.session_ref.s.yanad_session_id; break end
  end
  if not pass then
    for _, file in ipairs(turn.files) do
      local opts = file.review_state and file.review_state.opts or file.review_opts
      if opts and opts.turn_pass then
        pass, session_id = opts.turn_pass, opts.yanad_session_id
        break
      end
    end
  end
  if not pass then
    settled(false, "the MCP review has no acknowledged Run to close")
    return nil
  end
  require("yana.shadow.preview_settle").send_review_frame("review_close", { session_id = session_id,
    turn_id = pass.turn_id, generation = pass.generation }, "mcp:" .. pass.turn_id .. ":review.close", function(ok, result)
    if ok then
      for _, run in ipairs(cycles.runs) do
        require("yana.turn.turn_lifecycle").close_turn(run.pass, "review_closed")
      end
      require("yana.turn.turn_lifecycle").close_turn(pass, "review_closed")
      settled(true)
    else
      settled(false, type(result) == "table" and result.message or result)
    end
  end)
  return "pending"
end

function M.new(opts)
  opts = opts or {}
  next_owner = next_owner + 1
  local id = tostring(uv.os_getpid()) .. ":" .. tostring(uv.hrtime()) .. ":" .. next_owner
  local context = { id = id, turn_pass = opts.turn_pass, session_id = opts.session_id, workspace = opts.workspace,
    buffers = {}, paths = {}, snapshots = opts.snapshots or {}, input = opts.input, closed = false,
    snapshot_refusals = opts.snapshot_refusals or {},
    open_git = require("yana.shadow.git_shield").open_git({ open_folder = opts.open_folder or vim.fn.getcwd() }) }
  local submitted = {}
  for path, snap in pairs(context.snapshots) do
    local canonical = view.canonical_path(path)
    local bytes = snapshot_bytes[snap]
    if bytes == nil then
      bytes = snap.b0
      snapshot_bytes[snap] = bytes
      snap.b0 = rows_text(view.rows_of(bytes, snap.eol), bytes)
    end
    submitted[canonical] = { snapshot = snap, bytes = bytes, exists = uv.fs_stat(canonical) ~= nil }
  end
  function context:close(done)
    local changed = not self.closed
    self.closed = true
    if self.io_host then self.io_host:close(); self.io_host = nil end
    if done then done(true) end
    return changed
  end
  function context:copies(args)
    if self.closed then return nil, failure("context_closed", "this MCP edit context is closed") end
    if not only_keys(args, { root = true }) or type(args.root) ~= "string" or not vim.startswith(args.root, "/") then
      return nil, failure("invalid_arguments", "copies requires only an absolute root")
    end
    local root = vim.fs.normalize(args.root, { expand_env = false })
    local prefix = root == "/" and root or root .. "/"
    local copies = vim.empty_dict()
    local function put(path, text)
      if path == root or vim.startswith(path, prefix) then copies[path] = text end
    end
    for path, captured in pairs(submitted) do put(path, captured.bytes) end
    for path, input in pairs(self.input and self.input.files or {}) do
      put(path, input.existence == false and vim.NIL or input.bytes_ref)
    end
    for path, entry in pairs(self.paths) do
      if entry.deleted then put(path, vim.NIL)
      elseif entry.present or entry.snapshot then put(path, entry.text) end
    end
    return copies
  end
  local function open_copy(self, name)
    local path = view.canonical_path(name)
    local err = admission(self, path, diff.abs_path_literal(name))
    if err then return nil, err end
    local entry = self.paths[path]
    if not entry then
      local captured = submitted[path]
      local snap = captured and captured.snapshot
      local exists = captured and captured.exists
      local bufnr = snap and snap.bufnr
      local input = self.input and self.input.files[path]
      local before = input and input.bytes_ref or captured and captured.bytes
      if before == nil then
        exists = uv.fs_stat(path) ~= nil
        if exists then
          local err
          before, err = diff.read_file_bytes(path)
          if before == nil then return nil, failure("buffer_unavailable", err) end
        else
          before = ""
        end
      end
      local unloaded = not (snap or (input and input.bufnr))
      err = admission(self, path, nil, before, unloaded)
      if err then return nil, err end
      local format = input and input.eol or snap and snap.eol or text_format(before)
      entry = { path = path, bufnr = bufnr, snapshot = snap, exists = exists, before = before,
        unloaded = unloaded,
        ref = id .. ":buffer:" .. path }
      local proposal = input and input.file and (input.file.proposal or input.file.change)
      entry.kind = proposal and proposal.kind or (exists and "modify" or "create")
      entry.turn_creation = proposal and proposal.kind == "create" or false
      if input then entry.present = input.existence ~= false else entry.present = exists == true end
      entry.deleted = proposal and proposal.kind == "delete"
      entry.renamed_from, entry.renamed_to = proposal and proposal.renamed_from, proposal and proposal.renamed_to
      entry.rename_base = proposal and proposal.review_before
      entry.input_file = input and input.file
      entry.text = entry.before
      entry.before_rows = input and input.lines or view.rows_of(before, format)
      if #entry.before_rows == 0 and not unloaded then entry.before_rows = { "" } end
      entry.rows = entry.before_rows
    end
    if entry.deleted then return nil, failure("file_deleted", "the Run copy was deleted") end
    return entry
  end
  local function record_copy(self, entry)
    self.paths[entry.path], self.buffers[entry.ref] = entry, entry
  end
  function context:open_buffer(args)
    if self.closed then return nil, failure("context_closed", "this MCP edit context is closed") end
    if not only_keys(args, { name = true }) or type(args.name) ~= "string" or args.name == "" then
      return nil, failure("invalid_arguments", "open_buffer requires only a non-empty name")
    end
    local entry, err = open_copy(self, args.name)
    if not entry then return nil, err end
    record_copy(self, entry)
    return { buffer_ref = entry.ref, text = entry.text }
  end
  local function update_copy(self, entry, bytes)
    local err = admission(self, entry.path, nil, bytes, entry.unloaded)
    if err then return nil, err end
    local rows = bytes == entry.text and entry.rows or proposal_rows(entry, bytes)
    local changed = not vim.deep_equal(entry.rows, rows)
    entry.text, entry.rows = bytes, rows
    entry.present = entry.present or changed or (entry.snapshot == nil and entry.input_file == nil)
    return changed
  end
  function context:edit_buffer(args, done)
    local result, err
    if self.closed then err = failure("context_closed", "this MCP edit context is closed")
    elseif not only_keys(args, { buffer_ref = true, after_text = true })
        or type(args.buffer_ref) ~= "string" or type(args.after_text) ~= "string" then
      err = failure("invalid_arguments", "edit_buffer requires only buffer_ref and after_text text")
    else
      local entry = self.buffers[args.buffer_ref]
      if not entry or not entry.present and entry.deleted then err = failure("buffer_refused", "buffer reference is absent or not owned by this Run")
      else
        local changed
        changed, err = update_copy(self, entry, args.after_text)
        if not err then result = { buffer_ref = entry.ref, text = entry.text, changed = changed } end
      end
    end
    if done then done(result, err) end
    return result, err
  end
  function context:replace_text(args)
    if self.closed then return nil, failure("context_closed", "this MCP edit context is closed") end
    if not only_keys(args, { name = true, edits = true }) or type(args.name) ~= "string" or args.name == ""
        or not vim.islist(args.edits) or #args.edits == 0 then
      return nil, failure("invalid_arguments", "replace_text requires only a non-empty name and a non-empty edits list")
    end
    local entry, err = open_copy(self, args.name)
    if not entry then return nil, err end
    local text = entry.text
    for i, edit in ipairs(args.edits) do
      if not only_keys(edit, { old_text = true, new_text = true }) or type(edit.old_text) ~= "string"
          or edit.old_text == "" or type(edit.new_text) ~= "string" then
        return nil, failure("invalid_arguments", ("edit %d: invalid old_text or new_text"):format(i))
      end
      err = admission(self, entry.path, nil, edit.old_text, entry.unloaded)
        or admission(self, entry.path, nil, edit.new_text, entry.unloaded)
      if err then return nil, err end
      local first, last = text:find(edit.old_text, 1, true)
      if not first then return nil, failure("text_not_found", ("edit %d: not found"):format(i)) end
      local count = 1
      local next_match = text:find(edit.old_text, first + 1, true)
      while next_match do
        count = count + 1
        next_match = text:find(edit.old_text, next_match + 1, true)
      end
      if count ~= 1 then return nil, failure("text_not_unique", ("edit %d: found %d times"):format(i, count)) end
      text = text:sub(1, first - 1) .. edit.new_text .. text:sub(last + 1)
    end
    local changed
    changed, err = update_copy(self, entry, text)
    if err then return nil, err end
    record_copy(self, entry)
    return { name = entry.path, changed = changed }
  end
  local function evidence(self, entry)
    if entry.evidence then return true end
    local stat = uv.fs_lstat(entry.path)
    if stat and stat.type ~= "file" then return nil, failure("file_refused", "file actions require a regular file") end
    local bytes, err
    if stat then bytes, err = require("yana.diff").read_file_bytes(entry.path) else bytes = "" end
    if bytes == nil then return nil, failure("file_unavailable", err) end
    local root = self.workspace or vim.fn.fnamemodify(entry.path, ":h")
    entry.evidence = { root = root, rel = vim.fs.relpath(root, entry.path),
      base_state = stat and "file" or "absent", base_hash = vim.fn.sha256(bytes), base_mode = stat and stat.mode % 4096 }
    return true
  end
  function context:delete_file(args)
    if self.closed then return nil, failure("context_closed", "this MCP edit context is closed") end
    if not only_keys(args, { name = true }) or type(args.name) ~= "string" or args.name == "" then
      return nil, failure("invalid_arguments", "delete_file requires only a non-empty name")
    end
    local opened, err = self:open_buffer(args)
    if not opened then return nil, err end
    local entry = self.buffers[opened.buffer_ref]
    if not entry.present then return nil, failure("file_absent", "the Run copy is absent") end
    local ok; ok, err = evidence(self, entry)
    if not ok then return nil, err end
    entry.present, entry.deleted = false, true
    if entry.renamed_from then
      self.paths[entry.renamed_from].renamed_to = nil
      entry.renamed_from = nil
    end
    return { name = entry.path, deleted = true }
  end
  function context:rename_file(args)
    if self.closed then return nil, failure("context_closed", "this MCP edit context is closed") end
    if not only_keys(args, { from = true, to = true }) or type(args.from) ~= "string" or args.from == ""
        or type(args.to) ~= "string" or args.to == "" then
      return nil, failure("invalid_arguments", "rename_file requires only non-empty from and to")
    end
    local path = require("yana.turn.turn_cycle").canonical_path(args.to)
    local target = self.paths[path]
    local source_path = require("yana.turn.turn_cycle").canonical_path(args.from)
    local prior = self.paths[source_path]
    local returning = prior and prior.renamed_from == path
    local input_target = self.input and self.input.files[path]
    if target and target.present or not target and input_target and input_target.existence ~= false
        or (submitted[path] or uv.fs_lstat(path)) and not returning then
      return nil, failure("destination_exists", "the destination already exists")
    end
    local opened, err = self:open_buffer({ name = args.from })
    if not opened then return nil, err end
    local source = self.buffers[opened.buffer_ref]
    if not source.present then return nil, failure("file_absent", "the source Run copy is absent") end
    local ok; ok, err = evidence(self, source)
    if not ok then return nil, err end
    if not returning then
      local dest; dest, err = self:open_buffer({ name = path })
      if not dest then return nil, err end
      target = self.buffers[dest.buffer_ref]
    end
    local origin = source.renamed_from or source.path
    local original = self.paths[origin]
    local linked = original.kind ~= "create" or original.input_file ~= nil
    local base = source.rename_base or (source.input_file and (source.input_file.version_base or source.input_file.base_text)) or source.before
    source.present, source.deleted, source.renamed_from = false, true, nil
    target.present, target.deleted, target.text, target.rows = true, false, source.text, source.rows
    original.renamed_to = linked and path ~= origin and path or nil
    target.renamed_from, target.rename_base = linked and path ~= origin and origin or nil,
      linked and path ~= origin and base or nil
    return { buffer_ref = target.ref, text = target.text }
  end
  function context:changes()
    if self.result_changes then return self.result_changes, self.result_copies end
    local changes, copies = {}, {}
    for path, rec in pairs(self.input and self.input.files or {}) do
      copies[path] = { exists = rec.existence, bytes = rec.bytes_ref, rows = rec.lines, mode = rec.mode, source = "buffer" }
    end
    for path, entry in pairs(self.paths) do
      local existed = entry.kind ~= "create" or (entry.deleted and entry.turn_creation)
      local edited = not vim.deep_equal(entry.rows, entry.before_rows)
      copies[path] = { exists = entry.present, bytes = entry.present and (edited and entry.text or entry.before) or nil,
        rows = entry.present and entry.rows or nil, source = "buffer" }
      if (existed or entry.present) and (not entry.present or not existed or edited or entry.renamed_from) then
        if entry.snapshot then entry.snapshot.carried = true end
        local loaded = view.loaded(entry.bufnr)
        local change = { id = "mcp:" .. id .. ":" .. path, path = path, source = "buffer", status = "pending", shadow_apply = true,
          before = (existed or entry.snapshot) and entry.before or nil, after = entry.present and entry.text or nil,
          kind = entry.present and (existed and "modify" or "create") or "delete", buffer_capture = entry.snapshot,
          renamed_from = entry.renamed_from, renamed_to = entry.renamed_to, review_before = entry.rename_base,
          buf_org = submitted[path] and submitted[path].bytes,
          buf_updated = loaded and diff.buffer_bytes_snapshot(entry.bufnr) or nil,
          tick_done = loaded and vim.api.nvim_buf_get_changedtick(entry.bufnr) or nil }
        if entry.evidence then change = vim.tbl_extend("force", change, entry.evidence) end
        changes[#changes + 1] = change
      end
    end
    table.sort(changes, function(a, b) return a.path < b.path end)
    self.result_changes, self.result_copies = changes, copies
    return changes, copies
  end
  -- The existing review engine takes LF text for its row geometry. Keep the
  -- wire copy and durable bundle in their original bytes.
  function context:review_changes()
    local changes, copies = self:changes()
    local review = {}
    for i, change in ipairs(changes) do
      local entry = self.paths[change.path]
      local snap = change.buffer_capture
      local base = change.before and rows_text(entry.before_rows, change.before)
      local item = vim.tbl_extend("force", {}, change)
      item.before, item.after = base, change.after and rows_text(entry.rows, change.after)
      if snap then
        item.buf_org = snap.b0
        if change.buf_updated and view.loaded(snap.bufnr) then
          item.buf_updated = rows_text(vim.api.nvim_buf_get_lines(snap.bufnr, 0, -1, false), change.buf_updated)
        end
      end
      review[i] = item
    end
    return review, copies
  end
  function context:handle(frame, reply)
    if type(frame) ~= "table" then
      return reply({ id = -1, error = failure("invalid_request", "invalid host request") })
    end
    local args = frame.arguments
    if not only_keys(frame, { id = true, operation = true, arguments = true }) or type(frame.id) ~= "number" then
      return reply({ id = type(frame.id) == "number" and frame.id or -1,
        error = failure("invalid_request", "invalid host request") })
    end
    if self.closed then return reply({ id = frame.id, error = failure("context_closed", "this MCP edit context is closed") }) end
    local method = self[frame.operation]
    if frame.operation ~= "open_buffer" and frame.operation ~= "edit_buffer" and frame.operation ~= "replace_text"
        and frame.operation ~= "delete_file" and frame.operation ~= "rename_file" and frame.operation ~= "copies" then
      return reply({ id = frame.id, error = failure("unsupported_operation", "unsupported file operation") })
    end
    if self.mode == "ask" and frame.operation ~= "copies" then
      return reply({ id = frame.id, error = failure("read_only", "ask mode refuses write tools") })
    end
    local function answer(result, err)
      reply(result and { id = frame.id, result = result } or { id = frame.id, error = err })
    end
    if frame.operation ~= "edit_buffer" then
      local result, err = method(self, args)
      answer(result, err)
    else
      method(self, args, answer)
    end
  end

  return context
end
return M
