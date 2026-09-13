-- LAYER 1 (backend/vendor) and LAYER 2 (model) pickers, split out of
-- yana.ui. `M.pick_backend` picks WHICH vendor account is billed (row 58);
-- `M.pick_model` picks WHICH model within the active backend;
-- `M.pick_vendor_then_model` is the operator-convenience cascade of the two.
-- The layer-1 (vendor) / layer-2 (model) distinction is load-bearing: these
-- functions must keep it.
local config = require("yana.config")
local agent = require("yana.agent")
local log = require("yana.log")
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

-- deps.panels: the parent's shared panel-registry list (same table
-- reference; iterated, never reassigned, so the parent and this module
-- always see the same panels).
-- deps.current_panel: parent's `current_panel()` — the cursor/MRU panel.
-- deps.update_winbar: parent's `update_winbar(p)` — repaint one panel's
-- winbar chip (model/mode/backend) after a switch.
function M.new(deps)
  local panels = deps.panels
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar

  -- LAYER 2: pick a model WITHIN the active backend via the hierarchy table
  -- (model_hierarchy columns). Distinct key/command from M.pick_backend (LAYER 1) on
  -- purpose -- row 58 is exactly a layer-2 choice being mistaken for a layer-1 one.
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

  -- LAYER 2 source precedence (work order VENDORS, V1-4), decided HERE in one place, in
  -- this order, so a caller reading this function sees the whole policy rather than
  -- piecing it together from agent.lua and config.lua: 1. bd.list_models_args present
  -- -> run it (agent.list_models), parsed per bd.list_models_format. 2.
  local function apply_model_selection(backend, choice, p)
    -- `config.options.model` is the sole authority; hierarchy modes ride beside it as
    -- session-scoped tokens.
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
      require("yana.persisted_state").save_model_selection(config.options)
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
    local hierarchy = require("yana.model_hierarchy")
    local table_ui = require("yana.ui_model_hierarchy")
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
      -- Warm cache (filled at setup prefetch, or a prior pick): open the
      -- hierarchy table immediately — no "loading…" flash and no CLI spawn.
      local cached, cached_code = agent.cached_model_list(backend)
      if cached and cached_code == 0 and #cached > 0 then
        -- Stale-while-refresh: kick TTL refresh via list_models; table stays
        -- usable on last-known-good and may show a non-blocking refresh mark.
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

    -- Honest degrade (row 58 requirement 4): this backend has neither a
    -- listing surface nor a declared catalogue -- say so, never silently
    -- show the PREVIOUS backend's list under the new backend's name.
    notify_one_line(
      "yana: model picker unavailable — backend " .. backend .. " does not support listing models"
        .. "; set config.options.model directly if you know the id",
      vim.log.levels.WARN
    )
  end

  -- LAYER 1 apply: switch backend + reset model + drop vendor session ids.
  -- Shared by M.pick_backend and the operator convenience cascade below so the
  -- two dials stay one source of truth for switch side effects.
  local function apply_backend_switch(choice)
    local from_backend = config.options.backend or config.defaults.backend
    if not choice or choice == from_backend then
      return false
    end
    local from_model = config.options.model
    config.options.backend = choice
    -- Carrying it across a backend switch would pass a foreign id as --model to a
    -- vendor that has never heard of it, and the failure would be a vendor error the
    -- operator has to decode: exactly the confusion row 58 exists to remove. Resets to
    -- absence ("auto"/vendor default), never resurrected from a per-backend memory --
    -- this build does not keep one (see the report: a reasonable nicety, deliberately
    -- skipped rather than risking resurrecting an id the new backend does not actually
    config.options.model = nil
    -- Mode tokens are vendor-declared spellings; never carry them across a
    -- backend switch (same reason layer 2 model ids reset).
    config.options.model_modes = nil
    pcall(function()
      require("yana.persisted_state").save_model_selection(config.options)
    end)
    for _, q in ipairs(panels) do
      -- Vendor-specific session rule (row 58's sharp edge): a `--resume`
      -- session id belongs to the backend that issued it. Handing it to a
      -- different backend is meaningless or actively wrong, so every open
      -- panel's upstream session is dropped on a backend switch -- the
      -- CHAT continues (transcript kept, title kept) but as a fresh
      -- upstream session under the new backend rather than a resumed one.
      if q.session_id then
        q.session_id = nil
      end
      q.session_seats = {}
      -- Same reasoning as the session drop above: a model id, and a
      -- confirmation of one, both belong to the vendor that issued them.
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

  -- LAYER 1: pick the BACKEND -- which binary, which account, which bill (row 58).
  --
  -- Session-scoped exactly like M.pick_model, same shape: config.options.
  -- backend is the sole authority, every open panel's winbar reflects a
  -- switch immediately, and it is sticky for the life of the Neovim process
  -- (a new chat or new panel does not reset it) but never touches the
  -- operator's config file and does not survive a restart.
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
