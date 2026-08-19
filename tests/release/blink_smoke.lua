local blink_root = assert(os.getenv("RELEASE_BLINK_ROOT"), "RELEASE_BLINK_ROOT required")
vim.opt.runtimepath:prepend(blink_root)
local kinds = require("blink.cmp.types").CompletionItemKind
assert(type(kinds.Function) == "number" and type(kinds.Variable) == "number", "blink completion kinds unavailable")

local commands = require("blink_yana.commands").new()
local mentions = require("blink_yana.mentions").new()
local command_result, mention_result
commands:get_completions({ line = "plain text", cursor = { 1, 10 } }, function(result)
  command_result = result
end)
mentions:get_completions({ line = "plain text", cursor = { 1, 10 } }, function(result)
  mention_result = result
end)
assert(command_result and #command_result.items == 0, "command adapter did not return a valid empty result")
assert(mention_result and #mention_result.items == 0, "mention adapter did not return a valid empty result")
print("ALL PASS: blink adapters load against pinned blink.cmp")
