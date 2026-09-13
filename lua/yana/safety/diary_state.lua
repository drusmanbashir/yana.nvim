--
-- Read-only classifiers on one real path or one operation's recorded
-- before-state. Depend only on the diary_fs base layer (`read_bytes`,
-- `hash_bytes`) and `uv`, never on `session`/`op` write machinery, so they
-- are the second clean layer above diary_fs.lua.
local M = {}

function M.new(deps)
	local uv = deps.uv
	local read_bytes = deps.read_bytes
	local hash_bytes = deps.hash_bytes
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state
	-- Late-bound: `M.refusal_message` is defined much later in diary.lua
	-- (the readers group), so this forwards through the parent's `M` table
	-- rather than capturing it before it exists.
	local refusal_message = deps.refusal_message


	--- The observable before-state of one real path, TAGGED.
	---
	--- change-model: "Each operation records the lower-layer before-state fingerprint, OR
	--- ABSENCE, for that touched path." Absence is a state, not a hash of nothing, and
	--- neither of them is what an unreadable file is. The old representation collapsed all
	--- three onto the empty fingerprint: a present file whose bytes could not be read
	--- compared equal to nothing-there, so an accepted deletion passed its check, retained
	--- an EMPTY displaced copy, and then unlinked the real file. Every byte of it was
	---
	--- Returns `{ kind = "absent" }`, `{ kind = "link", mode, target }`,
	--- `{ kind = "file", bytes, hash, mode, dev, ino }`, or nil plus a named refusal.
	local function observe_state(path)
		local st = uv.fs_lstat(path)
		if not st then
			return { kind = "absent" }
		end
		if st.type == "link" then
			local target = uv.fs_readlink(path)
			if not target then
				return nil,
					path
						.. ": this symlink exists but its target could not be read — refusing; nothing was changed"
			end
			return {
				kind = "link",
				mode = st.mode,
				target = target,
			}
		end
		if st.type ~= "file" then
			return nil,
				path
					.. ": this path is a "
					.. tostring(st.type)
					.. ", not a regular file — the applier writes and displaces regular files only, so it refuses"
					.. " rather than act through it; nothing was changed and both versions are intact"
		end
		local content, rerr = read_bytes(path)
		if content == nil then
			return nil,
				path
					.. ": this file exists but could not be read ("
					.. tostring(rerr or "unreadable")
					.. "), so its bytes cannot be retained as a displaced copy — refusing; nothing was changed."
					.. " Make it readable and re-run, or reject this file"
		end
		return {
			kind = "file",
			bytes = content,
			hash = hash_bytes(content),
			mode = st.mode,
			dev = st.dev,
			ino = st.ino,
		}
	end

	local function mode_perm(mode)
		return mode and (mode % 4096) or nil
	end

	--- Is this a mode a restore could actually set?
	---
	--- `uv.fs_chmod` takes a number. A string, a float or a negative is not a mode
	--- the applier can apply, and accepting one meant the refusal arrived from
	--- inside `chmod_temp` — after the rollback row was durable and after the temp
	--- had been written, which is exactly the "wrote a row for something it could
	--- not do" the marker discipline forbids.
	local function valid_mode(mode)
		return type(mode) == "number" and mode == math.floor(mode) and mode >= 0 and mode <= 0xFFFF
	end

	--- The identity of one real path, from a single lstat.
	---
	--- Deliberately weaker than `observe_state`: it never reads the file. An
	--- automatic rollback runs after a rename whose result could not be READ at
	--- all, and refusing to record what it is about to restore over — because those
	--- bytes are unreadable — would leave the failed accept standing for ever.
	--- Identity is what a marker must carry; content is recorded beside it only
	--- where it is known.
	local function identity_of(path)
		local st = uv.fs_lstat(path)
		if not st then
			return { kind = "absent" }
		end
		return { kind = st.type, dev = st.dev, ino = st.ino, mode = st.mode }
	end

	--- Is this operation's accept-time evidence a COMPLETE TAGGED RECORD?
	---
	--- Every field the comparison needs is required, and a missing one refuses rather than
	--- being compared around. The evidence is taken by the producer's own classifying
	--- read; if it did not reach the applier intact, the honest answer is that drift
	--- cannot be judged, which is a refusal. Returns `ok`, and on failure the human reason
	--- plus a THIRD value naming which check failed (`evidence_check`) and the value it
	--- rejected (`evidence_rejected` — a tag, a truncated fingerprint, never raw content).
	local function evidence_complete(op)
		local tag = op.base_state
		if tag ~= "absent" and tag ~= "file" and tag ~= "link" then
			return false,
				tostring(op.path)
					.. ": this change carries no recorded before-state (found "
					.. tostring(tag)
					.. "), so whether the real file is the one the change was prepared against cannot be judged"
					.. " — refusing; nothing was changed. Re-run the turn to produce evidence for it",
				{ evidence_check = "missing_base_state", evidence_rejected = tag == nil and "nil" or tostring(tag) }
		end
		if type(op.base_hash) ~= "string" or #op.base_hash ~= 64 or not op.base_hash:match("^%x+$") then
			return false,
				tostring(op.path)
					.. ": this change carries no usable before-fingerprint — refusing; nothing was changed",
				{
					evidence_check = "malformed_base_hash",
					-- Truncated, and only when it is a hash-shaped string at all: no
					-- content ever crosses this boundary.
					evidence_rejected = type(op.base_hash) == "string" and op.base_hash:sub(1, 16) or type(op.base_hash),
				}
		end
		if (tag == "file" or tag == "link") and op.base_mode == nil then
			return false,
				tostring(op.path)
					.. ": this change records a "
					.. tag
					.. " before-state but no mode for it, so a mode-only human change cannot be seen"
					.. " — refusing; nothing was changed",
				{ evidence_check = "missing_base_mode", evidence_rejected = "nil" }
		end
		if tag == "link" and (type(op.base_link_target) ~= "string" or op.base_link_target == "") then
			return false,
				tostring(op.path)
					.. ": this change records a symlink before-state but no target for it — refusing; nothing was changed",
				{ evidence_check = "missing_base_link_target", evidence_rejected = tostring(op.base_link_target) }
		end
		return true
	end

	--- Does the state just observed match the evidence this operation carries?
	---
	--- `base_state` is the tag, and `evidence_complete` above has already refused
	--- anything without one, so the comparison here is exact in every field: absent
	--- matches only absent, and type, mode, symlink target and content must all
	--- agree.
	local function state_matches(op, state)
		-- Mutation seam (gate): the pre-fix content-only fallback for an operation
		-- carrying no tag. It is what made absence and an empty file compare equal.
		if test_state.fault.allow_untagged_base and op.base_state == nil then
			return (state.kind == "absent" and hash_bytes("") or state.hash) == op.base_hash
		end
		if op.base_state ~= state.kind then
			return false
		end
		if state.kind == "absent" then
			return true
		end
		if state.kind == "link" then
			if state.target ~= op.base_link_target then
				return false
			end
			return mode_perm(state.mode) == mode_perm(op.base_mode)
		end
		if mode_perm(state.mode) ~= mode_perm(op.base_mode) then
			return false
		end
		return state.hash == op.base_hash
	end

	--- Why the observed state is not the recorded one, named for the human.
	local function state_refusal(op, path, state)
		if op.base_state == "absent" and state.kind == "file" then
			return path
				.. ": this file did not exist when the change was prepared and something has created it since"
				.. " — refusing to overwrite it; the agent's version is kept in the turn and yours is untouched"
		end
		if op.base_state == "file" and state.kind == "absent" then
			return path
				.. ": this file existed when the change was prepared and has been removed since"
				.. " — refusing to recreate it; re-diff to decide against the current tree"
		end
		if op.base_state == "link" and state.kind == "link" and op.base_link_target and state.target ~= op.base_link_target then
			return path
				.. ": this symlink's target ("
				.. tostring(state.target)
				.. ") differs from the agent's starting copy ("
				.. tostring(op.base_link_target)
				.. ") — refusing; both versions are kept"
		end
		if op.base_state == "file" and state.kind == "file" and op.base_mode and mode_perm(state.mode) ~= mode_perm(op.base_mode) then
			return path
				.. ": this file's mode differs from the agent's starting copy — refusing; both versions are kept"
		end
		if op.base_state == "link" and state.kind == "link" and op.base_mode and mode_perm(state.mode) ~= mode_perm(op.base_mode) then
			return path
				.. ": this symlink's mode differs from the agent's starting copy — refusing; both versions are kept"
		end
		return refusal_message(path)
	end

	return {
		observe_state = observe_state,
		mode_perm = mode_perm,
		valid_mode = valid_mode,
		identity_of = identity_of,
		evidence_complete = evidence_complete,
		state_matches = state_matches,
		state_refusal = state_refusal,
	}
end

return M
