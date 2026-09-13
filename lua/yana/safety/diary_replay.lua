-- Same names, same behaviour, same write order, moved verbatim.
--
-- `M.replay` is the ~310-line crash-recovery three-way (intent/done/ rollback/revert
-- state-machine reconciliation) plus the journal-reader group that grew up around it
-- (`M.note`, `M.journal_rows`, `M.status_summary`, `M.list_displaced`,
-- `M.recover_displaced`, `M.second_pass_reanchor`, `M.displaced_copy_path`,
-- `M.refusal_message`, `M.empty_hash`) and `M.apply_with_injection`, the test hook that
-- shares `M.replay`'s own journal-lookup shape. Moved whole; never split mid-function.
--
local M = {}

function M.new(deps)
	local uv = deps.uv
	local diff = deps.diff
	local control_plane = deps.control_plane
	local load_journal = deps.load_journal
	local read_bytes = deps.read_bytes
	local hash_bytes = deps.hash_bytes
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local apply_operation = deps.apply_operation
	local complete_rollback = deps.complete_rollback
	local displaced_path_for = deps.displaced_path_for
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` / `diary._config.x` at runtime is still seen
	-- here.
	local test_state = deps.test_state
	local config = deps.config
	local sweep_orphan_temps = deps.sweep_orphan_temps


	-- Recover a diary: resume in-flight ops and report done/reverted/failed.
	local function replay(opts)
		opts = opts or {}
		local session = opts.session
		if opts.aged and (os.time() - (session.created_at or os.time())) >= config.aged_frontier_sec then
			if not opts.confirm_aged then
				return { done = 0, total = 0, needs_confirmation = true, aged = true }
			end
		end

		local rows, truncated, err = load_journal(session)
		if not rows then
			return { done = 0, total = 0, conflicts = {}, failures = { { error = err } } }
		end

		local swept = {}
		local sweep_refused = {}
		if opts.apply_pending then
			local err
			swept, err, sweep_refused = sweep_orphan_temps(session)
			if err then
				return {
					done = 0,
					total = 0,
					conflicts = {},
					failures = { { error = err } },
					swept = swept,
					sweep_refused = sweep_refused,
				}
			end
		end

		local intents = {}
		local done = {}
		local conflicted = {}
		local unlink_start = {}
		local unlink_done = {}
		local revert_start = {}
		local revert_done = {}
		local rollback_start = {}
		local rollback_done = {}
		local restore_temp = {}
		local displaced_rows = {}
		for _, row in ipairs(rows) do
			if row.kind == "intent" then
				intents[#intents + 1] = row
			elseif row.kind == "done" then
				done[row.op_id] = true
			elseif row.kind == "conflict" and row.op_id then
				conflicted[row.op_id] = true
			elseif row.kind == "unlink_start" and row.op_id then
				unlink_start[row.op_id] = row
			elseif row.kind == "unlink_done" and row.op_id then
				unlink_done[row.op_id] = true
			elseif row.kind == "displaced" and row.op_id then
				displaced_rows[row.op_id] = row
			elseif row.kind == "revert_start" and row.op_id then
				revert_start[row.op_id] = row
			elseif row.kind == "revert_done" and row.op_id then
				revert_done[row.op_id] = true
				done[row.op_id] = nil
			elseif row.kind == "rollback_start" and row.op_id then
				-- Last row wins: a retried rollback appends a fresh marker, and the
				-- identity recovery must compare against is the one the most recent
				-- attempt checked.
				rollback_start[row.op_id] = row
			elseif row.kind == "restore_temp" and row.op_id then
				-- Last row wins for the same reason: a retried restore creates its own
				-- fresh temp, and the output recovery may recognise is that one.
				restore_temp[row.op_id] = row
			elseif row.kind == "rollback_done" and row.op_id then
				rollback_done[row.op_id] = true
			end
		end

		local applied = 0
		local reverted = 0
		local rolled_back = 0
		local conflicts = {}
		local failures = {}
		local reverts = {}
		local rollbacks = {}
		for _, op in ipairs(intents) do
			-- Mutation seam (gate): the pre-fix blindness, where an automatic
			-- rollback left no marker replay would look at, so a crash on either
			-- side of its restore fell through to the accept three-way below.
			local marker = rollback_start[op.op_id]
			if test_state.fault.replay_ignores_rollback_rows then
				marker = nil
			end
			marker = marker or revert_start[op.op_id]
			local purpose = marker and marker.purpose
			local in_flight = not test_state.fault.replay_ignores_revert_rows
				and not revert_done[op.op_id]
				and (rollback_done[op.op_id] or marker)
			if revert_done[op.op_id] and test_state.fault.gate_bypass_settled then
				-- Mutation seam (gate): the pre-fix settled branch, which counted a
				-- `revert_done` row as a finished revert without reading the marker or
				-- the restore record that row rests on.
				reverted = reverted + 1
			elseif revert_done[op.op_id] then
				-- A SETTLED REVERT IS A COMPLETION CLAIM LIKE ANY OTHER.
				--
				-- It was the last row that escaped the state machine: `revert_done`
				-- present meant "reverted, count it and move on", so a marker stripped
				-- of its fingerprint or a restore record damaged after the fact was
				-- never looked at again and the revert stayed reported as finished.
				-- Routed through the same gate, the claim is re-validated against the
				-- evidence it rests on; nothing is appended either way.
				local verdict, verr = complete_rollback(session, op, displaced_rows[op.op_id], marker, {
					settled = true,
					restored = restore_temp[op.op_id],
				})
				if verdict == "reverted" then
					-- Reverted accepts are not pending applies.
					reverted = reverted + 1
				elseif verdict == "conflict" then
					conflicts[#conflicts + 1] = op
				else
					failures[#failures + 1] = {
						op_id = op.op_id,
						path = op.path,
						error = verr or "settled revert could not be validated",
					}
				end
			elseif in_flight then
				-- A ROLLBACK CAUGHT MID-FLIGHT. Its markers are a state machine, not decoration:
				-- `revert_start` says a user revert was licensed, `rollback_start` says which
				-- object a restore is about to be performed over and WHY, `rollback_done` says the
				-- restore landed and was verified, and `revert_done` says a revert is finished.
				-- Without this, a crash anywhere between them left the original `done` row standing
				-- or handed the operation to the accept three-way, which re-applied an accept that
				local verdict, verr = complete_rollback(session, op, displaced_rows[op.op_id], marker, {
					rollback_done = rollback_done[op.op_id] and true or false,
					restored = restore_temp[op.op_id],
					apply_pending = opts.apply_pending,
				})
				if verdict == "reverted" then
					reverted = reverted + 1
					revert_done[op.op_id] = true
					done[op.op_id] = nil
					reverts[#reverts + 1] = op
				elseif verdict == "rolled_back" then
					-- The accept was undone on purpose. It is not applied, it is not
					-- pending, and it is never retried here: its verification failed.
					rolled_back = rolled_back + 1
					done[op.op_id] = nil
					rollbacks[#rollbacks + 1] = op
				elseif verdict == "conflict" then
					conflicts[#conflicts + 1] = op
				elseif verdict == "pending" then
					-- Nothing to do without --apply: the rollback is recorded, not finished.
					if purpose == "revert" then
						reverts[#reverts + 1] = op
					else
						rollbacks[#rollbacks + 1] = op
					end
				else
					failures[#failures + 1] = {
						op_id = op.op_id,
						path = op.path,
						error = verr or "rollback recovery failed",
					}
				end
			elseif done[op.op_id] then
				applied = applied + 1
			elseif conflicted[op.op_id] then
				conflicts[#conflicts + 1] = op
			elseif unlink_done[op.op_id] and uv.fs_lstat(op.path) ~= nil then
				conflicts[#conflicts + 1] = op
			else
				local real, rerr = read_bytes(op.path)
				if real == nil then
					-- EXISTENCE IS DECIDED BY LSTAT, NOT BY READABILITY.
					if uv.fs_lstat(op.path) ~= nil then
						failures[#failures + 1] = {
							op_id = op.op_id,
							path = op.path,
							error = rerr or "file unreadable",
						}
					else
						real = ""
					end
				end
				if real ~= nil then
					local h = hash_bytes(real)

					-- Three-way recovery: real equals new -> done; equals old ->
					-- redo; otherwise conflict.
					--
					-- For an unlink the "new" state is ABSENCE, and it has to be
					-- decided with lstat rather than by hashing. read_bytes yields
					-- "" for a missing file, so a bytes-only test cannot separate
					-- the three outcomes this recovery exists to tell apart:
					-- already unlinked, never unlinked (still there with its
					-- turn-start bytes), and someone recreated it since.
					local verdict
					if op.op_kind == "delete" then
						local marker = unlink_start[op.op_id]
						local now = uv.fs_lstat(op.path)
						if unlink_done[op.op_id] then
							if now == nil then
								verdict = "new"
							else
								verdict = "conflict"
							end
						elseif now == nil then
							verdict = "new"
						elseif marker then
							-- The applier was licensed to unlink and no completion row
							-- exists, so whether it acted is unknowable from the journal.
							-- Redo ONLY while the very object the check passed on is
							-- still at the path; a different object carrying the same
							-- bytes is a recreation, and deleting it would destroy work
							-- this turn never read. Identity says what content cannot.
							if
								now.type == "file"
								and marker.checked_type == "file"
								and marker.checked_dev ~= nil
								and marker.checked_ino ~= nil
								and now.dev == marker.checked_dev
								and now.ino == marker.checked_ino
								and h == op.base_hash
							then
								verdict = "old"
							else
								verdict = "conflict"
							end
						elseif h == op.base_hash then
							verdict = "old"
						else
							verdict = "conflict"
						end
					elseif h == hash_bytes(op.target) then
						verdict = "new"
					elseif h == op.base_hash then
						verdict = "old"
					else
						verdict = "conflict"
					end

					if verdict == "new" then
						local ok_mark, err_mark = append_jsonl(journal_path(session), {
							kind = "done",
							op_id = op.op_id,
							path = op.path,
							ts = os.time(),
						})
						if ok_mark then
							done[op.op_id] = true
							applied = applied + 1
						else
							failures[#failures + 1] = {
								op_id = op.op_id,
								path = op.path,
								error = err_mark,
							}
						end
					elseif verdict == "old" then
						if opts.apply_pending then
							local ok, aerr = apply_operation(session, op, {})
							if ok then
								done[op.op_id] = true
								applied = applied + 1
							else
								failures[#failures + 1] = {
									op_id = op.op_id,
									path = op.path,
									error = aerr or "apply failed",
								}
							end
						end
					else
						conflicts[#conflicts + 1] = op
					end
				end
			end
		end

		local frontiers = {}
		for _, op in ipairs(intents) do
			local sid = op.stream or session.stream
			frontiers[sid] = frontiers[sid] or { done = 0, total = 0 }
			frontiers[sid].total = frontiers[sid].total + 1
			if done[op.op_id] then
				frontiers[sid].done = frontiers[sid].done + 1
			end
		end

		return {
			done = applied,
			reverted = reverted,
			rolled_back = rolled_back,
			total = #intents,
			frontiers = frontiers,
			conflicts = conflicts,
			reverts = reverts,
			rollbacks = rollbacks,
			failures = failures,
			truncated_tail = truncated,
			swept = swept,
			sweep_refused = sweep_refused,
		}
	end

	-- Test hook: apply the latest intent for a path with an injected fault.
	local function apply_with_injection(opts)
		opts = opts or {}
		local session = opts.session
		local path = diff.abs_path(opts.path)
		local rows, _, err = load_journal(session)
		if not rows then
			return false, err
		end
		local op
		for i = #rows, 1, -1 do
			local row = rows[i]
			if row.kind == "intent" and row.path == path then
				op = row
				break
			end
		end
		if not op then
			return false, "no intent for path"
		end
		return apply_operation(session, op, {
			inject_after_rename = opts.inject_after_hash,
		})
	end

	-- Build the standard human message for a stale-file conflict refusal.
	local function refusal_message(path)
		return path
			.. ": this file differs from the agent's starting copy — your mid-turn edit or a stale start copy; both versions kept; re-diff offered"
	end

	-- Return the fingerprint hash of empty content.
	local function empty_hash()
		return (hash_bytes(""))
	end

	--- Journal a NOTE row: something durable happened beside the real-tree operations, and
	--- the journal is where this turn's write history is read from.
	---
	--- A note is NOT an operation: it carries no op_id, no intent/done pairing and
	--- nothing replays it. `kind` is namespaced by its caller (`undo.stage`) so a
	--- reader can never mistake one for an `intent`/`done` row.
	local function note(session, row)
		if type(session) ~= "table" or type(session.diary_dir) ~= "string" then
			return false, "no diary session"
		end
		if type(row) ~= "table" or type(row.kind) ~= "string" or row.kind == "" then
			return false, "a journal note needs a kind"
		end
		if row.kind == "intent" or row.kind == "done" or row.kind == "begin" then
			return false, "a journal note may not impersonate an operation row: " .. row.kind
		end
		local note = vim.deepcopy(row)
		note.ts = os.time()
		return append_jsonl(journal_path(session), note)
	end

	-- Return the session's raw journal rows and any truncated tail.
	local function journal_rows(session)
		local rows, tail, err = load_journal(session)
		if not rows then
			return nil, err
		end
		return rows, tail
	end

	-- Summarize journal rows into per-op state and done/pending/refused counts.
	local function status_summary(session)
		local rows, _, err = load_journal(session)
		if not rows then
			return {
				rows = {},
				states = {},
				done = 0,
				pending = 0,
				refused = 0,
				total = 0,
				error = err,
			}
		end
		local states = {}
		local done_ids = {}
		local done, pending, refused, total = 0, 0, 0, 0
		for _, row in ipairs(rows) do
			if row.kind == "intent" then
				total = total + 1
				states[row.op_id] = { rel = vim.fn.fnamemodify(row.path, ":."), state = "intent" }
			elseif row.kind == "displaced" and states[row.op_id] then
				states[row.op_id].state = "displaced"
			elseif row.kind == "done" and states[row.op_id] then
				states[row.op_id].state = "done"
				if not done_ids[row.op_id] then
					done_ids[row.op_id] = true
					done = done + 1
				end
			elseif row.kind == "refused" and states[row.op_id] then
				states[row.op_id].state = "refused"
				if not done_ids[row.op_id] then
					done_ids[row.op_id] = true
					refused = refused + 1
				end
			elseif row.kind == "conflict" and states[row.op_id] then
				states[row.op_id].state = "conflict"
				if not done_ids[row.op_id] then
					done_ids[row.op_id] = true
					refused = refused + 1
				end
			elseif row.kind == "revert_done" and states[row.op_id] then
				states[row.op_id].state = "reverted"
			end
		end
		for _, info in pairs(states) do
			if info.state == "intent" or info.state == "displaced" then
				pending = pending + 1
			end
		end
		return {
			rows = rows,
			states = states,
			done = done,
			pending = pending,
			refused = refused,
			total = total,
		}
	end

	-- Return every displaced-copy row recorded in the session's journal.
	local function list_displaced(session)
		local rows, _, err = load_journal(session)
		local out = {}
		if not rows then
			return out
		end
		for _, row in ipairs(rows) do
			if row.kind == "displaced" then
				out[#out + 1] = row
			end
		end
		return out
	end

	-- Copy a displaced file to an out-of-workspace path, refusing control-plane.
	local function recover_displaced(session, op_id, out_path)
		-- Recovery output paths lie outside the workspace. Recovery
		-- output paths ... get their own explicit output-path refusal rule"), so the
		-- workspace-relative matcher does not apply — but a control-plane path is
		-- still never a write target, INCLUDING another repository's `.git/` that has
		-- nothing to do with this workspace. Classify the LEXICAL output path
		-- (unresolved, so a `.git` symlink keeps its name).
		local out_lit = diff.abs_path_literal(out_path)
		if control_plane.is_control_plane(out_lit) then
			return false, "recover --out refused — control-plane path: " .. out_lit
		end
		local resolved = diff.abs_path(out_path)
		if control_plane.is_control_plane(resolved) then
			return false, "recover --out refused — resolves into a control-plane path: " .. resolved
		end
		-- Distinguish the three outcomes explicitly: recovery must write strictly OUTSIDE the
		-- workspace. Test insideness directly against the resolved workspace prefix.
		local ws = diff.abs_path(session.workspace)
		if resolved == ws or vim.startswith(resolved, ws .. "/") then
			return false, "recover --out must not write inside workspace: " .. out_path
		end
		local rows, _, err = load_journal(session)
		if not rows then
			return false, err
		end
		for _, row in ipairs(rows) do
			if row.kind == "displaced" and row.op_id == op_id then
				local content, rerr = read_bytes(row.displaced_path)
				if content == nil then
					return false, rerr or "displaced file missing"
				end
				local ok, werr = diff.write_file(resolved, content)
				return ok, werr
			end
		end
		return false, "no displaced row for op_id " .. tostring(op_id)
	end

	-- Re-read a file and return its current bytes with a fresh fingerprint.
	local function second_pass_reanchor(opts)
		opts = opts or {}
		local path = diff.abs_path(opts.path)
		local content, err = read_bytes(path)
		if content == nil then
			return nil, err
		end
		return {
			path = path,
			anchor_hash = hash_bytes(content),
			content = content,
		}
	end

	-- Return the on-disk path of an op's displaced copy.
	local function displaced_copy_path(session, op_id)
		return displaced_path_for(session, op_id)
	end

	return {
		replay = replay,
		apply_with_injection = apply_with_injection,
		refusal_message = refusal_message,
		empty_hash = empty_hash,
		note = note,
		journal_rows = journal_rows,
		status_summary = status_summary,
		list_displaced = list_displaced,
		recover_displaced = recover_displaced,
		second_pass_reanchor = second_pass_reanchor,
		displaced_copy_path = displaced_copy_path,
	}
end

return M
