local log = require("yana.log")

local M = {}

-- W5 — deps.ask for a real Turn. Config suppression (negation 5) is deleted for now; it
-- re-enters only under a re-ruling, inside the one gate's own config table — not as a
-- cause-keyed map that never matched Turn causes (decided/undo_exhausted/abort vs
-- leave_edge/floor_pending/floor_decided). The box is byte-identical whatever route
-- reached it -- no per-cause wording, no cost line.
local DIALOG_MSG = "End turn?"
local DIALOG_BUTTONS = "&End turn\n&Keep reviewing"
local NO_UI_DEFAULT = { decided = "end", undo_exhausted = "keep", abort = "keep" }

function M.make_ask(opts_fn)
	return function(cause, ctx)
		-- Log BEFORE the blocking call so the last row on disk names the exact dialog, not
		-- just that something stopped.
		-- The real confirm lives in Neovim's bundled runtime, whose debug source moved:
		-- 0.11.x "@vim/_editor.lua", 0.12.x "vim/_core/editor". Missing either classes
		-- the real dialog as a stub, and a headless decided turn never ends.
		local confirm_source = debug.getinfo(vim.fn.confirm, "S").source
		local is_test_stub = type(confirm_source) == "string"
			and not (confirm_source:find("vim/_core/editor", 1, true) or confirm_source:find("vim/_editor.lua", 1, true))
		local has_ui = false
		do
			local ok_ui, uis = pcall(vim.api.nvim_list_uis)
			has_ui = ok_ui and type(uis) == "table" and #uis > 0
		end
		log.lifecycle_info("turn.dialog.open", {
			cause = cause,
			prompt = DIALOG_MSG,
			buttons = DIALOG_BUTTONS,
			has_ui = has_ui,
		})
		local asked, answer = pcall(vim.fn.confirm, DIALOG_MSG, DIALOG_BUTTONS, 2, "Question")
		-- Headless / no-UI: `confirm` raw-pcalled answers the default (2) silently even with
		-- nobody there to see the box.
		local drawn = asked == true
		if drawn and answer == 2 and not has_ui and not is_test_stub then
			drawn = false
		end
		local mapped
		if not drawn then
			mapped = NO_UI_DEFAULT[cause] or "keep"
		else
			mapped = answer == 1 and "end" or "keep"
		end
		log.lifecycle_info("turn.dialog.choice", {
			cause = cause,
			raw = asked and answer or nil,
			answer = mapped,
		})
		return mapped
	end
end

-- W6 — the live tab handling callback. A small named table for turn:register()
-- acting on `turn_end`, so the order in which the owner registers it is the
-- teardown order (bus LOCKED 3: registration order is execution order).
--
-- PRUNED (manifest): `paint_callback`, `keymap_callback` and `listener_callback`
-- are gone. Namespaces and keys are now released by `review_resources.close`
-- through the owner table that recorded them, and the listener callback had no
-- caller at all (`yana.turn.turn_listeners` stays live for `diff_preview`).

function M.tabs_callback(tabs)
	return {
		name = "tabs",
		turn_end = function(_cb, _ctx)
			if tabs and tabs.close_owned_tabs then
				tabs.close_owned_tabs()
			end
		end,
	}
end

return M
