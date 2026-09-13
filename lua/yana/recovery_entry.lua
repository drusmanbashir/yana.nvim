-- Non-blocking first-recovery hook shared by every :Yana* command.
local M = {}

function M.schedule(workspace)
	vim.schedule(function()
		pcall(function()
			local ui = require("yana.ui")
			if type(ui.check_recovery) == "function" then
				ui.check_recovery({ workspace = workspace })
			end
		end)
	end)
end

return M
