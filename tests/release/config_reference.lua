-- F-PUBLIC-PACKAGE: option names come from evaluated Lua, never source regex.
local root, list = assert(arg[1], 'TREE required'), arg[2] == '--list'
vim.opt.runtimepath:prepend(root)
local defaults = require('yana.configuration.config_defaults')
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
add('backends', defaults.backends)
for _, descriptor in pairs(defaults.backends) do walk(descriptor, 'backends.<name>') end
-- Lua omits nil-valued entries. These nullable settings cannot be discovered
-- with pairs(); keep this explicit supplement alongside the runtime traversal.
for _, path in ipairs({'cmd', 'model', 'inline_exec_allowlist', 'capture_root',
  'ui.review_buttons.steal_ratio', 'sessions.dir'}) do add(path, vim.NIL) end
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
os.exit(failed and 1 or 0)
