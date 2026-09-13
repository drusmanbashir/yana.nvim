-- Compound-mode disclosure ribbon for one open review.
local Factory = {}

function Factory.new(deps)
  local env = setmetatable({}, {
    __index = function(_, key)
      local value = deps[key]
      if value ~= nil then
        return value
      end
      return _G[key]
    end,
  })
  local function setup()
  local function show_compound_mode(change)
    if state.mode_banner_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, HINT_NS, state.mode_banner_id)
      state.mode_banner_id = nil
    end
    local text = compound_mode_text(change)
    if not text then
      return
    end
    state.mode_banner_id = vim.api.nvim_buf_set_extmark(bufnr, HINT_NS, 0, 0, {
      virt_lines = { { { text, EXT_HL.hint } } },
      virt_lines_above = true,
    })
  end
    return {
      show_compound_mode = show_compound_mode,
    }
  end
  setfenv(setup, env)
  return setup()
end

return Factory
