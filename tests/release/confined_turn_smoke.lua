-- Exercise the public MCP launcher with a private agent working directory.
if vim.env.YANA_REPO_DIR and vim.env.YANA_REPO_DIR ~= "" then
  error("contaminated environment: YANA_REPO_DIR is set")
end
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local scratch = assert(vim.env.YANA_CONFINED_SCRATCH)

local workspace, state_root = scratch .. "/ws", scratch .. "/state"
local runtime = state_root .. "/mcp-runtime/ymtest"
vim.fn.mkdir(workspace, "p")
vim.fn.mkdir(runtime, "p")
vim.fn.writefile({ "seed" }, workspace .. "/seed.txt")
vim.fn.writefile({ "doomed" }, workspace .. "/doomed.txt")
local result = vim.system({
  root .. "/bin/yana-confine", "--workspace", workspace, "--runtime-dir", runtime,
  "--session-auto", "--turn", "release-smoke", "--mode", "inline", "--",
  "sh", "-c", [[
    set -eu
    test "$PWD" = "$2/mcp-agent"
    test ! -e seed.txt
    test -z "${NVIM:-}"
    printf 'runtime writable' > "$1/marker"
  ]], "sh", runtime, state_root,
}, { text = true, env = { YANA_STATE_ROOT = state_root } }):wait()
assert(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
assert(vim.deep_equal(vim.fn.readfile(workspace .. "/seed.txt"), { "seed" }))
assert(vim.deep_equal(vim.fn.readfile(workspace .. "/doomed.txt"), { "doomed" }))
assert(vim.fn.filereadable(workspace .. "/created.txt") == 0)
assert(vim.fn.filereadable(runtime .. "/marker") == 1)
print("ALL PASS: yana confined turn smoke")
