-- LAYER 1 (backend/vendor: which account is billed) and LAYER 2 (model within the active backend) pickers,
-- plus the cascade of the two. The layer distinction is load-bearing; keep it.
local config = require("yana.config")
local agent = require("yana.agent.agent")
local log = require("yana.log")
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

-- deps.panels: parent's panel list (iterated, never reassigned); deps.current_panel: cursor/MRU panel;
-- deps.update_winbar: repaint one panel's chip.
function M.new(deps)
  local panels = deps.panels
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar

  -- LAYER 2: pick a model WITHIN the active backend; a distinct key/command from pick_backend (LAYER 1).
  local function ensure_auto_row(models)
    for _, m in ipairs(models) do
      if m.id == "auto" then
        return models
      end
    end
    local out = { { id = "auto", label = "let the backend choose" } }
    vim.list_extend(out, models)
    return out
  end

  local function apply_model_selection(backend, choice, p)
    -- config.options.model is the sole authority; hierarchy modes ride beside it as session-scoped tokens.
    local from_model = config.options.model or "auto"
    local resolved = choice.model
    if resolved == "auto" then
      resolved = nil
    end
    local prev_actual_model = config.options.model
    local model_changed = resolved ~= prev_actual_model
      or not vim.deep_equal(config.options.model_modes, choice.modes)
    config.options.model = resolved
    config.options.model_modes = choice.modes and vim.deepcopy(choice.modes) or nil
    pcall(function()
      require("yana.runtime.persisted_state").save_model_selection(config.options)
    end)
    if model_changed then
      for _, q in ipairs(panels) do
        q.model_actual = nil
      end
    end
    for _, q in ipairs(panels) do
      update_winbar(q)
    end
    log.lifecycle("model.switch", {
      panel = p and p.id or nil,
      backend = backend,
      from = from_model,
      to = resolved,
      modes = choice.modes,
      session = p and p.session_id or nil,
    })
    local label = resolved or "auto"
    if choice.modes then
      local bits = {}
      for k, v in pairs(choice.modes) do
        bits[#bits + 1] = k .. "=" .. v
      end
      table.sort(bits)
      if #bits > 0 then
        label = label .. " (" .. table.concat(bits, ",") .. ")"
      end
    end
    notify_one_line("yana: model (layer 2, backend " .. backend .. ") → " .. label, vim.log.levels.INFO)
  end

  local function present_hierarchy(models, source_note, open_opts)
    local p = current_panel()
    local backend = config.options.backend or "cursor"
    models = ensure_auto_row(models)
    local hierarchy = require("yana.agent.model_hierarchy")
    local table_ui = require("yana.panel.ui_model_hierarchy")
    local rows = hierarchy.build(backend, models)
    local refreshing = agent.model_list_refreshing and agent.model_list_refreshing(backend)
    open_opts = open_opts or {}
    table_ui.open({
      backend = backend,
      rows = rows,
      columns = hierarchy.columns(backend),
      refreshing = refreshing and true or false,
      source_note = source_note,
      current_model = config.options.model,
      current_modes = config.options.model_modes,
      on_apply = function(choice)
        apply_model_selection(backend, choice, p)
      end,
      on_back = open_opts.on_back,
    })
  end

  local function pick_model(open_opts)
    local backend = config.options.backend or "cursor"
    local bd = config.backend_descriptor(backend) or {}

    if bd.list_models_args then
      -- Warm cache: open the hierarchy table immediately, no loading flash and no CLI spawn.
      local cached, cached_code = agent.cached_model_list(backend)
      if cached and cached_code == 0 and #cached > 0 then
        -- Stale-while-refresh: table stays usable on last-known-good.
        agent.list_models(function() end, { backend = backend })
        present_hierarchy(cached, "(cached)", open_opts)
        return
      end
      notify_one_line("yana: loading models for backend " .. backend .. "…", vim.log.levels.INFO)
      agent.list_models(function(models, code, reason)
        if code == -2 then
          notify_one_line(
            "yana: model picker unavailable — backend " .. backend .. " " .. (reason or "does not support listing models")
              .. "; set config.options.model directly if you know the id",
            vim.log.levels.WARN
          )
          return
        end
        if code ~= 0 or #models == 0 then
          notify_one_line("yana: could not list models for backend " .. backend .. " (is it installed?)", vim.log.levels.ERROR)
          return
        end
        present_hierarchy(models, "(from " .. backend .. " " .. table.concat(bd.list_models_args, " ") .. ")", open_opts)
      end, { backend = backend })
      return
    end

    -- Static catalogue / cache path for vendors with no listing CLI (claude).
    do
      local cached, cached_code = agent.cached_model_list(backend)
      if cached and cached_code == 0 and #cached > 0 then
        present_hierarchy(cached, "(cached)", open_opts)
        return
      end
    end

    if bd.models and #bd.models > 0 then
      local models = {}
      for _, m in ipairs(bd.models) do
        table.insert(models, { id = m.id, label = m.label })
      end
      -- Seed the shared cache so a later pick_vendor_then_model hit is warm.
      agent.list_models(function() end, { backend = backend })
      present_hierarchy(models, "(declared list; " .. backend .. " has no model listing — may be stale)", open_opts)
      return
    end

    -- Honest degrade: no listing surface and no catalogue; say so, never show the PREVIOUS backend's list.
    notify_one_line(
      "yana: model picker unavailable — backend " .. backend .. " does not support listing models"
        .. "; set config.options.model directly if you know the id",
      vim.log.levels.WARN
    )
  end

  -- LAYER 1 apply: switch backend + reset model + drop vendor session ids; shared by pick_backend and the cascade.
  local function apply_backend_switch(choice)
    local from_backend = config.options.backend or config.defaults.backend
    if not choice or choice == from_backend then
      return false
    end
    local from_model = config.options.model
    config.options.backend = choice
    -- Reset to absence (auto): a foreign model id would reach a vendor that has never heard of it.
    config.options.model = nil
    -- Mode tokens are vendor-declared spellings; never carry them across a backend switch.
    config.options.model_modes = nil
    pcall(function()
      require("yana.runtime.persisted_state").save_model_selection(config.options)
    end)
    for _, q in ipairs(panels) do
      -- A `--resume` session id belongs to the backend that issued it: drop every panel's upstream session on a
      -- backend switch; the chat (transcript, title) continues as a fresh session.
      if q.session_id then
        q.session_id = nil
      end
      q.session_seats = {}
      -- A model id and its confirmation also belong to the issuing vendor.
      q.model_actual = nil
      update_winbar(q)
    end
    log.lifecycle("backend.switch", {
      panel = current_panel() and current_panel().id or nil,
      from = from_backend,
      to = choice,
      model_from = from_model,
      model_to = nil,
    })
    notify_one_line(
      "yana: backend (layer 1) → " .. choice .. " — model reset to auto; open chats continue as new sessions under " .. choice,
      vim.log.levels.INFO
    )
    return true
  end

  local function configured_backend_names()
    local backends_tbl = config.options.backends or {}
    local names = {}
    for name in pairs(backends_tbl) do
      names[#names + 1] = name
    end
    table.sort(names)
    return names
  end

  -- LAYER 1: pick the BACKEND (binary, account, bill). Session-scoped like pick_model: config.options.backend is
  -- the sole authority, sticky for the Neovim process, never written to the config file.
  local function pick_backend()
    local names = configured_backend_names()
    if #names <= 1 then
      notify_one_line(
        "yana: only one backend configured (" .. (names[1] or "none") .. ") — add one to config.backends to switch",
        vim.log.levels.INFO
      )
      return
    end
    local current = config.options.backend or config.defaults.backend
    vim.ui.select(names, {
      prompt = "yana: select backend (current: " .. current .. ")",
      format_item = function(name)
        return (name == current) and (name .. "  (current)") or name
      end,
    }, function(choice)
      apply_backend_switch(choice)
    end)
  end

  -- The one panel picker (the `model` key): LAYER 1 then LAYER 2, backend then model.
  -- M.pick_backend / M.pick_model stay as the :YanaBackend / :YanaModel commands.
  local function pick_vendor_then_model()
    local names = configured_backend_names()
    if #names <= 1 then
      pick_model()
      return
    end
    local function open_vendor()
      local current = config.options.backend or config.defaults.backend
      vim.ui.select(names, {
        prompt = "yana: select vendor, then model (current: " .. current .. ")",
        format_item = function(name)
          return (name == current) and (name .. "  (current)") or name
        end,
      }, function(choice)
        if not choice then
          return
        end
        apply_backend_switch(choice)
        pick_model({ on_back = open_vendor })
      end)
    end
    open_vendor()
  end

  return {
    pick_model = pick_model,
    pick_backend = pick_backend,
    pick_vendor_then_model = pick_vendor_then_model,
  }
end

return M
