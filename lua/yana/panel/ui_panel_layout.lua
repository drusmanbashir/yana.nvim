-- Panel windows: each chat owns its conversation window and prompt window.
-- Layout policy (ui_panel_layout_policy) decides which existing views are
-- visible; this module creates and destroys only view windows.
local config = require("yana.config")
local views = require("yana.panel.ui_panel_views")
local policy = require("yana.panel.ui_panel_layout_policy")

local M = {}

function M.new(deps)
  local depth = deps.depth
  local focus = deps.focus
  local maybe_drain_queue = deps.maybe_drain_queue
  local panels = deps.panels
  local panel_for_buf = deps.panel_for_buf
  local prompt_winbar_text = deps.prompt_winbar_text
  local update_winbar = deps.update_winbar
  local focus_prompt_dep = deps.focus_prompt

  local function win_valid(w)
    return type(w) == "number" and w > 0 and vim.api.nvim_win_is_valid(w)
  end

  local function cur_tab()
    return vim.api.nvim_get_current_tabpage()
  end

  local function column_identity(conv_win)
    if not win_valid(conv_win) then
      return nil
    end
    local wi = vim.fn.getwininfo(conv_win)[1]
    if not wi then
      return nil
    end
    return {
      tab = vim.api.nvim_win_get_tabpage(conv_win),
      wincol = wi.wincol,
      width = wi.width,
    }
  end

  local function views_in_tab(tab)
    local out = {}
    for _, q in ipairs(panels) do
      local v = views.get(q, tab)
      if v and win_valid(v.conv) then
        out[#out + 1] = { panel = q, tab = tab, conv = v.conv, prompt = v.prompt }
      end
    end
    return out
  end

  local function panels_in_column(p, tab)
    tab = tab or cur_tab()
    local v = p and views.get(p, tab)
    local id = v and column_identity(v.conv)
    if not id then
      if v then
        return { { panel = p, tab = tab, conv = v.conv, prompt = v.prompt } }
      end
      return {}
    end
    local out = {}
    for _, e in ipairs(views_in_tab(tab)) do
      local qid = column_identity(e.conv)
      if qid and qid.tab == id.tab and qid.wincol == id.wincol and qid.width == id.width then
        out[#out + 1] = e
      end
    end
    table.sort(out, function(a, b)
      local wa = vim.fn.getwininfo(a.conv)[1]
      local wb = vim.fn.getwininfo(b.conv)[1]
      return (wa and wa.winrow or 0) < (wb and wb.winrow or 0)
    end)
    return out
  end

  local function compute_width()
    local w = config.options.ui.width
    if w <= 1 then
      return math.max(30, math.floor(vim.o.columns * w))
    end
    return math.floor(w)
  end

  local function set_panel_buf_opts(buf, ft, is_prompt)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = ft
    vim.b[buf].yana_panel = true
    if is_prompt then
      vim.b[buf].yana_prompt = true
    end
  end

  local function win_opts(win, is_prompt)
    local o = config.options
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = o.ui.wrap
    vim.wo[win].linebreak = o.ui.wrap
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].winfixwidth = true
    if is_prompt then
      vim.wo[win].winbar = prompt_winbar_text(panel_for_buf(vim.api.nvim_win_get_buf(win)), win)
    end
  end

  local active_winhl = "WinSeparator:YanaActivePanel,WinBar:YanaActivePanel"

  local function set_active_winhl(win, active)
    if not win_valid(win) then
      return
    end
    local keep = {}
    for item in (vim.wo[win].winhl or ""):gmatch("[^,]+") do
      if item ~= "WinSeparator:YanaActivePanel" and item ~= "WinBar:YanaActivePanel"
        and item ~= "Normal:YanaActivePanel" then
        keep[#keep + 1] = item
      end
    end
    if active then
      keep[#keep + 1] = active_winhl
    end
    vim.wo[win].winhl = table.concat(keep, ",")
  end

  local function mark_prompt_owner(p, tab)
    for _, e in ipairs(views_in_tab(tab)) do
      local active = e.panel == p
      set_active_winhl(e.conv, active)
      set_active_winhl(e.prompt, active)
    end
  end

  local function set_tab_prompt_lock(tab, locked)
    if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then
      return
    end
    for _, e in ipairs(views_in_tab(tab)) do
      if win_valid(e.prompt) then
        if locked then
          pcall(vim.api.nvim_win_set_height, e.prompt, config.options.ui.prompt_height)
        end
        vim.wo[e.prompt].winfixheight = locked
      end
    end
  end

  local layout_group = vim.api.nvim_create_augroup("YanaPanelLayout", { clear = true })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = layout_group,
    callback = function()
      set_tab_prompt_lock(cur_tab(), true)
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = layout_group,
    callback = function()
      local tab = cur_tab()
      vim.schedule(function()
        if vim.api.nvim_tabpage_is_valid(tab) and cur_tab() == tab then
          set_tab_prompt_lock(tab, false)
        end
      end)
    end,
  })

  local function prompt_height(entry)
    return entry and win_valid(entry.prompt) and vim.api.nvim_win_get_height(entry.prompt) or 0
  end

  local function split_in(host, cmd)
    if not win_valid(host) then
      return nil
    end
    local created = nil
    pcall(vim.api.nvim_win_call, host, function()
      if pcall(vim.cmd, cmd) then
        created = vim.api.nvim_get_current_win()
      end
    end)
    return win_valid(created) and created or nil
  end

  local prompt_api = require("yana.panel.ui_panel_layout_prompt").new({
    depth = depth,
    win_valid = win_valid,
    cur_tab = cur_tab,
    views_in_tab = views_in_tab,
    split_in = split_in,
    win_opts = win_opts,
    update_winbar = update_winbar,
    mark_prompt_owner = mark_prompt_owner,
  })
  local make_room_for_prompt = prompt_api.make_room_for_prompt
  local ensure_prompt_win = prompt_api.ensure_prompt_win

  -- Close one panel's windows in `tab` without touching siblings or buffers.
  local function hide_panel_windows(p, tab)
    tab = tab or cur_tab()
    pcall(require("yana.panel.ui_review_buttons").detach_windows, tab, p)
    local prompt_win = views.prompt(p, tab)
    local conv_win = views.conv(p, tab)
    if win_valid(prompt_win) then
      pcall(vim.api.nvim_win_close, prompt_win, true)
    end
    if win_valid(conv_win) then
      pcall(vim.api.nvim_win_close, conv_win, true)
    end
    views.clear(p, tab)
  end

  local function hide_others(p, tab)
    for _, e in ipairs(views_in_tab(tab)) do
      if e.panel ~= p then
        hide_panel_windows(e.panel, tab)
      end
    end
  end

  local function relayout(tab)
    tab = tab or cur_tab()
    local open = views_in_tab(tab)
    if #open == 0 then
      return
    end
    local buttons = require("yana.panel.ui_review_buttons")
    local o = config.options
    -- One sidebar column: divide vertical space across stacked chat pairs.
    local cols = {}
    for _, e in ipairs(open) do
      local id = column_identity(e.conv)
      local key = id and (tostring(id.wincol) .. ":" .. tostring(id.width)) or ("solo:" .. tostring(e.panel.id))
      cols[key] = cols[key] or {}
      cols[key][#cols[key] + 1] = e
    end
    for _, group in pairs(cols) do
      local total = 0
      for _, e in ipairs(group) do
        total = total + vim.api.nvim_win_get_height(e.conv) + prompt_height(e) + buttons.height_of(e.panel, tab)
      end
      for _, e in ipairs(group) do
        local btn_h = buttons.height_of(e.panel, tab)
        local ph = o.ui.prompt_height
        local conv_h = math.max(3, math.floor(total / #group) - ph - btn_h - 1)
        if win_valid(e.prompt) then
          pcall(vim.api.nvim_win_set_height, e.prompt, ph)
        end
        buttons.apply_relayout(e.panel, tab, conv_h, prompt_height(e))
      end
    end
  end

  local function code_win_in_tab(tab)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(w).relative == "" then
        local buf = vim.api.nvim_win_get_buf(w)
        if not vim.b[buf].yana_panel then
          return w
        end
      end
    end
    return nil
  end

  local function attach_review_strip(p, tab)
    pcall(require("yana.panel.ui_review_buttons").attach, p, tab)
  end

  local function open_windows(p, tab)
    tab = tab or cur_tab()
    local conv = views.conv(p, tab)
    local prompt = views.prompt(p, tab)
    if win_valid(conv) and win_valid(prompt) then
      return
    end
    depth:enter()
    local ok, err = xpcall(function()
      if policy.is_rotate() then
        hide_others(p, tab)
      end

      if win_valid(conv) and not win_valid(prompt) then
        ensure_prompt_win(p, tab)
        relayout(tab)
        attach_review_strip(p, tab)
        maybe_drain_queue(p)
        return
      end

      local o = config.options
      local anchor = nil
      for _, e in ipairs(views_in_tab(tab)) do
        if e.panel ~= p then
          anchor = e
        end
      end

      local stacked = false
      local created_conv = nil
      local prev_ea = nil
      local side_w = nil
      if anchor and policy.is_split() then
        prev_ea = vim.o.equalalways
        vim.o.equalalways = false
        local code_win = code_win_in_tab(tab)
        local code_w = win_valid(code_win) and vim.api.nvim_win_get_width(code_win) or nil
        do
          local wi = vim.fn.getwininfo(anchor.conv)[1]
          if wi then
            side_w = wi.width
          end
        end
        -- Prefer splitting a tall conversation: close only the host chat's
        -- prompt (buffer kept), stack the new conversation below it at full
        -- sidebar width, then restore that host prompt.
        local host_panel = anchor.panel
        local host = anchor.conv
        local best_bottom = -1
        for _, e in ipairs(views_in_tab(tab)) do
          if e.panel ~= p and win_valid(e.conv) then
            local wi = vim.fn.getwininfo(e.conv)[1]
            if wi then
              local bottom = wi.winrow + wi.height
              if win_valid(e.prompt) then
                local pw = vim.fn.getwininfo(e.prompt)[1]
                if pw then
                  bottom = math.max(bottom, pw.winrow + pw.height)
                end
              end
              if bottom > best_bottom then
                best_bottom = bottom
                host = e.conv
                host_panel = e.panel
              end
            end
          end
        end
        pcall(require("yana.panel.ui_review_buttons").detach_windows, tab, host_panel)
        local host_prompt = views.prompt(host_panel, tab)
        if win_valid(host_prompt) then
          pcall(vim.api.nvim_win_close, host_prompt, true)
          views.set(host_panel, tab, { prompt = views.NONE })
        end
        created_conv = split_in(host, "belowright split")
        stacked = created_conv ~= nil
        if stacked then
          ensure_prompt_win(host_panel, tab)
          if side_w then
            for _, e in ipairs(views_in_tab(tab)) do
              if win_valid(e.conv) then
                pcall(vim.api.nvim_win_set_width, e.conv, side_w)
              end
              if win_valid(e.prompt) then
                pcall(vim.api.nvim_win_set_width, e.prompt, side_w)
              end
            end
            if win_valid(created_conv) then
              pcall(vim.api.nvim_win_set_width, created_conv, side_w)
            end
          end
          if code_w and win_valid(code_win) then
            pcall(vim.api.nvim_win_set_width, code_win, code_w)
          end
        else
          vim.o.equalalways = prev_ea
          prev_ea = nil
          ensure_prompt_win(host_panel, tab)
        end
      end
      if not stacked then
        local host = vim.api.nvim_tabpage_get_win(tab)
        created_conv = split_in(host, o.ui.position == "left" and "topleft vsplit" or "botright vsplit")
      end
      if not created_conv then
        if prev_ea ~= nil then
          vim.o.equalalways = prev_ea
        end
        return
      end
      vim.api.nvim_win_set_buf(created_conv, p.conv_buf)
      if not stacked then
        local want = require("yana.panel.ui_geometry").desired(tab) or compute_width()
        pcall(vim.api.nvim_win_set_width, created_conv, want)
      elseif side_w then
        pcall(vim.api.nvim_win_set_width, created_conv, side_w)
      end
      views.set(p, tab, { conv = created_conv })

      make_room_for_prompt(tab, created_conv, o.ui.prompt_height)
      local prev_min = vim.o.winminheight
      vim.o.winminheight = 1
      local created_prompt = split_in(created_conv, "belowright split")
      vim.o.winminheight = prev_min
      if created_prompt then
        vim.api.nvim_win_set_buf(created_prompt, p.prompt_buf)
        pcall(vim.api.nvim_win_set_height, created_prompt, o.ui.prompt_height)
        views.set(p, tab, { prompt = created_prompt })
      end

      win_opts(created_conv, false)
      if created_prompt then
        win_opts(created_prompt, true)
      end
      mark_prompt_owner(p, tab)
      for _, q in ipairs(panels) do
        update_winbar(q)
      end
      relayout(tab)
      if prev_ea ~= nil then
        local survivors = {}
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          survivors[#survivors + 1] = { win = w, height = vim.api.nvim_win_get_height(w) }
        end
        vim.o.equalalways = prev_ea
        for _, s in ipairs(survivors) do
          if win_valid(s.win) and vim.api.nvim_win_get_height(s.win) ~= s.height then
            pcall(vim.api.nvim_win_set_height, s.win, s.height)
          end
        end
      end

      if tab ~= cur_tab() then
        set_tab_prompt_lock(tab, true)
      end

      local geometry = require("yana.panel.ui_geometry")
      geometry.setup()
      geometry.observe(tab)

      attach_review_strip(p, tab)
      maybe_drain_queue(p)
    end, debug.traceback)
    depth:leave()
    if not ok then
      error(err)
    end
  end


  local nav
  nav = require("yana.panel.ui_panel_layout_nav").new({
    focus = focus,
    panels = panels,
    win_valid = win_valid,
    open_windows = function(p, tab)
      return open_windows(p, tab)
    end,
    ensure_prompt_win = ensure_prompt_win,
    hide_others = hide_others,
    mark_prompt_owner = mark_prompt_owner,
    focus_prompt = focus_prompt_dep,
    cur_tab = cur_tab,
  })

  return {
    compute_width = compute_width,
    set_panel_buf_opts = set_panel_buf_opts,
    win_opts = win_opts,
    relayout = relayout,
    open_windows = open_windows,
    ensure_prompt_win = ensure_prompt_win,
    panels_in_column = panels_in_column,
    next_panel = nav.next_panel,
    prev_panel = nav.prev_panel,
    focus_panel = nav.focus_panel,
    hide_panel_windows = hide_panel_windows,
    show_next_after_close = nav.show_next_after_close,
  }
end

return M
