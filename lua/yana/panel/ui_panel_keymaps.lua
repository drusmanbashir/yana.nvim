-- Panel buffer keymaps. Split from yana.ui_panel (cluster 8 keymap seam).
local config = require("yana.config")
local log = require("yana.log")

local M = {}

-- deps.state: parent shared state `S` (submit_panel, cancel_inflight, render_note).
-- deps.M: parent module table (steer, new_chat, toggle_mode, resend, pick_*).
-- deps.paste_into_panel: yana.ui_input facade local.
-- deps.close_panel / deps.open_new_panel / deps.focus_prompt: yana.ui_panel
-- lifecycle locals (late-bound through the factory).
-- deps.next_panel / deps.prev_panel: yana.ui_panel_layout focus/rotate.
function M.new(deps)
  local S = deps.state
  local ui_M = deps.M
  local paste_into_panel = deps.paste_into_panel
  local close_panel = deps.close_panel
  local open_new_panel = deps.open_new_panel
  local focus_prompt = deps.focus_prompt
  local next_panel = deps.next_panel
  local prev_panel = deps.prev_panel

  local function apply_panel_keymaps(p)
    local k = config.options.mappings
    local function map(buf, modes, lhs, rhs, desc)
      if not lhs or lhs == "" then
        return
      end
      -- Every panel keymap funnels through here, so wrapping the function-typed
      -- rhs in log.guard covers all of them at one choke point: on error the
      -- traceback is logged before it surfaces exactly as before.
      if type(rhs) == "function" then
        local fn = rhs
        rhs = function(...)
          log.guard("panel keymap " .. lhs, fn, ...)
        end
      end
      vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
    end

    -- which-key group for the resend prefix, buffer-local so it only shows in the
    -- panel. Optional dependency: absent which-key must not break keymaps.
    local function register_resend_which_key(buf)
      if not k.resend or k.resend == "" then
        return
      end
      local ok, wk = pcall(require, "which-key")
      if not ok then
        return
      end
      pcall(wk.add, {
        buffer = buf,
        { k.resend, group = "resend last prompt", icon = "󰑖", mode = { "n", "i" } },
        { k.resend .. "r", desc = "here — same chat, same session", mode = { "n", "i" } },
        { k.resend .. "n", desc = "new chat — fresh session, same mode", mode = { "n", "i" } },
        { k.resend .. "a", desc = "new agent chat — fresh session, agent mode", mode = { "n", "i" } },
      })
    end

    -- Prompt buffer: submit & control.
    map(p.prompt_buf, { "n", "i" }, k.submit, function()
      S.submit_panel(p)
    end, "yana: submit")
    local function stop_inflight()
      if S.cancel_inflight(p) then
        S.render_note(p, "⏹ stopped")
      end
    end
    map(p.prompt_buf, { "n", "i" }, k.stop, stop_inflight, "yana: stop")
    map(p.prompt_buf, { "n", "i" }, k.steer, function()
      ui_M.steer()
    end, "yana: interrupt and steer")
    map(p.prompt_buf, { "n", "i" }, k.next_panel, function()
      next_panel(p)
    end, "yana: next panel")
    map(p.prompt_buf, { "n", "i" }, k.prev_panel, function()
      prev_panel(p)
    end, "yana: previous panel")

    -- Manual completion-menu open: prompt buffer, insert mode only, works on an empty
    -- line with no trigger character (blink's `/` and `@` sources otherwise only fire
    -- on those trigger characters). Bare cmp.show() with no providers override —
    -- blink.lua's sources.default already scopes to { "yana_commands", "yana_mentions"
    -- } for any buffer flagged b:yana_prompt, so this reaches the same two sources
    -- without duplicating that scoping decision here.
    --
    -- Default key is <C-Space> (config.lua), same chord blink.cmp itself binds and
    -- re-applies buffer-locally on every InsertEnter.
    map(p.prompt_buf, "i", k.completion_menu, function()
      local ok, blink = pcall(require, "blink.cmp")
      if ok then
        blink.show()
      end
    end, "yana: open completion menu")

    local ip = config.options.image_paste
    if ip and ip.enable then
      -- normalize_image_paste always yields a list. <C-v>/<C-V> collapse to one
      -- keycode, so binding both is idempotent, not a conflict.
      for _, key in ipairs(ip.key) do
        map(p.prompt_buf, "i", key, function()
          paste_into_panel(p, {})
        end, "yana: paste image/text from clipboard")
      end
    end

    for _, buf in ipairs({ p.prompt_buf, p.conv_buf }) do
      vim.keymap.set("n", "<Tab>", "<Nop>", { buffer = buf, silent = true, desc = "yana: ignore harpoon tab" })
      if buf == p.conv_buf then
        map(buf, "n", k.stop, stop_inflight, "yana: stop")
      end
      local modes = (buf == p.prompt_buf) and { "n", "i" } or "n"
      map(buf, modes, k.new_chat, function()
        ui_M.new_chat()
      end, "yana: new chat")
      map(buf, modes, k.toggle_mode, function()
        ui_M.toggle_mode()
      end, "yana: toggle mode")
      -- Resend is a PREFIX, not a single key: the useful question after "resend"
      -- is always "where", and a chat's mode is locked once it has run a turn, so
      -- "in agent mode" necessarily means "in a new chat". which-key renders the
      -- three leaves; register_resend_which_key below labels them.
      if k.resend and k.resend ~= "" then
        register_resend_which_key(buf)
        map(buf, modes, k.resend .. "r", function()
          ui_M.resend({ where = "here" })
        end, "resend here (same session)")
        map(buf, modes, k.resend .. "n", function()
          ui_M.resend({ where = "new" })
        end, "resend in a new chat")
        map(buf, modes, k.resend .. "a", function()
          ui_M.resend({ where = "agent" })
        end, "resend in a new agent chat")
      end
      map(buf, modes, k.model, function()
        ui_M.pick_vendor_then_model()
      end, "yana: pick the agent CLI, then its model")
      map(buf, modes, k.new_panel, function()
        open_new_panel()
      end, "yana: new panel")
      map(buf, modes, k.queue, function()
        ui_M.pick_queue()
      end, "yana: queued prompts")
      map(buf, "n", k.review, function()
        ui_M.review_changes()
      end, "yana: review changes")
      map(buf, "n", k.reject, function()
        ui_M.reject_changes()
      end, "yana: reject change")
      map(buf, "n", k.close, function()
        close_panel(p)
      end, "yana: close panel")
    end

    map(p.conv_buf, "n", k.focus_prompt, function()
      focus_prompt(p)
    end, "yana: focus prompt")
  end

  return {
    apply_panel_keymaps = apply_panel_keymaps,
  }
end

return M
