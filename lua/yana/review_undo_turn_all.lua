-- `U` -- the turn-wide HISTORY operation (, "U is not
-- an action").
--
-- Every UndoAction class is a forward/reverse pair over ONE register row. `U` is
-- neither half of such a pair: it replays nothing, walks no cursor, and takes no row.
-- That is why it sits beside the router rather than inside the taxonomy, and why it
-- lives in its own module: it shares no code with the per-row dispatch, and
-- `review_undo.lua` is at its 500-line ceiling.
--
-- Body moved VERBATIM out of `review_undo.lua`. No behaviour change.
local Factory = {}

--- `env`: `facade` (for `_load_turn_start`, `_undo_rest_of_turn`,
--- `state`, `change`, `log`, `notify_one_line`,
--- `record_decision`, `undo_refuse`, `turn_register`.
function Factory.new(env)
  local M = env.facade
  local state = env.state
  local change = env.change
  local log = env.log
  local notify_one_line = env.notify_one_line
  local record_decision = env.record_decision
  local undo_refuse = env.undo_refuse
  local turn_register = env.turn_register

	local function undo_turn()
	  local n = #state.decisions
	  local loaded, load_err = M._load_turn_start(state)
	  if not loaded then
		undo_refuse("turn-start overlay could not be loaded -- " .. tostring(load_err))
		return
	  end
	  local restored, refused = M._undo_rest_of_turn(state)
	  local workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
	  turn_register.for_workspace(workspace):discard_turn(change.turn_id or change.turn_gen)
	  record_decision(state, "undo_turn", {
		decisions_undone = n,
		hunks = state.hunk_ledger:count(),
		files_undone = #restored + 1,
		files_written_back = 0,
		files_refused = #refused,
	  })

      -- One message for the whole turn, naming how many files it covered.
      local names = { change.rel or change.path }
      for _, rel in ipairs(restored) do
        names[#names + 1] = rel
      end
      local summary = string.format(
        "yana: undid every edit in this turn -- %d file(s) back to the state you were first shown: %s",
        #names,
        table.concat(names, ", ")
      )
      log.write("WARN", summary)
      notify_one_line(summary, vim.log.levels.INFO)
	  if #refused > 0 then
        local rmsg = string.format(
          "yana: %d file(s) could NOT be undone and are still as you left them: %s",
          #refused,
          table.concat(refused, "; ")
        )
        log.write("WARN", rmsg)
        notify_one_line(rmsg, vim.log.levels.WARN)
      end

      -- NOTHING LANDS THE CURSOR. `U` is an undo path, and after undo the
      -- cursor is wherever neovim left it (F-UNDO-CURSOR).
      -- The jump to the turn's first hunk that used to close this branch --
      -- `M._focus_turn_first_hunk` -> `land_on` + `normal! zz` -- is deleted
      -- with the function it called; undo was its only caller.
    end
  return { undo_turn = undo_turn }
end

return Factory
