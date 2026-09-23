-- Accept-pass file-claim refusal and per-root diary/checkpoint bookkeeping,
-- split out of shadow/apply.lua. Reached from the facade under the
-- original names, and used directly by shadow/apply_accept.lua and by
-- apply.lua's own standalone/revert path.
local M = {}

local diary = require("yana.safety.diary")
local checkpoint = require("yana.safety.checkpoint")
local apply_claims = require("yana.shadow.apply_claims")

local function claim_context(pass, change)
	pass = pass or {}
	local turn = pass.shadow_turn or pass.review_turn or pass
	local root = (type(change.root) == "string" and change.root ~= "") and change.root or turn.workspace
	local rel = change.rel
	local session_id = turn.yanad_session_id or pass.yanad_session_id or turn.session_id or pass.session_id
	return root, rel, {
		turn_id = tostring(pass.turn_id or turn.turn_id or "?"),
		workspace = turn.workspace,
		stream = turn.stream,
		yanad_session_id = session_id,
		session_id = session_id,
	}
end

--- A `file.claim` THIS change already won, remembered with the (root, rel) it
--- was won for.
---
--- yanad claims are never handed back by the client -- `release_file_claim` is
--- retired plumbing (yanad_async_claim_renewal asserts its absence) -- so a
--- claim this session holds, it still holds. Asking the daemon a second time
--- for an answer already in hand buys nothing and costs a round trip, and it
--- is that round trip that made `<C-r>` on an already-claimed `cA` row need
--- two presses: the first press could only START the request and the reapply
--- had to wait for a callback. Served from here, the same door answers
--- immediately, on the main thread, with NO wait of any kind.
---
--- Only GRANTS are remembered. A refusal clears the record
--- (`record_file_claim_refusal`), so a file we do not hold is always re-asked.
local function cached_grant(change, root, rel, owner)
	local held = change._yanad_claim_held
	if type(held) ~= "table" then
		return nil
	end
	if held.root ~= root or held.rel ~= rel or held.abs ~= change.path then
		return nil
	end
	-- The held record must name the path THIS (root, rel) derives. A held claim
	-- whose path disagrees is not an answer to this request: ask the daemon.
	local canon = apply_claims.file_claim_path(root, rel)
	if type(canon) ~= "string" or canon == "" or held.path ~= canon or held.abs ~= canon then
		return nil
	end
	-- OWNER-BOUND. A claim this session/turn holds is served to that session and
	-- turn only; another owner asking for the same (root, rel) asks the daemon.
	if held.session_id ~= owner.yanad_session_id or held.turn_id ~= owner.turn_id then
		return nil
	end
	return held.path
end

--- The identity a claim authorises: the canonical root, the relative path, the
--- absolute path the write will land on, and the session/turn that asked.
---
--- Every field is read from the change AT THE MOMENT it is computed. A grant
--- freezes one of these; the door that consumes it recomputes another and
--- compares. That is the whole binding: mutating `change.root`, `change.rel` or
--- `change.path` between the request and the write changes the recomputed
--- identity and the frozen one no longer authorises it.
---
--- `canonical` is the path `apply_claims` will ASK THE DAEMON FOR, derived from
--- (root, rel) exactly as the request does. It is what makes the daemon's own
--- answer checkable: the daemon claims a path, and a grant may only be recorded
--- when that path is the one this identity names.
---
--- `CLAIM_IDENTITY` marks a record as a frozen identity, so `grant_file_claim`
--- can tell "here is the record the request froze" from "here is a door context,
--- derive one now".
local CLAIM_IDENTITY = {}

local function identity_of(pass, change)
	local root, rel, owner = claim_context(pass, change)
	return {
		__identity = CLAIM_IDENTITY,
		root = root,
		rel = rel,
		path = change.path,
		canonical = apply_claims.file_claim_path(root, rel),
		session_id = owner.yanad_session_id,
		turn_id = owner.turn_id,
	}
end

--- A root-bound identity is COHERENT only when its three chains agree: the
--- (root, rel) the daemon is asked about must DERIVE the absolute path the write
--- will land on. Freezing `path` and `canonical` independently is not enough --
--- a triple that was contradictory FROM THE START, `{root="/ws", rel="a.lua",
--- path="/escape.lua"}`, satisfies both comparisons separately while naming a
--- file yanad was never asked about. An incoherent identity claims nothing.
local function coherent(id)
	if type(id) ~= "table" then
		return false
	end
	if type(id.canonical) ~= "string" or id.canonical == "" then
		return false
	end
	if type(id.path) ~= "string" or id.path == "" then
		return false
	end
	return vim.fn.fnamemodify(id.path, ":p") == id.canonical
end

local function is_frozen_identity(value)
	return type(value) == "table" and value.__identity == CLAIM_IDENTITY
end

--- Exact comparison of a frozen grant against a freshly recomputed identity.
---
--- `owner` compares session and turn as well, and is used by the DOORS, which
--- recompute from the same kind of context object the grant was frozen from.
--- The applier cannot: it holds an apply pass, whose session id names the
--- shadow turn rather than the yanad session, so a session compare there would
--- refuse every legitimate accept. Path identity is compared on both routes.
---
--- `grant.root_bound` is false only for a grant taken WITHOUT a context -- the
--- direct-applier route used by apply_delete_unlink_happy and
--- overlay_multiroot_review, which grant `(change, token, path)` and then call
--- the applier themselves. Such a grant is still bound to rel and absolute
--- path; it just has no door context to have frozen a root from.
local function identity_matches(grant, now, compare_owner)
	if type(grant) ~= "table" or type(now) ~= "table" then
		return false
	end
	if grant.root_bound then
		if grant.root ~= now.root then
			return false
		end
		-- BOTH SIDES MUST BE SELF-CONSISTENT. Neither the frozen triple nor the
		-- one recomputed now may name a path its own (root, rel) does not derive.
		if not (coherent(grant) and coherent(now)) then
			return false
		end
	end
	if grant.rel ~= now.rel then
		return false
	end
	if grant.path ~= now.path then
		return false
	end
	-- THE DAEMON'S OWN ANSWER IS EVIDENCE, NOT DECORATION. `granted_path` is the
	-- path yanad actually claimed. A root-bound grant may only authorise the
	-- canonical path recomputed NOW from (root, rel); an unbound direct grant may
	-- only authorise the change's own absolute path. Without this a claim won for
	-- one file could be spent on another.
	-- A MISSING CLAIMED PATH IS A REFUSAL, NOT "NOTHING TO CHECK". A grant that
	-- cannot say which path was claimed is not evidence that anything was.
	if type(grant.granted_path) ~= "string" or grant.granted_path == "" then
		return false
	end
	local authorised = grant.root_bound and now.canonical or now.path
	if grant.granted_path ~= authorised then
		return false
	end
	if compare_owner then
		if grant.session_id ~= now.session_id or grant.turn_id ~= now.turn_id then
			return false
		end
	end
	return true
end

--- Does the grant already sitting on this change belong to THIS door's attempt?
---
--- A door that finds `_yanad_claim_granted` set may only serve it when it names
--- the same root, rel, absolute path, session and turn the door is about to
--- write. A leftover from an aborted bulk press, or a grant another session
--- won, is not an answer to this attempt: the door re-requests instead.
function M.claim_grant_matches(pass, change)
	if type(change) ~= "table" then
		return false
	end
	return identity_matches(change._yanad_claim_granted, identity_of(pass, change), true)
end

--- True when the structured refusal names a real holder (pid or session_id).
local function has_holder_identity(refusal)
	if type(refusal) ~= "table" then
		return false
	end
	local editor = type(refusal.editor) == "table" and refusal.editor or {}
	if editor.pid ~= nil and tostring(editor.pid) ~= "" then
		return true
	end
	if type(refusal.session_id) == "string" and refusal.session_id ~= "" then
		return true
	end
	return false
end

--- Copy-pasteable way to reach the holding editor. Prefer the recorded
--- servername (never guess /run/user/.../nvim.<pid>.0). Fall back to
--- :YanaRecover. Append nothing when neither is known — a placeholder is worse.
local function open_hint(refusal)
	local editor = type(refusal) == "table" and type(refusal.editor) == "table" and refusal.editor or {}
	local servername = editor.servername
	if type(servername) == "string" and servername ~= "" then
		return "  open it with: nvim --server " .. servername .. " --remote-ui"
	end
	local sid = type(refusal) == "table" and refusal.session_id or nil
	if type(sid) == "string" and sid ~= "" then
		return "  open it with: :YanaRecover " .. sid
	end
	return ""
end

--- Begin the accept-time claim. A granted token is consumed by the existing
--- synchronous applier, immediately before its fingerprint/write sequence.
function M.request_file_claim(pass, change, done)
	if type(change) ~= "table" then
		return false, "change missing for file.claim"
	end
	local root, rel, owner = claim_context(pass, change)
	-- FROZEN BEFORE DISPATCH. Everything this claim will be allowed to authorise
	-- is read from the change HERE, on the caller's own stack, and travels to the
	-- callback as an immutable record. `change` is mutable and the reply is
	-- ASYNCHRONOUS: re-reading it when the daemon answers would let a claim
	-- requested for one file be recorded as authority for another.
	local frozen = identity_of(pass, change)
	-- FAIL CLOSED ON A CONTRADICTORY REQUEST. If the change's absolute path is not
	-- the one (root, rel) derives, there is no single file to claim and the two
	-- comparison chains would each pass while naming different files.
	if not coherent(frozen) then
		return false,
			string.format(
				"refusing to accept %s: it is not the file %s/%s names (%s)",
				tostring(change.path),
				tostring(root),
				tostring(rel),
				tostring(frozen.canonical)
			)
	end
	local held = cached_grant(change, root, rel, owner)
	if held ~= nil then
		done(true, held, nil, nil, frozen)
		return true
	end
	local started, start_err = apply_claims.request_file_claim(root, rel, owner, function(ok, path, description, code, refusal)
		if ok then
			-- The daemon claimed `path`. If that is not the path this request was
			-- frozen for, nothing was claimed for this attempt: refuse rather than
			-- record authority for a file yanad never arbitrated.
			if path ~= frozen.canonical then
				done(
					false,
					string.format(
						"refusing to accept %s: yanad claimed %s, not %s",
						tostring(frozen.path),
						tostring(path),
						tostring(frozen.canonical)
					),
					"claim_path_mismatch",
					nil,
					frozen
				)
				return
			end
			change._yanad_claim_held = {
				root = frozen.root,
				rel = frozen.rel,
				abs = frozen.path,
				path = path,
				session_id = frozen.session_id,
				turn_id = frozen.turn_id,
			}
			done(true, path, nil, nil, frozen)
			return
		end
		local message
		if not has_holder_identity(refusal) then
			-- Client-side failure (no_daemon / timeout): yanad called cb(false, code)
			-- with no refusal table. Do not invent a holder.
			message = string.format(
				"refusing to accept %s: could not check the file claim: %s",
				tostring(change.path),
				tostring(code or "unknown")
			)
		else
			-- Real claim conflict: one holder clause + optional open hint.
			local files = type(refusal) == "table" and refusal.files or {}
			local named = (#files > 0) and table.concat(files, ", ") or tostring(path or change.rel)
			message = string.format(
				"refusing to accept %s: %s is under review in another turn (%s)",
				tostring(change.path),
				named,
				tostring(description or code or "held by another session")
			) .. open_hint(refusal)
		end
		done(false, message, code, refusal, frozen)
	end)
	if not started then
		return false, start_err
	end
	return true
end

--- Record a ONE-SHOT grant, bound to what it authorises.
---
--- `pass` is the door's own claim context (the same object it handed
--- `request_file_claim`). With it the grant freezes root, rel, absolute path,
--- session and turn; without it -- the direct-applier route a test takes when
--- it calls `accept_composed` itself -- the grant is still frozen on rel and
--- absolute path, and says so with `root_bound = false`.
--- The FIRST argument shape is the one product doors use: the immutable record
--- `request_file_claim` froze BEFORE it dispatched, handed back with the reply.
--- It is stored verbatim -- `change` is NOT reread here, because between the
--- request and this callback `change.root`, `change.rel` and `change.path` may
--- all have moved. The daemon-returned `path` must equal that record's canonical
--- path or no grant is recorded at all: yanad claimed some other file.
function M.grant_file_claim(change, token, path, pass, live)
	-- NO CLAIMED PATH, NO GRANT. Every route must say which path was claimed.
	if type(path) ~= "string" or path == "" then
		M.record_file_claim_refusal(change, "claim_path_missing", nil)
		return false
	end
	local id
	if is_frozen_identity(pass) then
		if path ~= pass.canonical or not coherent(pass) then
			M.record_file_claim_refusal(change, "claim_path_mismatch", nil)
			return false
		end
		-- REVALIDATE THE OWNER AGAINST THE LIVE DOOR, at the moment of storing.
		-- The applier deliberately does not compare session (an apply pass's
		-- session names the shadow turn), so if the door's session or turn moved
		-- while the claim was in flight, THIS is the only place it is caught.
		if live ~= nil then
			local _, _, now_owner = claim_context(live, change)
			if now_owner.yanad_session_id ~= pass.session_id or now_owner.turn_id ~= pass.turn_id then
				M.record_file_claim_refusal(change, "claim_owner_changed", nil)
				return false
			end
		end
		id = vim.tbl_extend("force", {}, pass)
		id.root_bound = true
	elseif pass ~= nil then
		id = identity_of(pass, change)
		id.root_bound = true
		if not coherent(id) then
			M.record_file_claim_refusal(change, "claim_path_mismatch", nil)
			return false
		end
	else
		-- UNBOUND DIRECT GRANT: no door context to have frozen a root from, so the
		-- claimed path must be the change's own absolute path -- there is nothing
		-- else it could have been claimed for.
		if path ~= change.path then
			M.record_file_claim_refusal(change, "claim_path_mismatch", nil)
			return false
		end
		id = { root = nil, rel = change.rel, path = change.path, root_bound = false }
	end
	id.token = token
	id.granted_path = path
	change._yanad_claim_granted = id
	change.file_claim = path
	change.shadow_refusal = nil
	return true
end

--- Drop any grant still sitting on this change. Called on every route that
--- leaves an accept WITHOUT reaching the applier -- a bulk abort, a per-file
--- skip -- so a grant taken for that press cannot become a second attempt's
--- authority on a later single-file accept.
function M.clear_file_claim_grant(change)
	if type(change) == "table" then
		change._yanad_claim_granted = nil
	end
end

function M.record_file_claim_refusal(change, code, refusal)
	change._yanad_claim_granted = nil
	-- We do not hold this file: forget any earlier grant so the next door asks
	-- the daemon again rather than serving a claim that was taken from us.
	change._yanad_claim_held = nil
	change.shadow_refusal = type(refusal) == "table" and refusal or { reason_code = code }
end

--- Fail closed unless the async accept funnel granted this exact attempt.
---
--- This check NEVER talks to the daemon. It reads one fact -- did the door that
--- issued this accept already win a `file.claim` for it? -- and answers. Asking
--- here used to mean BLOCKING on an RPC whose own budget is
--- `yanad.timeout_ms + retries * retry_ms + 500` = 7.5s, and a blocking poll
--- freezes the editor: a silent daemon socket froze a routine accept for 7562ms and a
--- three-file `<C-r>` replay for 22643ms, with the user unable to type. Even a
--- HEALTHY daemon cost 387ms per accept. The claim is a QUESTION FOR A DOOR,
--- not for the applier: every door pre-requests it asynchronously and enters
--- this synchronous applier from the request's own callback
--- (`review_lifecycle.finish_session`, `turn_settle`).
---
--- So an ungranted attempt is refused by name, immediately. Never a silent
--- allow, and never a wait.
function M.file_claim_refusal(pass, change)
	if type(change) ~= "table" then
		return "refusing to accept: yanad file.claim was not granted for this attempt"
	end
	local grant = change._yanad_claim_granted
	if grant ~= nil then
		-- CONSUMED EXACTLY ONCE, whatever the verdict: a grant read here is gone,
		-- so neither a success nor a mismatch can be replayed by a second door.
		change._yanad_claim_granted = nil
		if identity_matches(grant, identity_of(pass, change), false) then
			return nil
		end
		M.record_file_claim_refusal(change, "claim_identity_mismatch", nil)
		return "refusing to accept "
			.. tostring(change.path)
			.. ": the yanad file.claim in hand was granted for "
			.. tostring(grant.root_bound and grant.root or "?")
			.. "/"
			.. tostring(grant.rel)
			.. " ("
			.. tostring(grant.path)
			.. "), not for this attempt"
	end
	M.record_file_claim_refusal(change, "claim_not_granted", nil)
	return "refusing to accept "
		.. tostring(change.path)
		.. ": yanad file.claim was not granted for this attempt"
end

--- The pass's durable journal, opened on demand.
---
--- Every caller is on the ACTION side (accept, checkpoint, revert). The first one pays
--- for `diary.begin`; the rest reuse the session. A failure is recorded ON THE PASS --
--- the object being resolved -- before it is returned, so a later predicate can ask
--- "did opening the journal halt?" without re-deriving it from the session that does
--- not exist.
local function ensure_session(pass)
	if pass.diary_session then
		return pass.diary_session
	end
	if not pass.diary_begin then
		local err = "the apply pass carries no way to open its durable journal"
		pass.diary_begin_halted = err
		return nil, err
	end
	local diary_begin = pass.diary_begin
	local turn = pass.shadow_turn
	if turn and turn.home_buffer_capture then
		if type(turn.turn_dir) ~= "string" or turn.turn_dir == "" then
			local err = "buffer-only turn carries no pinned private turn directory"
			pass.diary_begin_halted = err
			return nil, err
		end
		diary_begin = vim.tbl_extend("force", {}, diary_begin, {
			diary_dir = turn.turn_dir .. "/home-buffer-diary",
		})
	end
	local session, berr = diary.begin(diary_begin)
	if not session then
		pass.diary_begin_halted = berr or "opening the durable journal failed"
		return nil, pass.diary_begin_halted
	end
	pass.diary_begin_halted = nil
	pass.diary_session = session
	return session
end

--- The pass's journal if it has already been opened, without opening one.
--- For read-only introspection (`dump`, `journal_rows`): asking what the pass
--- has written must never be the thing that makes it write.
function M.opened_session(pass)
	return pass and pass.diary_session or nil
end

--- The workspace of the root a change belongs to, or the pass's primary.
function M.change_root(pass, change)
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	local root = change and change.root
	if type(root) ~= "string" or root == "" then
		return primary
	end
	return root
end

--- The journal for ONE root, opened on demand.
---
--- The primary root goes through `ensure_session` untouched, so a single-root
--- pass -- and every pass built by hand, which carries `diary_session` and no
--- `diary_begin` at all -- behaves exactly as before. A declared write root
--- opens its own journal, rooted at itself, the first time an accept on that
--- root reaches this point; a turn whose extra-root changes are all rejected
--- never creates one.
function M.session_for_root(pass, root)
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	if not root or root == "" or primary == nil or root == primary then
		return ensure_session(pass)
	end
	pass.diary_sessions = pass.diary_sessions or {}
	if pass.diary_sessions[root] then
		return pass.diary_sessions[root]
	end
	local session, berr = diary.begin({
		workspace = root,
		stream = pass.diary_begin.stream,
	})
	if not session then
		local err = berr or ("opening the durable journal for " .. root .. " failed")
		pass.diary_begin_halted = err
		return nil, err
	end
	pass.diary_begin_halted = nil
	pass.diary_sessions[root] = session
	return session
end

--- Every journal this pass has actually opened, primary first. Read-only:
--- asking what the pass has written must never be the thing that makes it write.
function M.opened_sessions(pass)
	local out = {}
	if pass and pass.diary_session then
		out[#out + 1] = pass.diary_session
	end
	for _, session in pairs((pass and pass.diary_sessions) or {}) do
		out[#out + 1] = session
	end
	return out
end

function M.ensure_checkpoint(pass, root)
	root = root or (pass.diary_begin and pass.diary_begin.workspace) or nil
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	local is_primary = (primary == nil) or (root == primary)
	if is_primary then
		if pass.checkpoint_started then
			return true
		end
	else
		pass.checkpoints_started = pass.checkpoints_started or {}
		if pass.checkpoints_started[root] then
			return true
		end
	end
	local session, serr = M.session_for_root(pass, root)
	if not session then
		return false, serr
	end
	-- Only THIS root's paths. checkpoint.begin_turn resolves every path inside
	-- its session's workspace and refuses one that is not, so handing it the
	-- whole turn's paths would fail the moment a turn spans two roots.
	local paths = pass.paths
	if root and pass.paths_by_root and pass.paths_by_root[root] then
		paths = pass.paths_by_root[root]
	end
	local cp, err = checkpoint.begin_turn({
		session = session,
		turn_id = pass.turn_id,
		paths = paths,
	})
	if not cp then
		return false, err
	end
	if is_primary then
		pass.checkpoint_started = true
	else
		pass.checkpoints_started[root] = true
	end
	return true
end

return M
