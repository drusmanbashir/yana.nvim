-- Panel autocmds: last-panel tracking, stop-hook focus, WinClosed sibling cleanup.
-- Split from yana.ui_panel (cluster 8 autocmd seam).
local log = require("yana.log")
local views = require("yana.ui_panel_views")

local M = {}

-- deps.state: parent shared state `S` (last_panel, last_focused_panel).
-- deps.win_valid: parent panel bookkeeping.
-- deps.ensure_prompt_win: yana.ui_panel_layout — rebuild THIS panel's own prompt
-- when missing (never adopts another chat's prompt window).
function M.new(deps)
  local S = deps.state
  local win_valid = deps.win_valid
  local ensure_prompt_win = deps.ensure_prompt_win

  -- Each chat owns its prompt. Entering a conversation that lost its prompt
  -- window rebuilds that panel's own prompt under its conversation.
  local function repair_own_prompt(p)
    local tab = vim.api.nvim_get_current_tabpage()
    if views.conv(p, tab) ~= vim.api.nvim_get_current_win() then
      return
    end
    if win_valid(views.prompt(p, tab)) then
      return
    end
    if (S._prompt_layout_building or 0) > 0 then
      return
    end
    ensure_prompt_win(p, tab)
  end

  local function setup_panel_autocmds(p)
    p.augroup = vim.api.nvim_create_augroup("YanaPanel" .. p.id, { clear = true })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = p.augroup,
      callback = function(ev)
        log.guard("yana.ui panel BufEnter", function()
          if ev.buf == p.conv_buf or ev.buf == p.prompt_buf then
            S.last_panel = p
          end
        end)
      end,
    })

    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      group = p.augroup,
      buffer = p.conv_buf,
      callback = function()
        S.last_focused_panel = p
        log.guard("yana.ui panel repair own prompt", repair_own_prompt, p)
      end,
    })
    vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      group = p.augroup,
      buffer = p.prompt_buf,
      callback = function()
        S.last_focused_panel = p
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      group = p.augroup,
      callback = function(ev)
        log.guard("yana.ui panel WinClosed", function()
          local w = tonumber(ev.match)
          if p.closing then
            return
          end
          local buttons = require("yana.ui_review_buttons")
          if buttons.tab_for_win(w) then
            pcall(buttons.on_win_closed, w)
            return
          end
          local view, vtab = views.find_win(p, w)
          if not view then
            return
          end
          -- Layout rebuilds may close a prompt window to re-split the column;
          -- that must not tear down the conversation (layout rebuild closing a prompt).
          if (S._prompt_layout_building or 0) > 0 then
            if w == view.prompt then
              views.set(p, vtab, { prompt = views.NONE })
            elseif w == view.conv then
              views.set(p, vtab, { conv = views.NONE })
            end
            return
          end
          if view.closing then
            return
          end
          views.set(p, vtab, { closing = true })
          vim.schedule(function()
            log.guard("yana.ui panel WinClosed cleanup", function()
              pcall(require("yana.ui_review_buttons").detach_windows, vtab, p)
              local cur = views.get(p, vtab)
              if cur then
                if win_valid(cur.prompt) then
                  pcall(vim.api.nvim_win_close, cur.prompt, true)
                end
                if win_valid(cur.conv) then
                  pcall(vim.api.nvim_win_close, cur.conv, true)
                end
              end
              views.clear(p, vtab)
            end)
          end)
        end)
      end,
    })

    vim.api.nvim_create_autocmd("TabClosed", {
      group = p.augroup,
      callback = function()
        log.guard("yana.ui panel TabClosed", function()
          views.prune(p)
        end)
      end,
    })
  end

  return {
    setup_panel_autocmds = setup_panel_autocmds,
  }
end

return M
