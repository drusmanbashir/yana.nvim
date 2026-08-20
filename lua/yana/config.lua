-- yana: configuration defaults and merge logic.
local M = {}

M.defaults = {
  -- WHERE cursor-agent IS RESOLVED FROM. Nothing below bakes in a username,
  -- an absolute path, or an env var this product invented for itself.
  -- Resolution is decided ONCE, by M.resolve_cmd() below, and every consumer
  -- (agent spawn, model list, health/dependency rows) asks it -- never reads
  -- config.options.cmd directly to spawn or probe. Precedence:
  --   1. This value, if you set it: setup({ cmd = "/path/to/cursor-agent" }).
  --   2. The environment variable NAMED by `cmd_env` below, read lazily at
  --      resolve time -- the same indirection avante.nvim uses for provider
  --      API keys (lua/avante/config.lua's `api_key_name` field; read by
  --      lua/avante/providers/init.lua's E.parse_envvar): you name the env
  --      var your shell already exports, yana reads it lazily, and no
  --      secret or machine-specific value is ever a default.
  --   3. `cursor-agent` resolved on PATH.
  -- `~` is expanded (vim.fn.expand) on whichever candidate wins.
  -- nil here (the default) means "not set in setup()", which is exactly what
  -- lets step 2 run at all -- setting a string always wins outright.
  cmd = nil,

  -- Name of the environment variable read for step 2 above. Point this at
  -- whatever your shell profile already exports -- e.g.
  -- cmd_env = "CURSOR_CLI_BIN" if that is the name you already use -- yana
  -- ships no opinion beyond this default name and reads it lazily (never
  -- baked into a default value). Set to false to skip step 2 and go
  -- straight from explicit `cmd` to the PATH fallback.
  cmd_env = "YANA_AGENT_BIN",

  -- Model to use. nil/"" => let cursor-agent pick (Auto). e.g. "claude-opus-5".
  model = nil,

  -- THE dial. One setting, three results, named for what you get
  -- rather than for the machinery underneath (the mode contract):
  --
  --   "ask"      the agent reads the workspace and answers. Proposes no edits,
  --              opens no review, writes nothing.
  --   "inline"   DEFAULT. The cursor-IDE clone: the agent works confined in the
  --              overlay, every change is offered as reviewable hunks, and the
  --              journaled applier writes the real tree only after acceptance.
  --   "agentic"  a plain wrapper around the full cursor agent. It edits files
  --              itself. No overlay, no change set, no review, no diary.
  mode = "inline",

  -- Direct mode lets cursor-agent write the real workspace without Yana's
  -- overlay or review path. It must be enabled separately from selecting it.
  enable_agentic = false,

  -- Pass --trust so the workspace is trusted in headless mode (no prompt).
  trust = true,


  -- Pass --approve-mcps so MCP servers do not block on interactive consent.
  approve_mcps = false,

  -- Additional artifact directory component names/globs. These affect
  -- grouping and retention strength only; they never grant safety.
  artifact_dir_prefixes = {},

  -- Buffer-local keys during inline hunk review (Avante replace_in_file parity).
  diff_keymaps = {
    ours = "co",
    theirs = "ct",
    all_theirs = "ca",
    all_changes = "cA",
    both = "cb",
    next = "]x",
    prev = "[x",
  },

  -- Inline diff: standard git colors via colorscheme DiffAdd/DiffDelete.
  diff_highlights = {
    incoming = { link = "DiffAdd" },
    deleted = { link = "DiffDelete" },
    hint = { link = "Comment" },
  },

  -- Winbar mode chip: git-style palette aligned with diff_highlights above.
  -- Each mode maps to a YanaMode* highlight group applied in the panel winbar.
  mode_highlights = {
    ask = { link = "Comment" },
    inline = { link = "DiffAdd" },
    agentic = { link = "DiffChange" },
  },

  -- Winbar model chip (`model: auto` or the chosen model id).
  model_highlight = { link = "Special" },

  -- Prepended to agent-mode prompts. Nil disables.
  agent_instructions = [[
Agent mode: you have write access. When the user asks to populate, add, change, or give an example in a file, EDIT that file with the Edit File tool immediately — do not only reply in chat or ask whether to paste. Use minimal diffs at the referenced line numbers. When a visual selection is attached, prefer edits inside the stated edit zone; out-of-zone edits may be rejected or flagged before review. The user reviews each edit as inline hunks in the open file (co/ct/ca) before it is final.
]],

  selection_scope = {
    -- "reject" hard-blocks out-of-zone edits; "warn" keeps them reviewable with a note; "off" disables.
    enforce = "reject",
    -- When no function/class/cell resolves, bare selection uses this level instead of a 1-line jail.
    unstructured = "warn",
    cell_markers = { "# %%", "#%%" },
    min_zone_lines = 1,
    -- Out-of-zone rejections per path in one turn before cancel_inflight.
    rejection_cap = 3,
  },

  queue = {
    -- When a turn finishes with an agent-level error, hold any queued
    -- follow-ups (do not auto-fire the next one) and notify instead — the
    -- user decides whether to still send them via the queue picker/keymap.
    pause_on_error = false,
  },

  redirect = {
    -- After cancelling, wait this long for the process's exit to be observed
    -- before escalating to SIGKILL.
    confirm_exit_timeout_ms = 3000,
    -- After SIGKILL, wait this long more; if the process still won't die the
    -- redirect is aborted (text returned to the prompt) — never two processes.
    kill_grace_ms = 1500,
    -- One-line prefix telling the model the previous turn was cut.
    marker = "[redirect — previous turn interrupted]",
  },

  context = {
    -- When no visual selection is given, tell the agent which file/line the
    -- cursor is on so it can open the file itself.
    include_file = true,
    -- Hard cap on selection lines embedded into the prompt.
    max_selection_lines = 600,
  },

  sessions = {
    -- Where yana stores its session registry and transcripts.
    -- nil => stdpath("data") .. "/yana".
    dir = nil,
    -- Where the cursor-agent CLI stores its chats (for discovering sessions
    -- started outside Neovim). nil => ~/.cursor/chats.
    chats_dir = nil,
    -- Maximum number of sessions shown in the picker.
    max = 50,
  },

  ui = {
    -- Sidebar width. <= 1 is treated as a fraction of total columns,
    -- > 1 is an absolute column count.
    width = 0.40,
    -- Height (in rows) of the prompt input area at the bottom.
    prompt_height = 6,
    -- "right" or "left".
    position = "right",
    wrap = true,
    -- Show token usage / duration after each answer.
    show_usage = true,
    -- Render the model's "thinking" content (if any).
    show_thinking = false,
    -- Spinner frames shown in the winbar while the agent is responding.
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Buffer-local keymaps inside the panel. Set any to false/nil to disable.
  keymaps = {
    submit = "<C-s>",        -- submit prompt (insert + normal mode)
    submit_normal = "<CR>",  -- submit prompt (normal mode only)
    new_chat = "<C-n>",      -- start a fresh chat (clears session)
    toggle_mode = "<M-t>",   -- Alt+t: cycle mode (avoid <C-t> — Vim tag pop / E73)
    -- Alt+r: resend-last-prompt PREFIX. Three leaves, each with a `desc`
    -- (shown by :map and by which-key if you use it):
    --   <M-r>r  here  — same chat, same session, same mode
    --   <M-r>n  new   — new chat (fresh session), this chat's mode
    --   <M-r>a  agent — new chat forced to agent mode (ask -> "now do it")
    resend = "<M-r>",
    model = "<C-g>",         -- open the model picker
    review = "<C-y>",        -- open inline review for a pending change
    accept = "<C-a>",        -- accept a pending change (keep agent edit)
    reject = "<C-x>",        -- reject a pending change (revert file)
    diff = "<C-y>",          -- alias for review (deprecated name)
    focus_prompt = "i",      -- from the conversation window, jump to prompt
    close = "q",             -- close the panel (from either window, normal mode)
    stop = "<C-c>",          -- stop an in-flight response
    sessions = "<M-s>",      -- Alt+s: pick a session to view/resume
    new_panel = "<M-n>",     -- Alt+n: open an additional panel (parallel session)
    queue = "<M-q>",         -- Alt+q: view/edit/delete/reorder queued follow-ups
    -- Interrupt the in-flight response and immediately resend the prompt
    -- buffer as a new turn (session context preserved via --resume). Insert
    -- + normal mode, prompt buffer only. NOTE: many terminals cannot tell
    -- <C-CR> apart from plain <CR> without the Kitty keyboard protocol (or
    -- equivalent) enabled — if that's the case for you, rebind to something
    -- your terminal reports distinctly (e.g. "<M-CR>" or a leader-prefixed key).
    steer = "<C-CR>",
    -- Manually open the completion menu (slash-commands / @mentions) from an
    -- empty prompt line or mid-sentence, without a trigger character.
    -- Insert mode, prompt buffer only.
    --
    -- Coexistence constraint with blink.cmp, if installed: blink re-applies
    -- its OWN buffer-local <C-Space> -> cmp.show() on every InsertEnter
    -- (blink.cmp/lua/blink/cmp/keymap/init.lua keymap.setup's InsertEnter
    -- autocmd calls apply.keymap_to_current_buffer unconditionally whenever
    -- config.enabled() is true for the buffer). So yana's own buffer-local
    -- <C-Space> mapping (apply_panel_keymaps, set once at panel-open time) is
    -- only ever live until blink's next InsertEnter overwrites it — kept as a
    -- same-behavior fallback for when blink.cmp is absent or disabled, not as
    -- a competing keymap. If your blink.cmp config scopes providers for
    -- yana's prompt buffer (check `vim.b.yana_prompt == true` and return
    -- yana's sources), blink's own <C-Space> opens the yana-scoped menu and
    -- the two mappings perform the SAME action; without that scoping, blink
    -- opens its default providers instead (:checkhealth yana reports this).
    completion_menu = "<C-Space>",
  },

  -- Roots to scan for skills (each a directory whose entries are
  -- skill-directories containing a SKILL.md). Preference-shaped — WHICH
  -- roots to look in is configurable here; the scanning LOGIC that reads
  -- them stays in lua/yana/commands.lua. Project-local
  -- `<git-root-or-cwd>/.cursor/skills` is always scanned too, ahead of this
  -- list, the same way project `.cursor/commands` outranks
  -- `~/.cursor/commands` — it is not listed here because "project root"
  -- is a runtime value, not a preference.
  skill_dirs = {
    vim.fn.expand("~/.cursor/skills"),
    vim.fn.expand("~/.cursor/skills-cursor"),
    vim.fn.expand("~/.claude/skills"),
  },

  -- Inline edit ("Ctrl-K"): select lines, state an instruction in a small float
  -- over the selection, and have the agent rewrite exactly those lines. The
  -- result is NOT special-cased — it becomes a normal agent turn whose changes
  -- land in the ordinary inline hunk review, so CORE's containment and
  -- accept/reject contract applies unchanged. The only thing this adds is an
  -- entry path that does not require visiting the panel.
  inline_edit = {
    enable = true,
    -- Float geometry. width <= 1 is a fraction of total columns, > 1 absolute.
    width = 0.5,
    -- Extra prompt rows beyond the first; the float grows up to this as you type.
    max_height = 6,
    -- How many past instructions <C-p>/<C-n> can cycle through. 0 disables.
    history = 20,
    -- Float keymaps. submit sends; cancel closes without sending.
    keymaps = {
      submit = "<C-s>",      -- insert + normal
      submit_normal = "<CR>",-- normal only (insert <CR> inserts a newline)
      cancel = "<Esc>",      -- insert + normal
      cancel_normal = "q",   -- normal only
      history_prev = "<C-p>",
      history_next = "<C-n>",
    },
  },

  -- Optional GLOBAL keymaps. Only applied when require("yana").setup{} is
  -- called. Each maps to a command; set to false/nil to skip.
  global_keymaps = {
    toggle = nil,            -- e.g. "<leader>cc" — opens/closes panel from any buffer
    ask = nil,               -- e.g. "<leader>ca" (works in normal + visual)
    -- Inline edit. VISUAL mode only by default, which is what makes "<C-k>" a
    -- safe suggestion despite being heavily used elsewhere: <C-k> is commonly
    -- bound in normal mode (window navigation), insert mode (digraphs) and
    -- inside completion menus, but visual-mode <C-k> is almost always free.
    -- Setting inline_edit_normal too takes the CURRENT LINE as the selection,
    -- and is nil by default precisely because normal-mode <C-k> usually is not
    -- free. e.g. inline_edit = "<C-k>", inline_edit_normal = "<leader>ck"
    inline_edit = nil,
    inline_edit_normal = nil,
  },

	-- Paste an image (or an image file, or plain text) from the system
	-- clipboard into the prompt buffer. See lua/yana/clipboard.lua.
	image_paste = {
		enable = true,
		-- Insert-mode, prompt buffer only. String or list. <C-v> and <C-V> are the
		-- same physical key to Vim (control-chord notation is case-insensitive), so
		-- listing both is purely so either spelling in user config works; add a
		-- genuinely different key here (e.g. "<C-S-v>") to bind more.
		key = { "<C-v>", "<C-V>" },
		keep = 20,          -- pasted images retained in the cache dir
	},


	-- Diagnostic recording, OFF by default. When true, every raw cursor-agent
	-- stdout line is teed verbatim to `<turn_dir>/private/stream.ndjson` and a
	-- `meta.json` sidecar (argv, cwd, mode, model, timestamps, exit code,
	-- stderr) is written at exit, so the turn can be replayed through the real
	-- pipeline by `tests/fake-cursor-agent`.
	--
	-- It is off by default because it is PER-EVENT disk I/O, and the default
	-- configuration owes CTL-CLEAN: a clean turn leaves `yana.log`
	-- byte-identical. The tee writes its own files and never the log, so even
	-- with this on the log stays untouched — the flag only decides whether the
	-- recording files exist at all. See lua/yana/record.lua.
	debug_record = false,
}

M.options = vim.deepcopy(M.defaults)

----------------------------------------------------------------------
-- THE MODE DIAL
--
-- Every question the rest of the product used to ask five options is answered
-- here, from one value. Nothing below is configurable, because each of these
-- was a way for two settings to disagree.
----------------------------------------------------------------------

local MODES = { ask = true, inline = true, agentic = true }

--- Highlight group names for the winbar mode chip (one per named mode).
M.mode_hl_groups = {
  ask = "YanaModeAsk",
  inline = "YanaModeInline",
  agentic = "YanaModeAgentic",
}
M.model_hl_group = "YanaModel"

function M.normalize_mode(value, enable_agentic)
	if value == nil then
		return M.defaults.mode
	end
	if type(value) ~= "string" or MODES[value] == nil then
		error(
			"yana: invalid config.mode "
				.. vim.inspect(value)
				.. ' — one of "ask" (read and answer), "inline" (hunks you review, the default), "agentic" (the agent edits files itself)',
			0
		)
	end
	if value == "agentic" and enable_agentic ~= true then
		error(
			'yana: config.mode = "agentic" requires enable_agentic = true because it writes the real workspace without confinement or review',
			0
		)
	end
	return value
end

--- WHERE THE AGENT RUNS. True for every mode that starts the agent under the
--- harness -- `ask` and `inline` -- and false only for `agentic`, which is the
--- direct surface that the public safety contract places outside containment.
---
--- Ruling R-3, 2026-08-18 (the mode contract section 2). This answered `inline`
--- only until that date, so an `ask` turn ran the agent against the real tree
--- with `--mode ask` on the argv as its only barrier. A vendor flag is a
--- request, not a boundary: the cardinal principle requires the guarantee to
--- hold when cursor-agent is replaced by a hostile executable that ignores the
--- flag, and such an executable does not stop writing because the mode it was
--- launched under is called `ask`. Confinement costs a read-only turn nothing,
--- so the exception was closed rather than documented.
function M.resolve_mode(mode)
	local m = mode
	if m == nil or m == "" then
		m = M.options.mode
	end
	if m == "agent" then
		m = "agentic"
	elseif m == "plan" then
		m = "ask"
	elseif m == "review" then
		m = "inline"
	end
	if MODES[m] ~= nil then
		if m == "agentic" and M.options.enable_agentic ~= true then
			return "inline"
		end
		return m
	end
	return M.options.mode
end

function M.overlay_mode(mode)
	local m = M.resolve_mode(mode)
	return m == "inline" or m == "ask"
end

--- WHO WRITES. Does this mode open hunk reviews and accept through the
--- journaled applier? `inline` only.
---
--- The two predicates are deliberately separate and, since R-3, they no longer
--- give the same answer: `ask` runs confined (overlay_mode) and proposes
--- nothing (no review). Welding them together is what made confinement
--- conditional on there being something to review.
function M.review_mode_active(mode)
	return M.resolve_mode(mode) == "inline"
end

--- The cursor-agent permission mode. An internal consequence of the dial, never
--- a user-facing option.
function M.agent_permission_mode(mode)
	if M.resolve_mode(mode) == "ask" then
		return "ask"
	end
	return "agent"
end

--- Whether this turn's argv carries the vendor permission-bypass flag.
---
--- THIS FUNCTION IS THE ENTIRE DECISION. Adjudicated 2026-08-17 and recorded in
--- the mode contract as a KNOWN EXPOSURE, not a resolution: `--force`
--- governs Cursor's OWN permission prompts, and this product's threat model
--- assumes a hostile agent binary that ignores the vendor permission layer
--- entirely. The boundary is the overlay the agent is confined in plus the hunk
--- review gating every real-tree write -- neither is affected by this flag.
--- Dropping it would surrender all editing (non-force tool calls need an
--- approval a headless `-p` turn has nobody to answer) and buy no security.
---
--- Revisit trigger: the capsule shipping, or a pinned cursor-agent release
--- demonstrating a non-interactive non-force edit -- whichever comes first.
--- When that lands, this returns false and nothing else changes. Every caller
--- asks this function rather than reading a flag, precisely so the reversal is
--- one line here.
function M.agent_needs_permission_flag(mode)
	return M.resolve_mode(mode) ~= "ask"
end

local ENFORCE_MODES = { reject = true, warn = true, off = true }

local function normalize_enforce(value, fallback)
  if type(value) == "string" and ENFORCE_MODES[value] then
    return value
  end
  return fallback
end

function M.normalize_selection_scope(scope)
  local base = vim.deepcopy(M.defaults.selection_scope)
  if type(scope) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, scope)
  out.enforce = normalize_enforce(out.enforce, base.enforce)
  out.unstructured = normalize_enforce(out.unstructured, base.unstructured)
  if type(out.cell_markers) ~= "table" or #out.cell_markers == 0 then
    out.cell_markers = vim.deepcopy(base.cell_markers)
  else
    local markers = {}
    for _, marker in ipairs(out.cell_markers) do
      if type(marker) == "string" and marker ~= "" then
        markers[#markers + 1] = marker
      end
    end
    if #markers == 0 then
      out.cell_markers = vim.deepcopy(base.cell_markers)
    else
      out.cell_markers = markers
    end
  end
  if type(out.min_zone_lines) ~= "number" or out.min_zone_lines < 1 then
    out.min_zone_lines = base.min_zone_lines
  end
  if type(out.rejection_cap) ~= "number" or out.rejection_cap < 1 then
    out.rejection_cap = base.rejection_cap
  end
  return out
end

function M.normalize_image_paste(ip)
  local base = vim.deepcopy(M.defaults.image_paste)
  if type(ip) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, ip)
  if type(out.enable) ~= "boolean" then
    out.enable = base.enable
  end
  -- Accept a bare string or a list; always hand callers a list so the keymap
  -- site never has to branch on the type.
  local keys = {}
  if type(out.key) == "string" then
    if out.key ~= "" then
      keys[1] = out.key
    end
  elseif type(out.key) == "table" then
    for _, k in ipairs(out.key) do
      if type(k) == "string" and k ~= "" then
        keys[#keys + 1] = k
      end
    end
  end
  if #keys == 0 then
    keys = vim.deepcopy(base.key)
  end
  out.key = keys
  if type(out.keep) ~= "number" or out.keep < 1 then
    out.keep = base.keep
  end
  return out
end

function M.normalize_redirect(r)
  local base = vim.deepcopy(M.defaults.redirect)
  if type(r) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, r)
  if type(out.confirm_exit_timeout_ms) ~= "number" or out.confirm_exit_timeout_ms < 50 then
    out.confirm_exit_timeout_ms = base.confirm_exit_timeout_ms
  end
  if type(out.kill_grace_ms) ~= "number" or out.kill_grace_ms < 50 then
    out.kill_grace_ms = base.kill_grace_ms
  end
  if type(out.marker) ~= "string" then
    out.marker = base.marker
  end
  return out
end

function M.normalize_inline_edit(ie)
  local base = vim.deepcopy(M.defaults.inline_edit)
  if type(ie) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, ie)
  if type(out.enable) ~= "boolean" then
    out.enable = base.enable
  end
  -- width follows the ui.width convention: <= 1 is a fraction, > 1 absolute.
  -- Anything else (0, negative, non-number) falls back rather than producing a
  -- zero-width float the user cannot type into.
  if type(out.width) ~= "number" or out.width <= 0 then
    out.width = base.width
  end
  if type(out.max_height) ~= "number" or out.max_height < 1 then
    out.max_height = base.max_height
  end
  if type(out.history) ~= "number" or out.history < 0 then
    out.history = base.history
  end
  if type(out.keymaps) ~= "table" then
    out.keymaps = vim.deepcopy(base.keymaps)
  else
    -- A key set to false/nil is "unbound", which is legitimate; a non-string is
    -- not, and would throw inside vim.keymap.set at float-open time instead of
    -- at setup time where the mistake is.
    for name, key in pairs(out.keymaps) do
      if key ~= false and key ~= nil and type(key) ~= "string" then
        out.keymaps[name] = base.keymaps[name]
      end
    end
  end
  return out
end

--- `cmd_env` is either a non-empty string (the env var name) or `false`
--- (step 2 disabled). Anything else falls back to the shipped default name
--- rather than silently disabling env indirection on a typo.
function M.normalize_cmd_env(value)
  if value == false then
    return false
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return M.defaults.cmd_env
end

--- Read an environment variable the way `resolve_cmd` needs to: Neovim's
--- `getenv()` answers an unset variable with `vim.NIL` (or plain `nil`,
--- depending on version) rather than Lua `nil`, so callers that only check
--- `~= nil` get fooled. Every other case (unset, set-but-empty) is folded to
--- Lua `nil` here so callers have exactly one falsy shape to handle.
local function getenv(name)
  local v = vim.fn.getenv(name)
  if v == nil or v == vim.NIL or v == "" then
    return nil
  end
  return v
end

--- THE machine-specific resolution contract for the agent binary (avante.nvim's
--- `api_key_name` indirection, applied to a binary path instead of a secret --
--- see the `cmd`/`cmd_env` comments in M.defaults above for the citation).
--- Every consumer that needs to spawn or probe cursor-agent asks THIS
--- function -- never `config.options.cmd` directly -- so there is exactly one
--- place precedence is decided and exactly one place `~` gets expanded.
---
--- Precedence, first match wins:
---   "config"  -- config.options.cmd, when set (explicit setup({ cmd = .. })).
---   "cmd_env" -- the environment variable NAMED by config.options.cmd_env
---               (default "YANA_AGENT_BIN"; false disables this step), when
---               that variable is itself set and non-empty.
---   "path"    -- the bare name "cursor-agent", left for the caller (jobstart,
---               vim.fn.exepath, ...) to resolve on PATH.
--- `~` is expanded (vim.fn.expand) on whichever string wins; the PATH
--- fallback is a bare command name and is never expanded (there is nothing
--- to expand).
---
--- Returns a table:
---   step        "config" | "cmd_env" | "path" -- which step resolved.
---   value       the resolved command string to spawn or probe.
---   candidates  every step considered, in order, for diagnostics (health
---               rows, error messages): each entry is
---               { step, tried = bool, raw?, expanded?, env_name?, note? }.
---               `tried = true` means this step produced a candidate (raw is
---               the pre-expansion string); `tried = false` means it was
---               skipped or empty, and `note` says why.
function M.resolve_cmd()
  local candidates = {}

  local explicit = M.options.cmd
  if type(explicit) == "string" and explicit ~= "" then
    local expanded = vim.fn.expand(explicit)
    candidates[#candidates + 1] = { step = "config", tried = true, raw = explicit, expanded = expanded }
    return { step = "config", value = expanded, candidates = candidates }
  end
  candidates[#candidates + 1] = { step = "config", tried = false, note = "cmd not set in setup()" }

  local env_name = M.options.cmd_env
  if env_name == false then
    candidates[#candidates + 1] = { step = "cmd_env", tried = false, note = "cmd_env disabled (set to false)" }
  elseif type(env_name) == "string" and env_name ~= "" then
    local env_val = getenv(env_name)
    if env_val then
      local expanded = vim.fn.expand(env_val)
      candidates[#candidates + 1] =
        { step = "cmd_env", tried = true, env_name = env_name, raw = env_val, expanded = expanded }
      return { step = "cmd_env", value = expanded, candidates = candidates }
    end
    candidates[#candidates + 1] =
      { step = "cmd_env", tried = false, env_name = env_name, note = "$" .. env_name .. " is not set" }
  else
    candidates[#candidates + 1] = { step = "cmd_env", tried = false, note = "cmd_env disabled" }
  end

  candidates[#candidates + 1] = { step = "path", tried = true, raw = "cursor-agent", expanded = "cursor-agent" }
  return { step = "path", value = "cursor-agent", candidates = candidates }
end

--- Convenience for hot paths that only need the resolved string (agent spawn,
--- --list-models). Diagnostics that need to explain THEMSELVES (health rows,
--- refusal messages) call M.resolve_cmd() directly for the full candidate
--- list.
function M.cmd()
  return M.resolve_cmd().value
end

function M.normalize_skill_dirs(dirs)
  local base = vim.deepcopy(M.defaults.skill_dirs)
  if type(dirs) ~= "table" then
    return base
  end
  local out = {}
  for _, d in ipairs(dirs) do
    if type(d) == "string" and d ~= "" then
      out[#out + 1] = vim.fn.expand(d)
    end
  end
  if #out == 0 then
    return base
  end
  return out
end

function M.normalize_artifact_dir_prefixes(prefixes)
  if prefixes == nil then
    return {}
  end
  if type(prefixes) ~= "table" then
    error("artifact_dir_prefixes must be a list of directory component names or globs")
  end
  local out, seen = {}, {}
  for _, name in ipairs(prefixes) do
    if type(name) ~= "string"
      or name == ""
      or name == "."
      or name == ".."
      or name:find("/", 1, true)
      or name:find("\\", 1, true)
      or name:find("\0", 1, true)
    then
      error("artifact_dir_prefixes entries must be single directory component names or globs")
    end
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Install configuration ATOMICALLY: nothing becomes effective until every
--- validator has accepted.
---
--- The order here is the whole point. A validator that refuses a value raises,
--- and it raises while the candidate is still a LOCAL table — so the raise
--- leaves `M.options` exactly as it was before the call. The alternative, which
--- this replaced, published the merged table first and validated after, so a
--- refused `mode` errored loudly AND stayed effective: `overlay_mode()` false,
--- `review_mode_active()` false, `--force` on the argv. A rejected
--- configuration produced the least confined state the product has.
---
--- FIRST-CALL CASE: `M.options` is seeded with the defaults at module load
--- (above), so there is no window in which the product is unconfigured. A
--- setup that fails on the very first call therefore leaves the DEFAULTS
--- effective — mode "inline", which is the overlay-confined, review-gated,
--- fail-closed state. "Unconfigured" was never an option worth having: it
--- would mean a turn could run with no mode at all, which is the same defect
--- wearing a different hat.
---
--- The error is re-raised unchanged (it simply propagates), so the user
--- still sees which key was wrong and what the accepted values are.
function M.setup(opts)
  opts = opts or {}
  local next_options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Replace (do not deep-merge) each highlight role so a custom bg/fg does not
  -- keep a leftover defaults.link (e.g. DiffAdd) that would win at apply time.
  if opts.diff_highlights then
    next_options.diff_highlights = vim.deepcopy(M.defaults.diff_highlights)
    for role, spec in pairs(opts.diff_highlights) do
      next_options.diff_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.mode_highlights then
    next_options.mode_highlights = vim.deepcopy(M.defaults.mode_highlights)
    for role, spec in pairs(opts.mode_highlights) do
      next_options.mode_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.model_highlight then
    next_options.model_highlight = vim.deepcopy(opts.model_highlight)
  end
  -- Every validator runs against the candidate. Any of them may raise; none of
  -- them can leave a half-installed configuration behind.
  next_options.selection_scope = M.normalize_selection_scope(next_options.selection_scope)
  next_options.image_paste = M.normalize_image_paste(next_options.image_paste)
  next_options.redirect = M.normalize_redirect(next_options.redirect)
  next_options.inline_edit = M.normalize_inline_edit(next_options.inline_edit)
  next_options.skill_dirs = M.normalize_skill_dirs(next_options.skill_dirs)
  next_options.artifact_dir_prefixes = M.normalize_artifact_dir_prefixes(next_options.artifact_dir_prefixes)
  next_options.cmd_env = M.normalize_cmd_env(next_options.cmd_env)
  next_options.enable_agentic = next_options.enable_agentic == true
  next_options.mode = M.normalize_mode(next_options.mode, next_options.enable_agentic)
  -- Only now does anything become effective.
  M.options = next_options
  M.apply_mode_highlights()
  return M.options
end

--- Apply winbar chip highlights from `mode_highlights` and `model_highlight`.
function M.apply_mode_highlights()
  local h = M.options.mode_highlights or M.defaults.mode_highlights
  for mode, group in pairs(M.mode_hl_groups) do
    local spec = h[mode] or {}
    if spec.link and not spec.bg and not spec.fg then
      vim.api.nvim_set_hl(0, group, { link = spec.link, default = true, force = true })
    else
      local hl = vim.tbl_extend("force", spec, { force = true })
      hl.link = nil
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
  local ms = M.options.model_highlight or M.defaults.model_highlight or {}
  if ms.link and not ms.bg and not ms.fg then
    vim.api.nvim_set_hl(0, M.model_hl_group, { link = ms.link, default = true, force = true })
  else
    local hl = vim.tbl_extend("force", ms, { force = true })
    hl.link = nil
    vim.api.nvim_set_hl(0, M.model_hl_group, hl)
  end
end

-- The cursor-agent permission mode for this turn. The panel argument is kept so
-- every existing call site still compiles, but it is no longer authoritative:
-- mode is a product-level dial, not a per-panel one, which is what stopped two
-- panels from disagreeing about what a turn was allowed to do.
function M.panel_mode(panel_mode)
  return M.resolve_mode(panel_mode)
end

return M
