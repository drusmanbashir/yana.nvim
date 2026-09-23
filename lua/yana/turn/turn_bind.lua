-- The settler is an adapter over the v1 settle path during cutover.
local Turn = require("yana.turn.turn")
local wiring = require("yana.turn.turn_wiring")
local settle = require("yana.turn.turn_settle")
local turn_overlay = require("yana.turn.turn_overlay")

local M = {}

-- ONE current-Turn slot; turn_bind is the sole writer. Pool args are ignored (compat until W8).
local current = nil
local current_overlay = nil
-- The pool the live Turn was bound to; the one record sidebar chrome asks.
local current_pool = nil

-- Advance hook invoked when a file reaches zero pending mid-turn. Not a Turn method
-- or Bus signal (Turn never drives UI). Wired once in observe_open, dropped with the Turn.
local current_advance = nil

-- ACK record per panel AND epoch, written only here, so a retry re-requests only
-- owners still owed and never closes a review twice.
local function ack_key(f)
	local owner = f.review_owner
	if type(owner) == "table" and owner.panel_id ~= nil and owner.epoch ~= nil then
		return "panel:" .. tostring(owner.panel_id) .. "/epoch:" .. tostring(owner.epoch)
	end
	return f.review_opts and f.review_opts.on_close or nil
end

-- Ask each distinct un-acknowledged panel owner to close its review. "pending"
-- means the callback will call `settled` later; nil/true is a synchronous ok.
local function close_review_owners(turn, cause, done)
	local acks = turn.review_close_acks
	if type(acks) ~= "table" then
		acks = {}
		turn.review_close_acks = acks
	end
	local owners = {}
	local seen = {}
	for _, f in ipairs(turn.files) do
		local opts = f.review_opts
		if type(opts) == "table" and type(opts.on_close) == "function" then
			local key = ack_key(f)
			if key ~= nil and not seen[key] and not acks[key] then
				seen[key] = true
				owners[#owners + 1] = { opts = opts, close = opts.on_close, key = key }
			end
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
			else
					-- The ACK is the ownership boundary: a partial success retries only the rest.
				acks[owner.key] = true
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

-- THE ONE TERMINAL SWEEP: the Turn's mandatory `deps.cleanup`, run BEFORE publication
-- over each member's ACTIVE and PARKED review. May refuse, naming stage and file.
-- `hooks.queue_pool_for` resolves the per-file pool so a multi-pool Turn retires only
-- its own members.
local function cleanup_turn_members(turn, hooks)
	local lifecycle = require("yana.review_lifecycle")
	local failures = {}
	local members = {}

	for _, f in ipairs(turn.files) do
		local change = f.change
		local file_pool = hooks and hooks.queue_pool_for and hooks.queue_pool_for(f) or current_pool
		local active = file_pool and file_pool.active

		-- EXACT states, active and parked, each closed once.
		local states, seen = {}, {}
		local function consider(state)
			if type(state) == "table" and not seen[state] then
				seen[state] = true
				states[#states + 1] = state
			end
		end
		consider(f.review_state)
		if type(change) == "table" then
			consider(change._parked_state)
			consider(change._parked_review)
			if active ~= nil and active.change == change then
				consider(active)
			end
		end

		members[#members + 1] = {
			file = f,
			change = change,
			pool = file_pool,
			active = active,
			states = states,
		}
		for _, state in ipairs(states) do
			local called, result, reason = pcall(lifecycle.cleanup, state)
			if not called then
				failures[#failures + 1] = tostring(f.path) .. ": " .. tostring(result)
			elseif result ~= true then
				failures[#failures + 1] = tostring(f.path) .. ": " .. tostring(reason or "cleanup_refused")
			end
		end
	end

	if #failures > 0 then
		return false, table.concat(failures, "; ")
	end

	-- Attachment, status and pool ownership stay intact until every state has closed,
	-- so a refusal or throw can retry the exact members.
	for _, member in ipairs(members) do
		local f, change = member.file, member.change
		if type(change) == "table" and change.status == "pending" then
			change.status = f:accepted() and "accepted" or "rejected"
		end
		for _, state in ipairs(member.states) do
			if rawequal(f.review_state, state) then
				local detached, detach_err = turn:detach_review(f.path, state)
				if not detached then
					return false, tostring(f.path) .. ": " .. tostring(detach_err)
				end
			end
		end
		local file_pool, active = member.pool, member.active
		if file_pool ~= nil and active ~= nil and active.change == change and file_pool.active == active then
			file_pool.active = nil
		end
	end
	return true
end

local function clear_if_current(turn)
	if current == turn then
		current = nil
		current_overlay = nil
		current_advance = nil
		current_pool = nil
	end
end

-- `files` built from the pool's changes. `hooks`: v1_settle(f) per-file settle
-- (may be nil); opts_fn() config accessor; on_gone(turn) v1 pool cleanup.
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
		cleanup = function(turn)
			return cleanup_turn_members(turn, hooks)
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

-- Called once a file's review is live (review_open_bind.lua). Registers the UI teardown
-- callbacks ONCE and grows the file list. Theme preview (`opts.preview`) binds NO Turn.
function M.observe_open(pool, file_entry, hooks)
	local review_opts = file_entry and file_entry.review_opts
	if type(review_opts) == "table" and review_opts.preview then
		return nil
	end
	local t = M.bind(pool, {}, hooks)
		-- THE one write of the live Turn's pool: intake binds with `pool = nil`, and it
		-- must be known before `t:start()` so `turn_start` subscribers can ask.
	if pool ~= nil then
		current_pool = pool
	end
	local fresh = not t._wired
	current_overlay:add_file(file_entry)
	local file = assert(t:add_file(file_entry), "turn_bind.observe_open: file must join the Turn")
	if file_entry.review_state ~= nil then
		local attached, attach_err = t:attach_review(file.path, file_entry.review_state)
		assert(attached, attach_err)
	end
	if fresh then
		t._wired = true
		current_advance = hooks.advance
			-- A file may park AFTER its last hunk was decided; remove exact Turn members from
			-- EACH file's pool before `shadow_release` can launch the next turn. Never clear a
			-- pool (it may hold another owner).
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
			-- Namespaces and keys are released by `review_resources.close` through the owner
			-- table. The button strip's only existence condition is a live Turn; `pool.active`
			-- decides dimming at render time.
		t:register({
			name = "buttons",
			turn_start = function(_cb, _ctx)
				pcall(require("yana.panel.ui_review_buttons").open, pool)
			end,
			review_alive = function(_cb, _ctx)
				pcall(require("yana.panel.ui_review_buttons").open, pool)
			end,
			review_finished = function(_cb, _ctx)
				pcall(require("yana.panel.ui_review_buttons").refresh)
			end,
			turn_end = function(_cb, _ctx)
				pcall(require("yana.panel.ui_review_buttons").remove, pool)
			end,
		})
			-- No `turn_end` teardown listener: `deps.cleanup` (mandatory, fallible) sweeps active AND parked reviews.
		t:start()
	end
	return t
end

-- The live Turn's pool, or nil when none is live.
function M.live_pool()
	if current and current:is_live() then
		return current_pool
	end
	return nil
end

-- Singleton accessor; `pool` ignored (compat until W8).
function M.get(pool)
	if current and current:is_live() then
		return current
	end
	return nil
end

-- Intake binds a file before its buffer opens. A terminal refusal must undo
-- that pre-bind so an empty singleton cannot block or contaminate the next review.
function M.withdraw_unopened(path)
	if not (current and current:is_live()) then
		return true
	end
	if current:file(path) == nil then
		return true
	end
	local withdrew, empty_or_err = current:withdraw_unopened_file(path)
	if not withdrew then
		return false, empty_or_err
	end
	if current_overlay then
		current_overlay:remove_file(path)
	end
	if empty_or_err then
		return current:retire_empty("review_open_refused")
	end
	return true
end

function M.overlay(pool)
	if M.get(pool) then
		return current_overlay
	end
	return nil
end

-- `u` walked the decision history back to pending; the Turn runs the one End process.
function M.on_undo_exhausted(pool)
	local t = M.get(pool)
	if t then
		t:on_undo_exhausted()
	end
end

-- The leave edge: zero pending across the Turn is the "decided" trigger inside Turn.
--- `trigger` is the control's own name, forwarded from `_poll_leave_edge`. The
--- owning review travels with it so an End that completes asynchronously still
--- reports who asked and for which review.
function M.on_decision(pool, state, trigger)
	local t = M.get(pool)
	if not t then
		return
	end
	t:on_decision(trigger, state and state.opts and state.opts.review_owner or nil)
		-- No advance while ACK-waiting or with cleanup owed: the next queued owner would
		-- join a Turn that is already finishing.
	if t:is_live() and not t.ending and not t.close_error and not t.cleanup_error
		and current_advance and state and state.hunk_ledger and state.hunk_ledger:count() == 0
	then
		pcall(current_advance, state)
	end
end

-- `announce_review`: render trigger from a file's open path. `refresh_review_liveness`:
-- pulled on every history move. The Turn owns the edge and the emit.
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

-- Abort routes through the same end steps.
--- The `cR` control. It has its own source: an Abort is not the last hunk
--- being decided, and a result that says `last_hunk` for it is a lie about
--- what the operator did.
function M.abort(pool, owner)
	local t = M.get(pool)
	if t then
		return t:end_turn("abort", { source = "abort_control", owner = owner })
	end
	return false
end

return M
