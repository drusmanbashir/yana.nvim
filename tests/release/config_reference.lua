-- F-PUBLIC-PACKAGE: option names come from evaluated Lua, never source regex.
local root, list = assert(arg[1], 'TREE required'), arg[2] == '--list'
vim.opt.runtimepath:prepend(root)
local config = require('yana.config')
if type(config.public_defaults) ~= 'table' then
  print('CONFIG REFERENCE FAIL: public configuration inventory unavailable')
  os.exit(1)
end
local defaults = config.public_defaults
for _, key in ipairs({'backends', 'modes', 'inline_edit', 'log_level'}) do
  if defaults[key] == nil then
    print('CONFIG REFERENCE FAIL: public configuration inventory missing ' .. key)
    os.exit(1)
  end
end
if type(defaults.backends) ~= 'table' or type(defaults.backends.default) ~= 'string' then
  print('CONFIG REFERENCE FAIL: public backend default unavailable')
  os.exit(1)
end
local public_logging = {}
for _, key in ipairs({'log_level', 'profile', 'debug_modules', 'debug_record'}) do
  if defaults[key] ~= nil then table.insert(public_logging, key) end
end
if #public_logging ~= 1 or public_logging[1] ~= 'log_level' then
  print('CONFIG REFERENCE FAIL: public logging inputs must contain only log_level')
  os.exit(1)
end
local paths = {}
local function add(path)
  paths[path] = true
end
local function walk(value, prefix)
  if prefix ~= '' then add(prefix, value) end
  if type(value) ~= 'table' then return end
  for key, child in pairs(value) do
    if type(key) == 'string' then
      walk(child, prefix == '' and key or prefix .. '.' .. key)
    elseif type(child) == 'table' then
      walk(child, prefix .. '[]')
    end -- scalar array items are values, not additional options
  end
end
for key, value in pairs(defaults) do
  if key ~= 'backends' then walk(value, key) end
end
add('backends')
if type(defaults.backends) == 'table' and defaults.backends.default ~= nil then
  add('backends.default')
end
-- Named backend entries have a fixed public wildcard path. Their command and
-- model are optional user inputs omitted from Lua defaults when nil.
add('backends.<name>')
for _, option in ipairs({'cmd', 'model'}) do
  add('backends.<name>.' .. option)
end
local ordered = vim.tbl_keys(paths)
table.sort(ordered)
if list then
  for _, path in ipairs(ordered) do print(path) end
  print('CONFIG REFERENCE PATHS: ' .. #ordered)
  os.exit(0)
end
local function read(path) return table.concat(vim.fn.readfile(root .. '/' .. path), '\n') end
local markdown = read('docs/configuration.md'):gsub('<!%-%-.-%-%->', '')
local help = read('doc/yana.txt')
local start = assert(help:find('*yana-configuration*', 1, true), 'missing yana-configuration help tag')
local stop = help:find('\n==========', start, true)
assert(stop, 'missing end of yana-configuration section')
help = help:sub(start, stop - 1)
local failed = false
for _, document in ipairs({{'docs/configuration.md', markdown}, {'doc/yana.txt:yana-configuration', help}}) do
  local present = {}
  -- A backticked, fully qualified path is an explicit reference entry.
  -- Exact tokens prevent `ui.width_extra` or prose elsewhere from covering ui.width.
  for token in document[2]:gmatch('`([^`\n]+)`') do present[token] = true end
  local count = 0
  for _, path in ipairs(ordered) do
    if present[path] then count = count + 1
    else print('CONFIG REFERENCE FAIL: ' .. document[1] .. ' missing ' .. path); failed = true end
  end
  print(string.format('CONFIG REFERENCE %s: %s %d/%d paths',
    count == #ordered and 'PASS' or 'FAIL', document[1], count, #ordered))
end

-- Every Lua configuration example in the public documents must use only the
-- documented public paths above and pass the real setup without a warning, so a
-- renamed, retired or misspelled setting cannot survive in one document after the
-- code and the reference moved on.
local function balanced(text, open_at)
  local depth = 0
  for i = open_at, #text do
    local c = text:sub(i, i)
    if c == '{' then depth = depth + 1 elseif c == '}' then depth = depth - 1 end
    if depth == 0 then return text:sub(open_at, i) end
  end
end
local function example_tables(name, text)
  local found = {}
  local blocks = {}
  for block in text:gmatch('```lua\n(.-)```') do blocks[#blocks + 1] = block end
  for block in text:gmatch('>lua\n(.-)\n<') do blocks[#blocks + 1] = block end
  for _, block in ipairs(blocks) do
    local hit = false
    for _, pattern in ipairs({'opts%s*=%s*()%{', 'setup%s*%(%s*()%{', 'setup%s*()%{'}) do
      for at in block:gmatch(pattern) do
        local body = balanced(block, at)
        if body then found[#found + 1] = body; hit = true end
      end
    end
    -- docs/configuration.md fragments are fields to merge into `opts`.
    if not hit and name == 'docs/configuration.md' then found[#found + 1] = '{' .. block .. '}'
    elseif not hit and block:find('setup', 1, true) then
      -- A setup call through a variable cannot be checked; examples pass a literal table.
      found[#found + 1] = 'nil --[[ setup without a literal table ]]'
    end
  end
  return found
end
local function example_paths(value, prefix, out)
  for key, child in pairs(value) do
    if type(key) == 'string' then
      local path = prefix == '' and key or prefix .. '.' .. key
      if prefix == 'backends' and key ~= 'default' then path = 'backends.<name>' end
      out[#out + 1] = path
      if type(child) == 'table' then example_paths(child, path, out) end
    end
  end
  return out
end
local example_documents = {'README.md', 'doc/yana.txt'}
for _, file in ipairs(vim.fn.globpath(root, 'docs/*.md', false, true)) do
  example_documents[#example_documents + 1] = file:sub(#root + 2)
end
local examples = 0
for _, name in ipairs(example_documents) do
  if vim.fn.filereadable(root .. '/' .. name) == 1 then
    for _, body in ipairs(example_tables(name, read(name))) do
      local chunk = load('return ' .. body, name, 't', {})
      local ok, value = pcall(chunk or error)
      if not chunk or not ok or type(value) ~= 'table' then
        print('CONFIG EXAMPLE FAIL: ' .. name .. ' has a configuration example that is not a literal table: '
          .. body:gsub('%s+', ' '):sub(1, 80))
        failed = true
      else
        examples = examples + 1
        for _, path in ipairs(example_paths(value, '', {})) do
          if not paths[path] then
            print('CONFIG EXAMPLE FAIL: ' .. name .. ' uses `' .. path .. '`, which is not a public setting')
            failed = true
          end
        end
        local warnings = {}
        local notify = vim.notify
        vim.notify = function(msg, level)
          if (level or 0) >= vim.log.levels.WARN then warnings[#warnings + 1] = msg end
        end
        -- Example executable paths are placeholders; setup checks shape here.
        local candidate = vim.deepcopy(value)
        for _, entry in pairs(type(candidate.backends) == 'table' and candidate.backends or {}) do
          if type(entry) == 'table' and entry.cmd ~= nil then entry.cmd = vim.v.progpath end
        end
        local accepted, err = pcall(config.setup, candidate)
        vim.notify = notify
        if not accepted or #warnings > 0 then
          print('CONFIG EXAMPLE FAIL: ' .. name .. ' example refused or warned by setup: '
            .. tostring(accepted and warnings[1] or err))
          failed = true
        end
      end
    end
  end
end
print(string.format('CONFIG EXAMPLES %s: %d examples checked', failed and 'FAIL' or 'PASS', examples))

-- Every exported tree lacks the adjacent development extension. Probe public
-- setup through the package API so ignored debug settings cannot look accepted.
if vim.fn.filereadable(root .. '/lua/yana/config_development.lua') == 0 then
  if type(config.setup) ~= 'function' then
    print('CONFIG REFERENCE FAIL: public setup function unavailable')
    os.exit(1)
  end
  local ok, err = pcall(config.setup, {log_level = defaults.log_level})
  if not ok then
    print('CONFIG REFERENCE FAIL: public log_level refused: ' .. tostring(err))
    os.exit(1)
  end
  for _, option in ipairs({
    {'profile', 'debugger'},
    {'debug_modules', {'keys'}},
    {'debug_record', true},
  }) do
    local name, value = option[1], option[2]
    local accepted, setup_err = pcall(config.setup, {[name] = value})
    if accepted then
      print('CONFIG REFERENCE FAIL: public setup accepted development option ' .. name)
      os.exit(1)
    end
    if not tostring(setup_err):find(name, 1, true) then
      print('CONFIG REFERENCE FAIL: public setup refusal did not name ' .. name)
      os.exit(1)
    end
  end
end
os.exit(failed and 1 or 0)
