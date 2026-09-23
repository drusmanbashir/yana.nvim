-- turn_dialog_smoke.lua -- the End-turn ask (lua/yana/turn/turn_wiring.lua make_ask) on
-- the Neovim that runs it, with no UI attached.
--
-- A fully decided turn must END headless: Turn:end_turn only proceeds on "end",
-- and anything else leaves the review open, so the post-review undo never
-- installs. make_ask tells the real vim.fn.confirm from a test stub by its debug
-- source, and that source moved between Neovim releases (0.11.x @vim/_editor.lua,
-- 0.12.x vim/_core/editor). Stubs must keep their literal answer.
--
-- Run: nvim --clean --headless -u NONE -i NONE -l tests/release/turn_dialog_smoke.lua
-- Exit 0 pass, 1 a check failed.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(repo)

local failures = {}
local function check(cond, msg)
	if cond then
		print("PASS: " .. msg)
	else
		print("FAIL: " .. msg)
		failures[#failures + 1] = msg
	end
end

local ask = require("yana.turn.turn_wiring").make_ask(function()
	return {}
end)
local builtin = vim.fn.confirm
local source = tostring(debug.getinfo(builtin, "S").source)
local version = tostring(vim.version())

check(#vim.api.nvim_list_uis() == 0, "no UI is attached (nvim " .. version .. ")")
check(
	ask("decided", { pending = 0 }) == "end",
	"real confirm (" .. source .. "), no UI: a fully decided turn ends"
)
check(
	ask("undo_exhausted", { pending = 0 }) == "keep",
	"real confirm (" .. source .. "), no UI: an exhausted undo keeps reviewing"
)

vim.fn.confirm = function()
	return 2
end
check(ask("decided", { pending = 0 }) == "keep", "stubbed confirm answering Keep (2) stays keep")
vim.fn.confirm = function()
	return 1
end
check(ask("decided", { pending = 0 }) == "end", "stubbed confirm answering End (1) ends")
vim.fn.confirm = builtin

if #failures > 0 then
	print(string.format("FAILED %d check(s)", #failures))
	os.exit(1)
end
print("ALL PASS: turn dialog smoke nvim=" .. version)
os.exit(0)
