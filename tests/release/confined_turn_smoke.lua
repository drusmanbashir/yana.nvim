-- One confined turn through the production functions: the fake agent edits,
-- creates and deletes inside the overlay, and not one byte of the real
-- workspace changes before acceptance.
--
-- Contamination guard first, before any plugin module loads: a harness that
-- can see a development checkout proves nothing about the exported tree.
local contaminant = os.getenv("YANA_REPO_DIR")
if contaminant and contaminant ~= "" then
  print("FAIL: contaminated environment: YANA_REPO_DIR is set")
  os.exit(1)
end

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
local scratch = assert(os.getenv("YANA_CONFINED_SCRATCH"), "YANA_CONFINED_SCRATCH required")
local failures = {}

local function check(value, message)
  if value then
    print("PASS: " .. message)
  else
    failures[#failures + 1] = message
    print("FAIL: " .. message)
  end
end

local config = require("yana.config")
config.setup({ mode = "inline" })

local diff = require("yana.diff")
local preview = require("yana.shadow.preview")
local jail = require("yana.shadow.jail")

-- No overlay launcher means the property cannot be tested at all. That is a
-- named refusal with its own exit code, never a fake pass.
if not jail.available() then
  print("CONFINED TURN GATE INCONCLUSIVE: bwrap unavailable")
  os.exit(65)
end

----------------------------------------------------------------------
-- scratch Git workspace
----------------------------------------------------------------------

local workspace = scratch .. "/ws"
vim.fn.delete(workspace, "rf")
vim.fn.mkdir(workspace, "p")
diff.write_file(workspace .. "/seed.txt", "seed\n")
diff.write_file(workspace .. "/doomed.txt", "doomed\n")

local function git(args)
  local cmd = { "git", "-C", workspace, "-c", "user.name=release-gate", "-c", "user.email=release-gate@invalid" }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, {
    text = true,
    env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null" },
  }):wait()
  return result.code == 0, (result.stderr or "") .. (result.stdout or "")
end

local ok_init, init_out = git({ "init", "-q" })
check(ok_init, "scratch workspace is a Git repository: " .. init_out)
local ok_add = git({ "add", "-A" })
local ok_commit, commit_out = git({ "commit", "-q", "-m", "seed" })
check(ok_add and ok_commit, "seed files committed: " .. commit_out)

-- Every byte of the workspace, .git included: content hash of every regular
-- file plus its path, in a stable order.
local function tree_hash(dir)
  local result = vim.system({
    "sh",
    "-c",
    'cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum',
    "_",
    dir,
  }, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr
  end
  return result.stdout
end

local before, before_err = tree_hash(workspace)
check(before ~= nil and before ~= "", "workspace hashed before the turn: " .. tostring(before_err))

----------------------------------------------------------------------
-- one confined turn through the production wrapper
----------------------------------------------------------------------

preview._test.force_state_root = scratch .. "/state"

local function starts_with(s, prefix)
  return type(s) == "string" and s:sub(1, #prefix) == prefix
end

check(starts_with(preview.state_root(), scratch), "turn state root lives under the gate scratch")
check(not starts_with(preview.state_root(), root .. "/"), "turn state root is outside the exported tree")

local session, err = preview.begin_turn({ workspace = workspace, stream = "release", turn_id = "1" })
check(session ~= nil, "preview.begin_turn: " .. tostring(err))
check(session and starts_with(session.layer_dir, scratch), "overlay layer directory lives under the gate scratch")

local agent_argv = {
  "sh",
  "-c",
  "printf 'agent-was-here\\n' >> seed.txt; printf 'fresh-file\\n' > created.txt; rm -f doomed.txt",
}
local cmd, werr = jail.wrap_cmd(agent_argv, session)
check(cmd ~= nil, "jail.wrap_cmd built an overlay argv: " .. tostring(werr))

local out = {}
local job = vim.fn.jobstart(cmd, {
  cwd = workspace,
  stdout_buffered = true,
  stderr_buffered = true,
  on_stdout = function(_, d)
    if d then
      vim.list_extend(out, d)
    end
  end,
  on_stderr = function(_, d)
    if d then
      vim.list_extend(out, d)
    end
  end,
})
check(job > 0, "overlay job started")
local code = vim.fn.jobwait({ job })[1]
check(code == 0, "confined fake agent exited 0 (got " .. tostring(code) .. "): " .. table.concat(out, " | "))

local report, rerr = preview.end_turn(session)
check(report ~= nil, "preview.end_turn: " .. tostring(rerr))

----------------------------------------------------------------------
-- the real workspace is byte-identical; the edits live in the review state
----------------------------------------------------------------------

local after, after_err = tree_hash(workspace)
check(after ~= nil and after ~= "", "workspace hashed after the turn: " .. tostring(after_err))
check(before == after, "workspace bytes identical before and after the turn")

check(diff.read_file_bytes(workspace .. "/seed.txt") == "seed\n", "real seed.txt unchanged")
check(vim.fn.filereadable(workspace .. "/created.txt") == 0, "created.txt did NOT reach the real workspace")
check(vim.fn.filereadable(workspace .. "/doomed.txt") == 1, "doomed.txt still present in the real workspace")

local upper = session and session.upper_dir or ""
check(diff.read_file_bytes(upper .. "/created.txt") == "fresh-file\n", "the create landed in the private upper layer")
check(
  (diff.read_file_bytes(upper .. "/seed.txt") or ""):find("agent-was-here", 1, true) ~= nil,
  "the edit landed in the private upper layer"
)
check(vim.fn.getftype(upper .. "/doomed.txt") == "cdev", "the delete is a whiteout in the upper layer")

local kinds = {}
for _, op in ipairs((report or {}).ops or {}) do
  kinds[op.kind .. " " .. op.rel] = true
end
check(kinds["create created.txt"], "typed report lists create created.txt")
check(kinds["modify seed.txt"], "typed report lists modify seed.txt")
check(kinds["delete doomed.txt"], "typed report lists delete doomed.txt")

preview.release(session)
preview.discard(session)

if #failures > 0 then
  error(string.format("confined turn smoke failed: %s", table.concat(failures, "; ")))
end
print("ALL PASS: yana confined turn smoke")
