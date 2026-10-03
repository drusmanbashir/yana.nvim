-- Pure projection owner: final bytes, existence and mode for one reviewed file.
-- F-APPLY-JOURNAL: one calculation; missing original bytes are an error; the
-- mode verdict alone authorises a mode. No IO, no callbacks, no shared
-- state, no buffer mutation, no classifier call, no tree rescan. `compute` reads
-- its input and returns a fresh table; it never writes through the input.
-- Mode VALUES are carried and compared, never parsed or formatted (F-TRL01B-02).
local M = {}

-- One physical line plus the literal terminator that followed it, so that CRLF,
-- LF and a missing final newline survive a round trip byte for byte.
local function split_records(bytes)
	local records, index, size = {}, 1, #bytes
	while index <= size do
		local stop = string.find(bytes, "\n", index, true)
		if stop == nil then
			records[#records + 1] = { text = string.sub(bytes, index), eol = "" }
			break
		end
		local text, eol = string.sub(bytes, index, stop - 1), "\n"
		if string.sub(text, -1) == "\r" then
			text, eol = string.sub(text, 1, -2), "\r\n"
		end
		records[#records + 1] = { text = text, eol = eol }
		index = stop + 1
	end
	return records
end

-- The terminator inserted lines inherit when no replaced line supplies one.
local function default_eol(...)
	for _, records in ipairs({ ... }) do
		for _, record in ipairs(records) do
			if record.eol ~= "" then return record.eol end
		end
	end
	return "\n"
end

local function join_records(records, fallback_eol)
	local out, last = {}, #records
	for index = 1, last do
		local record = records[index]
		local eol = record.eol
		-- Only the final line may carry no terminator.
		if index < last and eol == "" then eol = fallback_eol end
		out[#out + 1] = record.text .. eol
	end
	return table.concat(out)
end

-- Replace `count` entries of `list` starting at `first` with `items`, returning a
-- new list. The input list is never written through.
local function splice(list, first, count, items)
	local out = {}
	for index = 1, first - 1 do out[#out + 1] = list[index] end
	for _, item in ipairs(items) do out[#out + 1] = item end
	for index = first + count, #list do out[#out + 1] = list[index] end
	return out
end

-- Hunks in descending start order, so each splice leaves earlier starts valid.
local function ordered(hunks, key)
	local picked = {}
	for index, hunk in ipairs(hunks) do
		picked[#picked + 1] = { hunk = hunk, index = index, start = key(hunk) }
	end
	table.sort(picked, function(a, b)
		if a.start ~= b.start then return a.start > b.start end
		return a.index > b.index
	end)
	return picked
end

local function any_accepted(hunks)
	for _, hunk in ipairs(hunks) do
		if hunk.verdict == "accepted" then return true end
	end
	return false
end

local EOL = { dos = "\r\n", mac = "\r", unix = "\n" }

-- The live buffer already shows every accepted side and every independent human
-- line; only a hunk the human did not accept is reverted to its original side.
local function compose_from_buffer(buffer, hunks)
	local lines = {}
	for index, line in ipairs(buffer.lines or {}) do lines[index] = line end
	for _, entry in ipairs(ordered(hunks, function(hunk)
		return hunk.span and hunk.span.first or 0
	end)) do
		local hunk = entry.hunk
		if hunk.verdict ~= "accepted" then
			local span = hunk.span
			if span and span.unplaced then
				return nil, "hunk " .. tostring(hunk.id) .. " " .. tostring(span.reason)
			end
			if span == nil or span.first == nil or span.last == nil then
				return nil, "hunk " .. tostring(hunk.id) .. " has no resolved buffer span"
			end
			if not span.restored then
				lines = splice(lines, span.first, span.last - span.first + 1, hunk.old_lines or {})
			end
		end
	end
	local eol = EOL[buffer.fileformat] or "\n"
	local out = {}
	for index, line in ipairs(lines) do
		out[#out + 1] = line
		if index < #lines or buffer.endofline ~= false then out[#out + 1] = eol end
	end
	local bytes = table.concat(out)
	if buffer.bomb == true then bytes = "\239\187\191" .. bytes end
	return lines, bytes
end
-- The follow-up's comparison view `C` is this composition, reused as is
-- (plan followup-addendum-turn.md "### Reuse and object rules"; turn/turn_cycle.lua).
M.compose_from_buffer = compose_from_buffer

-- Each hunk's PROPOSAL-side start, from stable original coordinates only: its
-- original-side start shifted by the line-count deltas of every hunk ahead of it
-- in (old_start, member order), whatever the verdicts, because the proposal is
-- the full diff. Never a live buffer row. It indexes the proposal's own records
-- for line endings only, never a location to write. Keyed by `descending` entry.
local function proposal_starts(descending)
	local starts, delta = {}, 0
	for index = #descending, 1, -1 do
		local entry = descending[index]
		starts[entry] = entry.hunk.old_start + delta
		delta = delta + #(entry.hunk.new_lines or {}) - #(entry.hunk.old_lines or {})
	end
	return starts
end

-- Without a buffer the original side is the base and only accepted hunks move.
local function compose_from_original(original_records, proposal_records, hunks)
	for _, hunk in ipairs(hunks) do
		if hunk.old_start == nil then
			return nil, (hunk.verdict == "accepted" and "accepted " or "")
				.. "hunk " .. tostring(hunk.id) .. " has no old_start"
		end
	end
	local records = original_records
	local fallback = default_eol(original_records, proposal_records)
	-- Descending (old_start, member order): each splice leaves earlier starts
	-- valid, and a shared start keeps the member order the diff built.
	local descending = ordered(hunks, function(hunk) return hunk.old_start end)
	local new_starts = proposal_starts(descending)
	for _, entry in ipairs(descending) do
		local hunk = entry.hunk
		if hunk.verdict == "accepted" then
			local first = hunk.old_start
			local old_lines = hunk.old_lines or {}
			local items = {}
			local new_start = new_starts[entry]
			for index, text in ipairs(hunk.new_lines or {}) do
				local replaced = records[first + index - 1]
				-- Past the original's end the proposal's own line keeps its ending,
				-- so a created file without a final newline stays without one.
				local proposed = replaced == nil
					and proposal_records[new_start + index - 1] or nil
				items[index] = { text = text, eol = replaced and replaced.eol or (proposed and proposed.eol) or fallback }
			end
			records = splice(records, first, #old_lines, items)
		end
	end
	return join_records(records, fallback)
end

-- compute(input) -> {action, bytes, mode, buffer_lines} | nil, reason
function M.compute(input)
	if type(input) ~= "table" then return nil, "projection input is not a table" end
	if input.purpose ~= "exit" then
		return nil, "projection purpose must be exit, got " .. tostring(input.purpose)
	end
	local original, proposal = input.original, input.proposal
	if type(original) ~= "table" then return nil, "projection input has no original side" end
	if type(proposal) ~= "table" then return nil, "projection input has no proposal side" end

	-- :46 — `""` is evidence only for a known creation or an actually empty file.
	local original_bytes
	if original.exists then
		original_bytes = original.bytes
		if type(original_bytes) ~= "string" then
			return nil, "missing original bytes: the original side is not recorded"
		end
	else
		original_bytes = ""
	end

	local hunks = input.hunks or {}
	-- :56 — accepted text or an accepted textless operation both keep content: the
	-- selected version's OWN decisions. Accepted work an earlier cycle's version
	-- carried keeps content too (F-ADDENDUM-CARRY: a missing fresh hunk does not
	-- erase what End owes), but it can only write that text: it never approves
	-- this version's deletion (CORE step 4, End applies accepted changes only).
	local own_accepted = input.operation_verdict == "accepted" or any_accepted(hunks)
	local content_accepted = own_accepted or input.carried == true

	local target_exists
	if proposal.exists == false then
		target_exists = not own_accepted -- a pending or rejected deletion retains the file
	elseif original.exists == false then
		-- A created file has nothing on disk until its content is accepted
			-- no empty file is written for a creation, so an unaccepted one stays absent.
		target_exists = content_accepted
	else
		target_exists = true
	end

	-- :58-60 — the verdict alone selects the mode; the proposed mode is never
	-- read without it. Under keep the mode is the effective accepted one an
	-- earlier cycle carried, else the original; a creation under keep has no
	-- original mode and takes the host's creation permissions.
	local target_mode
	if input.mode_verdict == "allow" then target_mode = proposal.mode
	else target_mode = input.accepted_mode or original.mode end

	local target_bytes, buffer_lines
	if target_exists then
		if type(input.buffer) == "table" then
			local lines, bytes = compose_from_buffer(input.buffer, hunks)
			if lines == nil then return nil, bytes end
			-- A ZERO-BYTE CREATION IS ZERO BYTES. Neovim cannot hold a
			-- zero-line buffer, so an empty file is the single placeholder row
			-- `{ "" }`; with `endofline` set, composing it emits `"" .. "\n"`
			-- and an accepted empty new file lands on disk as one newline.
			--
			-- The placeholder row is indistinguishable from a file that really
			-- does contain just a newline, so this is NOT a general rule about
			-- empty buffers. It is narrowed to the one case that has no other
			-- reading: a CREATION whose proposal is itself zero bytes, still
			-- showing that placeholder. Any human line makes `lines` something
			-- else and every other final-newline path is untouched.
			if original.exists == false
				and proposal.bytes == ""
				and #lines == 1
				and lines[1] == ""
			then
				bytes = ""
			end
			buffer_lines, target_bytes = lines, bytes
		else
			-- A later cycle's hunks index that version's `base`, never the original.
			local base = input.base
			if base == nil and input.versioned then
				return nil, "a later cycle's version has no base text; its hunks need the buffer"
			end
			local bytes, reason = compose_from_original(
				split_records(base or original_bytes),
				split_records(type(proposal.bytes) == "string" and proposal.bytes or ""),
				hunks)
			if bytes == nil then return nil, reason end
			target_bytes = bytes
		end
	elseif type(input.buffer) == "table" then
		buffer_lines = {}
	end

	-- THE ACTION COMES FROM THE DECISIONS. End reads no file bytes to decide
	-- whether to write. The one disk fact is a creation's path, by stat: a creation
	-- that ends absent removes the file only while it is still the operator's own
	-- save of the review buffer (`original.saved`); any other file there is kept
	-- (CORE "Saving is Neovim's", LEDGER N51).
	local action
	if not target_exists then
		action = (original.exists or original.saved == true) and "delete" or "none"
	elseif content_accepted or target_mode ~= original.mode then
		action = "replace"
	else
		action = "none"
	end

	return { action = action, bytes = target_bytes, mode = target_mode, buffer_lines = buffer_lines }
end

return M
