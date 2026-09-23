-- Live-daemon session attachment (+ telescope picker), split out of yana.ui.
-- Disk records are caches, never session authority. Every row comes from a
-- successful yanad status request and every attachment uses session.attach.
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

local PENDING_TURN_STATES = {
  settling = true,
  reviewing = true,
  dead_unsealed = true,
}

local function clean_path(path)
  return vim.fn.fnamemodify(tostring(path or ""), ":p"):gsub("/+$", "")
end

local function pending_state(row)
  if row.review then
    return "reviewing"
  end
  for _, turn in ipairs(row.turns or {}) do
    if PENDING_TURN_STATES[turn.state] then
      return turn.state
    end
  end
  return nil
end

local function pending_for_workspace(row, workspace)
  if type(row) ~= "table" or clean_path(row.workspace) ~= workspace then
    return false
  end
  if row.kind == "nvim" and row.liveness == "live" then
    return false
  end
  return pending_state(row) ~= nil
end

local function age_text(since, elapsed)
  local seconds = type(since) == "number" and math.max(0, elapsed and since or (os.time() - since)) or nil
  if not seconds then
    return "age unknown"
  elseif seconds < 60 then
    return tostring(seconds) .. "s"
  elseif seconds < 3600 then
    return tostring(math.floor(seconds / 60)) .. "m"
  elseif seconds < 86400 then
    return tostring(math.floor(seconds / 3600)) .. "h"
  end
  return tostring(math.floor(seconds / 86400)) .. "d"
end

local function recovery_rows(status, workspace)
  local since_by_session = {}
  for _, claim in ipairs(status.claims or {}) do
    local sid = claim.session_id
    if sid and type(claim.since) == "number" then
      since_by_session[sid] = math.min(since_by_session[sid] or claim.since, claim.since)
    end
  end
  local rows = {}
  for _, row in ipairs(status.sessions or {}) do
    if pending_for_workspace(row, workspace) then
      row = vim.tbl_extend("force", {}, row)
      row._yana_state = pending_state(row)
      row._yana_age = type(row.review_age_seconds) == "number"
        and age_text(row.review_age_seconds, true)
        or age_text(since_by_session[row.session_id])
      rows[#rows + 1] = row
    end
  end
  return rows
end

local function recovery_label(row)
  if row._yana_action then
    return row.label
  end
  local files = (#(row.files or {}) > 0) and table.concat(row.files, ", ") or "(no files)"
  return string.format("%s | %s | %s | %s", row._yana_state, row.kind or "unknown", files, row._yana_age)
end

-- deps.current_panel: parent's `current_panel()` — cursor/MRU panel.
-- deps.panel_open / deps.panel_open_in / deps.open_windows: panel lifecycle.
-- deps.open_new_panel: THE portal that builds a side pane (yana.ui_panel_lifecycle).
-- deps.focus_prompt: parent's `M.focus_prompt(p)`.
function M.new(deps)
  local current_panel = deps.current_panel
  local panel_open = deps.panel_open
  local panel_open_in = deps.panel_open_in
  local open_windows = deps.open_windows
  local open_new_panel = deps.open_new_panel
  local focus_prompt = deps.focus_prompt

  -- Deleted, not retargeted: the only surviving resume is the live-daemon-gated
  -- recovery family below (check_recovery / recover / :YanaRecover), which already asks
  -- yanad.status before naming anything.

  local recovery_request_seq = 0
  local checked_workspaces = {}
  local recovery_in_flight = {}
  local recovery_picker_open = false

  local function panel_is_current(target, target_id, workspace)
    local now = current_panel()
    if now ~= target then
      return false
    end
    if target and target.id ~= target_id then
      return false
    end
    local get_workspace = deps.workspace or vim.fn.getcwd
    return clean_path(get_workspace()) == workspace
  end

  -- One async daemon query is armed when yana.ui first loads. Explicit session
  -- commands set `force=true` so every invocation asks the live daemon again.
  local function check_recovery(opts)
    opts = opts or {}
    local get_workspace = deps.workspace or vim.fn.getcwd
    local workspace = clean_path(opts.workspace or get_workspace())
    if recovery_in_flight[workspace] or recovery_picker_open then
      return false
    end
    if checked_workspaces[workspace] and not opts.force then
      return false
    end
    checked_workspaces[workspace] = true
    recovery_in_flight[workspace] = true

    local target = current_panel()
    local target_id = target and target.id or nil
    recovery_request_seq = recovery_request_seq + 1
    local request_id = string.format("recovery:status:%d:%d", vim.fn.getpid(), recovery_request_seq)

    require("yana.runtime.yanad").status({}, request_id, function(ok, status)
      recovery_in_flight[workspace] = nil
      if not panel_is_current(target, target_id, workspace) then
        return
      end
      if not ok or type(status) ~= "table" then
        if opts.notify_empty then
          notify_one_line(
            "yana: no live yana daemon owns a session here — start a new session",
            vim.log.levels.INFO
          )
        end
        return
      end
      require("yana.runtime.yanad_recover").note_discovery_prunes(status.pruned)
      local rows = recovery_rows(status, workspace)
      if #rows == 0 then
        if opts.notify_empty then
          notify_one_line(
            "yana: no live yana daemon owns an attachable session here — start a new session",
            vim.log.levels.INFO
          )
        end
        return
      end

      -- Delete emptying the list closes without starting a chat. <Del> not x: leap map
      -- xs steals bare x. Telescope when available; injected deps.select for headless;
      -- else vim.ui.select + New session row.
      local tip = "Enter recover · Del delete · n new"
      local live_rows = rows

      local function start_new()
        if deps.start_new_session then
          deps.start_new_session(target)
        elseif target then
          focus_prompt(target)
        else
          open_new_panel()
        end
      end

      local function recover_choice(choice)
        if deps.recover_session then
          local recovery_target = target
          local tab = vim.api.nvim_get_current_tabpage()
          if opts.new_panel or not recovery_target or recovery_target.busy then
            recovery_target = open_new_panel({ recovering = true, focus = false })
          elseif not panel_open_in(recovery_target, tab) then
            open_windows(recovery_target, tab)
          end
          deps.recover_session(choice, recovery_target)
          return
        end
        if vim.fn.exists(":YanaRecover") == 2 then
          vim.cmd("YanaRecover " .. vim.fn.fnameescape(choice.session_id))
          return
        end
        notify_one_line("yana: session recovery is not built", vim.log.levels.ERROR)
      end

      local function handle_choice(choice, action)
        recovery_picker_open = false
        if not panel_is_current(target, target_id, workspace) then
          return
        end
        if action == "new" then
          start_new()
          return
        end
        if not choice then
          return
        end
        recover_choice(choice)
      end

      local function delete_session(choice, after)
        if not choice or type(choice.session_id) ~= "string" or choice.session_id == "" then
          if after then
            after(false)
          end
          return
        end
        recovery_request_seq = recovery_request_seq + 1
        local req = string.format("recovery:delete:%d:%d", vim.fn.getpid(), recovery_request_seq)
        require("yana.runtime.yanad").session_delete({ session_id = choice.session_id }, req, function(ok, res)
          if not panel_is_current(target, target_id, workspace) then
            recovery_picker_open = false
            if after then
              after(false)
            end
            return
          end
          if not ok then
            notify_one_line(
              "yana: delete session failed: " .. tostring(res),
              vim.log.levels.ERROR
            )
            if after then
              after(false)
            end
            return
          end
          notify_one_line(
            "yana: deleted session " .. tostring(choice.session_id):sub(1, 8),
            vim.log.levels.INFO
          )
          local kept = {}
          for _, row in ipairs(live_rows) do
            if row.session_id ~= choice.session_id then
              kept[#kept + 1] = row
            end
          end
          live_rows = kept
          if after then
            after(true, live_rows)
          end
        end)
      end

      recovery_picker_open = true

      if deps.select then
        deps.select(live_rows, {
          prompt = "yana: recover an unattached session  [" .. tip .. "]",
          format_item = recovery_label,
        }, function(choice, action)
          if action == "delete" then
            delete_session(choice, function(ok, remaining)
              if not ok then
                return
              end
              if not remaining or #remaining == 0 then
                recovery_picker_open = false
                notify_one_line("yana: no unattached sessions left", vim.log.levels.INFO)
                return
              end
              -- Headless injectors that need a refresh call select again.
              if deps.select_refresh then
                deps.select_refresh(remaining)
              end
            end)
            return
          end
          handle_choice(choice, action)
        end)
        return
      end

      local ok_tel, pickers = pcall(require, "telescope.pickers")
      if ok_tel then
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        local themes = require("telescope.themes")

        local function make_finder(session_rows)
          return finders.new_table({
            results = session_rows,
            entry_maker = function(s)
              local label = recovery_label(s)
              return {
                value = s,
                display = label,
                ordinal = label .. " " .. tostring(s.session_id or ""),
              }
            end,
          })
        end

        -- <Del> not x: global leap map `xs` makes bare x wait on timeoutlen (live
        -- fail).
        local nowait = { nowait = true }
        pickers
          .new(themes.get_dropdown({
            prompt_title = "yana recover  [" .. tip .. "]",
            results_title = false,
            previewer = false,
            initial_mode = "normal",
            finder = make_finder(live_rows),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr, map)
              local function close_picker()
                recovery_picker_open = false
                actions.close(prompt_bufnr)
              end

              local function delete_selected()
                local entry = action_state.get_selected_entry()
                if not entry or not entry.value then
                  notify_one_line("yana: no session selected", vim.log.levels.WARN)
                  return
                end
                delete_session(entry.value, function(ok, remaining)
                  if not ok then
                    return
                  end
                  if not remaining or #remaining == 0 then
                    close_picker()
                    notify_one_line("yana: no unattached sessions left", vim.log.levels.INFO)
                    return
                  end
                  local picker = action_state.get_current_picker(prompt_bufnr)
                  picker:refresh(make_finder(remaining), { reset_prompt = false })
                end)
              end

              actions.select_default:replace(function()
                local entry = action_state.get_selected_entry()
                close_picker()
                if entry and entry.value then
                  -- Flag already cleared; recover without toggling again.
                  if not panel_is_current(target, target_id, workspace) then
                    return
                  end
                  recover_choice(entry.value)
                end
              end)

              map("n", "<Del>", delete_selected, nowait)
              map("n", "<Delete>", delete_selected, nowait)

              map("n", "n", function()
                close_picker()
                if panel_is_current(target, target_id, workspace) then
                  start_new()
                end
              end, nowait)

              map({ "i", "n" }, "<Esc>", close_picker)

              return true
            end,
          }))
          :find()
        return
      end

      if #vim.api.nvim_list_uis() == 0 or type(vim.ui.select) ~= "function" then
        recovery_picker_open = false
        return
      end
      local fallback = {}
      for _, row in ipairs(live_rows) do
        fallback[#fallback + 1] = row
      end
      fallback[#fallback + 1] = { _yana_action = "new", label = "New session" }
      vim.ui.select(fallback, {
        prompt = "yana: recover an unattached session (install telescope for Del/n keys)",
        format_item = recovery_label,
      }, function(choice)
        if not choice then
          recovery_picker_open = false
          return
        end
        if choice._yana_action == "new" then
          handle_choice(nil, "new")
          return
        end
        handle_choice(choice, nil)
      end)
    end)
    return true
  end

  local function list_live(opts)
    opts = vim.tbl_extend("force", {}, opts or {}, {
      force = true,
      notify_empty = true,
    })
    return check_recovery(opts)
  end

  local function recover(session_id)
    if not session_id or session_id == "" then
      return list_live()
    end
    local target = current_panel()
    local tab = vim.api.nvim_get_current_tabpage()
    if not target or target.busy then
      target = open_new_panel({ recovering = true, focus = false })
    elseif not panel_open_in(target, tab) then
      open_windows(target, tab)
    end
    if not deps.recover_session then
      notify_one_line("yana: session recovery is not built", vim.log.levels.ERROR)
      return false
    end
    deps.recover_session({ session_id = session_id }, target)
    return true
  end

  if not deps.disable_auto_recovery then
    vim.schedule(function()
      check_recovery()
    end)
  end

  return {
    list_live = list_live,
    check_recovery = check_recovery,
    recover = recover,
  }
end

return M
