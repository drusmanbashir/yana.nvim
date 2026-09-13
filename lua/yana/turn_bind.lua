-- During the cutover the settler is an ADAPTER over the v1 settle path so byte
-- behaviour is unchanged while the doors flip; turn_settle.lua replaces it in the next
-- step, together with disconnecting the v1 applier.
local Turn = require("yana.turn")
local wiring = require("yana.turn_wiring")
local settle = require("yana.turn_settle")
local turn_overlay = require("yana.turn_overlay")

local M = {}

-- ONE current-Turn slot. turn_bind is the sole writer; pool args on the public
-- API stay for call-site compat until W8 removes pool plumbing. Lookups ignore
-- the pool key and return this singleton.
local current = nil
local current_overlay = nil
-- The pool the live Turn was bound to. Sidebar chrome asks "is there a live
-- Turn for this pool/panel?" and this is the ONE record that can answer it;
-- nothing else keeps a second copy.
local current_pool = nil

-- Action C (ADJUDICATED 10): the advance hook a file reaching zero pending
-- mid-turn invokes -- NOT a Turn method, NOT a Turn bus signal (Turn never
-- drives UI, turn.lua:4, and does not know which file is active). Wired once,
-- same moment as the other UI callbacks (observe_open's `fresh` branch), and
-- dropped with the Turn it belongs to.
local current_advance = nil

-- Ask each distinct panel owner to durably close its review. A callback that
-- returns "pending" owns an asynchronous daemon ACK and must call `settled`;
-- legacy synchronous callbacks remain valid by returning nil/true.
local function close_review_owners(turn, cause, done)
	local owners = {}
	local seen_by_panel = {}
	local seen_callbacks = {}
	for _, f in ipairs(turn.files) do
		local opts = f.review_opts
		if type(opts) == "table" and type(opts.on_close) == "function" then
			local first = false
			local owner = f.review_owner
			if type(owner) == "table" and owner.panel_id ~= nil and owner.epoch ~= nil then
				local epochs = seen_by_panel[owner.panel_id]
				if not epochs then
					epochs = {}
					seen_by_panel[owner.panel_id] = epochs
				end
				if not epochs[owner.epoch] then
					epochs[owner.epoch] = true
					first = true
				end
			elseif not seen_callbacks[opts.on_close] then
				seen_callbacks[opts.on_close] = true
				first = true
			end
			if first then owners[#owners + 1] = { opts = opts, close = opts.on_close } end
		end
	end
	if #owners == 0 then
		done(true)
		return true
	end

	local remaining = #owners
	local refused, refusal_error = false, nil
	local completed = false
	local function finish_if_ready()
		if remaining ~= 0 or completed then return end
		completed = true
		done(not refused, refusal_error)
	end
	for _, owner in ipairs(owners) do
		local reported = false
		local function settled(ok, err)
			if reported then return end
			reported = true
			if not ok then
				refused = true
				refusal_error = refusal_error or err or "review_close_refused"
			end
			remaining = remaining - 1
			finish_if_ready()
		end
		local ok, result, err = pcall(owner.close, { opts = owner.opts, close_cause = cause }, true, settled)
		if not ok then
			settled(false, result)
		elseif result ~= "pending" then
			settled(result ~= false, err)
		end
	end
	finish_if_ready()
	if completed then
		return not refused, refusal_error
	end
	return "pending"
end

local function clear_if_current(turn)
	if current == turn then
		current = nil
		current_overlay = nil
		current_advance = nil
		current_pool = nil
	end
end

-- Born at the handover (W1): `files` built from the pool's changes. `hooks`:
--   v1_settle(f)  — per-file settle closure (cutover adapter; may be nil)
--   opts_fn()     — config options accessor (dialog / future gate config)
--   on_gone(turn) — v1 pool cleanup
function M.bind(pool, files, hooks)
	if current and current:is_live() then
		for _, file in ipairs(files or {}) do
			current_overlay:add_file(file)
			current:add_file(file)
		end
		return current
	end
	local hooks_on_gone = hooks and hooks.on_gone
	current = Turn.new(files, {
		ask = wiring.make_ask(hooks.opts_fn),
		settler = settle,
		close = function(turn, cause, _refused, done)
			return close_review_owners(turn, cause, done)
		end,
		on_gone = function(turn)
			clear_if_current(turn)
			if hooks_on_gone then
				hooks_on_gone(turn)
			end
		end,
	})
	current_overlay = turn_overlay.new(files)
	return current
end

-- W1 entry: called from the open path once a file's review is live
-- (review_open_bind.lua, right after the rewind watcher attaches). This is still where
-- the UI teardown callbacks get registered ONCE, and where the file list
-- grows/refreshes as each review actually opens. Theme preview (`opts.preview`) binds
-- NO Turn — scrub-only close.
--
function M.observe_open(pool, file_entry, hooks)
	local review_opts = file_entry and file_entry.review_opts
	if type(review_opts) == "table" and review_opts.preview then
		return nil
	end
	local t = M.bind(pool, {}, hooks)
	-- THE one write of the live Turn's pool. Not `bind`: intake binds the Turn
	-- from the queued batch with `pool = nil` (ui_review.lua), so bind is not
	-- where the pool becomes known -- this is, and it happens before
	-- `t:start()` so the `turn_start` subscribers can already ask.
	if pool ~= nil then
		current_pool = pool
	end
	local fresh = not t._wired
	current_overlay:add_file(file_entry)
	t:add_file(file_entry)
	if fresh then
		t._wired = true
		current_advance = hooks.advance
		-- Action C may park a file
		-- AFTER its last hunk was decided so a pending sibling can open. That
		-- queue node belongs to this live Turn only. Remove exact Turn members
		-- from EACH file's workspace pool before `shadow_release` can launch the
		-- next turn; never clear a pool, because it may hold another owner.
		if hooks.queue_remove_change then
			t:register({
				name = "queue",
				turn_end = function(_cb, ctx)
					for _, f in ipairs(ctx.turn.files) do
						if f.change then
							local owning_pool = hooks.queue_pool_for and hooks.queue_pool_for(f) or pool
							hooks.queue_remove_change(owning_pool, f.change)
						end
					end
				end,
			})
		end
		t:register(wiring.tabs_callback(hooks.tabs))
		t:register(wiring.paint_callback(hooks.paint_ns, hooks.authority_ns))
		t:register(wiring.keymap_callback(hooks.bound_keys))
		-- The button strip is sidebar chrome with ONE condition: a live Turn.
		-- `turn_start` attaches it, `turn_end` removes it, and everything in
		-- between only re-renders -- `pool.active` (which review is shown, or
		-- none) is read at render time and decides dimming, never existence.
		t:register({
			name = "buttons",
			turn_start = function(_cb, _ctx)
				pcall(require("yana.ui_review_buttons").open, pool)
			end,
			review_alive = function(_cb, _ctx)
				pcall(require("yana.ui_review_buttons").open, pool)
			end,
			review_finished = function(_cb, _ctx)
				pcall(require("yana.ui_review_buttons").refresh)
			end,
			turn_end = function(_cb, _ctx)
				pcall(require("yana.ui_review_buttons").remove, pool)
			end,
		})
		if hooks.v1_teardown then
			t:register({ name = "v1teardown", turn_end = function(_cb, ctx)
				hooks.v1_teardown(ctx)
			end })
		end
		t:start()
	end
	return t
end

-- The live Turn's pool, or nil when no Turn is live. The sidebar's strip
-- precondition (`ui_review_buttons.attach`) reads exactly this.
function M.live_pool()
	if current and current:is_live() then
		return current_pool
	end
	return nil
end

-- Singleton accessor. `pool` ignored (compat until W8).
function M.get(pool)
	if current and current:is_live() then
		return current
	end
	return nil
end

function M.overlay(pool)
	if M.get(pool) then
		return current_overlay
	end
	return nil
end

-- `u` walked the Turn's whole decision history back to pending, nothing left to pop;
-- the Turn runs the one End process. Turn-global, so no path.
function M.on_undo_exhausted(pool)
	local t = M.get(pool)
	if t then
		t:on_undo_exhausted()
	end
end

-- W3: the leave edge. Decision sites report; zero pending across the Turn is the
-- "decided" trigger inside Turn.
function M.on_decision(pool, state)
	local t = M.get(pool)
	if not t then
		return
	end
	t:on_decision()
	-- `live` includes the ACK-waiting interval. It is not an advance interval:
	-- attaching the next queued owner there makes it a member of the Turn whose
	-- terminal cleanup is already in flight.
	if t:is_live() and not t.ending and not t.close_error
		and current_advance and state and state.hunk_ledger and state.hunk_ledger:count() == 0
	then
		pcall(current_advance, state)
	end
end

-- `announce_review` is the render trigger a file's own open
-- path pulls once its review surface is up; `refresh_review_liveness` is what
-- every history move (undo, redo) pulls so the Turn can re-derive whether a
-- pending hunk is still reachable. Neither decides anything -- the Turn owns
-- the edge and the emit, exactly as it owns the End process.
function M.announce_review(pool)
	local t = M.get(pool)
	if t then
		t:announce_review()
	end
end

function M.refresh_review_liveness(pool)
	local t = M.get(pool)
	if t then
		t:refresh_review_liveness()
	end
end

-- W4: abort. The abort command routes through the same two steps.
function M.abort(pool)
	local t = M.get(pool)
	if t then
		return t:end_turn("abort")
	end
	return false
end

return M
