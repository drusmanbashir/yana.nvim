-- Size split of turn_cycle.lua: the per-file derivation of one follow-up publication, pure (plan
-- followup-addendum-turn.md "### Reconciliation" steps 3-5 and its truth table, "### M0" run reconciliation
-- (B5 composed maps) and B6 typed lineage; panel rules F-ADDENDUM-PENDING, -ACCEPTED, -REJECTED,
-- -RECOMPUTE, -HISTORY-RUNNING, -FALLBACK). No vim API and no state: rows, ledger facts and recorded splices
-- arrive already read. The only text diffs are the agent's own I -> A edit set (its two versions, as on a first
-- run) and FALLBACK's base-against-result diff; `C` and `T` are never aligned, and equal text never decides
-- identity.
local line_space = require("yana.review_line_space")
local splice = require("yana.hunk_anchor_splice")

local R = {}

local function join(lines)
	if #lines == 0 then return "" end
	return table.concat(lines, "\n") .. "\n"
end

local function same(x, y)
	if #x ~= #y then return false end
	for i = 1, #x do
		if x[i] ~= y[i] then return false end
	end
	return true
end

-- The agent's own edit set I -> A in input rows: first-run block shape, `start_line..end_line` (an insertion
-- has end_line = start_line - 1 and lands before input row start_line), `new_lines` the agent's lines.
function R.edits(input_lines, agent_lines)
	return line_space.build_diff_blocks(join(input_lines), join(agent_lines))
end

----------------------------------------------------------------------
-- B5 composed maps: input rows -> current rows through recorded splices
----------------------------------------------------------------------

-- One recorded splice ({sr, sc, oer, oec, ner, nec}, on_bytes' arguments) as the one position transform's
-- splice; `back` inverts it (old and new ends swap), as a native undo replays it.
local function step_splice(rec, back)
	local s = splice.splice(rec[1], rec[2], rec[3], rec[4], rec[5], rec[6])
	if back then return { sr = s.sr, sc = s.sc, er = s.nr, ec = s.nc, nr = s.er, nc = s.ec } end
	return s
end

-- Where each of `n_input` submit rows stands among the buffer's `n_now` rows after `steps` ({{splices, back}}
-- in walk order: a back step's splices inverted and newest first), each row moved as Neovim moves an
-- `invalidate` point extmark (`hunk_anchor_splice.point`): a row number, or false once consumed. A composition
-- that does not land on the buffer's row count is not this buffer's history: nil, reason.
function R.compose(n_input, n_now, steps)
	local rows, count = {}, n_input
	for r = 1, n_input do rows[r] = r end
	for _, step in ipairs(steps) do
		local list = step.splices
		for k = 1, #list do
			local s = step_splice(list[step.back and #list + 1 - k or k], step.back)
			for r = 1, n_input do
				if rows[r] then rows[r] = splice.point(s, rows[r]) or false end
			end
			count = count + s.nr - s.er
		end
	end
	-- Neovim's mandatory empty row stands for a buffer with no rows left.
	if count ~= n_now and not (count == 0 and n_now == 1) then
		return nil, string.format("the recorded splices give %d rows where the buffer has %d", count, n_now)
	end
	return rows
end

-- Step 3, transport: each agent edit's input rows to the current rows (`rows[r]` = the row input row r stands
-- on now, or false when an edit consumed it). A replacement covers its surviving rows, lines typed between
-- them included (a whole replacement may show agent text over newer human text inside its target); an
-- insertion lands after its surviving upper neighbour, else before its lower one. Regions are half-open [a, b)
-- in current rows; a == b is a zero-width anchor before row a. Unplaceable -> nil, reason.
function R.transport(edits, rows, n_input)
	local out = {}
	for k, e in ipairs(edits) do
		local s, l = e.start_line, e.end_line
		local region
		if l >= s then
			local lo, hi
			for r = s, l do
				local v = rows[r]
				if v then lo, hi = math.min(lo or v, v), math.max(hi or v, v) end
			end
			if not lo then
				return nil, string.format("the agent's edit of input rows %d-%d has no surviving row", s, l)
			end
			region = { a = lo, b = hi + 1 }
		elseif s > 1 and rows[s - 1] then
			region = { a = rows[s - 1] + 1, b = rows[s - 1] + 1 }
		elseif s <= n_input and rows[s] then
			region = { a = rows[s], b = rows[s] }
		elseif s == 1 then
			region = { a = 1, b = 1 }
		else
			return nil, string.format("the agent's insertion before input row %d has no surviving neighbour", s)
		end
		region.kind, region.new, region.edit = "agent", e.new_lines or {}, k
		if out[#out] and region.a < out[#out].b then
			return nil, "the tracked rows of two agent edits cross"
		end
		out[#out + 1] = region
	end
	return out
end

----------------------------------------------------------------------
-- Steps 4-5: structural union, blocks and typed segments
----------------------------------------------------------------------

local function by_position(x, y)
	if x.a ~= y.a then return x.a < y.a end
	return x.b < y.b
end

-- Do two half-open regions share a row, or does an anchor fall strictly inside a span, or do two anchors meet?
-- Touching regions do not overlap: each keeps its own contribution (the duplicate-line counterexample).
local function overlaps(x, y)
	local xz, yz = x.b == x.a, y.b == y.a
	if not xz and not yz then return x.a < y.b and y.a < x.b end
	if xz and yz then return x.a == y.a end
	local span, at = xz and y or x, xz and x.a or y.a
	return span.a < at and at < span.b
end

-- Group the items by actual overlap. Two regions of one kind never overlap (the ledger's owned runs are
-- disjoint, the agent's edits are), so such an overlap is lost tracking, not a merge.
local function groups_of(items)
	table.sort(items, by_position)
	local groups, last = {}, {}
	for _, item in ipairs(items) do
		local prior = last[item.kind]
		if prior and overlaps(prior, item) then
			return nil, "two " .. item.kind .. " regions overlap in the current rows"
		end
		last[item.kind] = item
		local g = groups[#groups]
		if g and overlaps(g, item) then
			g.b = math.max(g.b, item.b)
			g.items[#g.items + 1] = item
		else
			groups[#groups + 1] = { a = item.a, b = item.b, items = { item } }
		end
	end
	return groups
end

-- One side of a group. "agent" is `T`: agent lines over its regions, current rows elsewhere (pending text the
-- agent left stays). "pending" is the prior side, `C`: each pending run's allocated prior text, and the
-- accepted/operator rows elsewhere -- inherited pending contributions removed, operator gaps kept.
local function side(group, view, kind)
	local out, row = {}, group.a
	for _, item in ipairs(group.items) do
		if item.kind == kind then
			for r = row, item.a - 1 do out[#out + 1] = view[r] end
			for _, text in ipairs(kind == "agent" and item.new or item.old) do out[#out + 1] = text end
			row = math.max(row, item.b)
		end
	end
	for r = row, group.b - 1 do out[#out + 1] = view[r] end
	return out
end

-- A pending run survives when the agent's regions leave some of it standing: its contribution stays pending
-- whatever the bytes around it say.
local function survives(group)
	for _, p in ipairs(group.items) do
		if p.kind == "pending" then
			local covered = false
			for _, e in ipairs(group.items) do
				if e.kind == "agent" then
					local whole = p.b > p.a and e.a <= p.a and p.b <= e.b
					local anchor = p.b == p.a and (e.a < p.a and p.a < e.b or (e.a == p.a and e.b == p.a))
					covered = covered or whole or anchor
				end
			end
			if not covered then return true end
		end
	end
	return false
end

local function span(first, count)
	if count > 0 then return { first = first, last = first + count - 1 } end
	return { anchor = first }
end

-- `T`, the review blocks (first-run shape: prior side `old_lines` at `start_line..end_line` in C rows, result
-- side `new_lines` at `new_start_line..new_end_line` in T rows; `prior_origins` names the pending runs and agent
-- edits; no id: a new result mints new ids) and the typed V -> T segments: `unchanged` rows map one to one with
-- their origins carried, `replaced`/`created`/`deleted` are agent regions. The segments alone, read forward or
-- inverted, are the positional map between the current and published endpoints; blocks are C -> T and separate.
local function assemble(view, groups)
	local T, blocks, segments = {}, {}, {}
	local row, c_delta = 1, 0
	local function seg(kind, a, b, first, count, src, dst)
		segments[#segments + 1] = { seg_id = #segments + 1, kind = kind, src = span(a, b - a), dst = span(first, count),
			src_origins = src, dst_origins = dst }
	end
	-- Unchanged rows [a, b): one segment per run of rows with one origin (a pending run's, or operator/accepted).
	local function unchanged(a, b, origin_of, block)
		local start = a
		for r = a, b do
			if r == b or (r > start and origin_of(r) ~= origin_of(start)) then
				if r > start then
					local o = origin_of(start)
					local first = #T + 1
					for x = start, r - 1 do T[#T + 1] = view[x] end
					local src, dst = {}, {}
					if o then src[1], dst[1] = o, o end
					if block then dst[#dst + 1] = block end
					seg("unchanged", start, r, first, r - start, src, dst)
				end
				start = r
			end
		end
	end
	local function none() return nil end
	for _, g in ipairs(groups) do
		unchanged(row, g.a, none)
		local new, old = side(g, view, "agent"), side(g, view, "pending")
		local origins = {}
		for _, item in ipairs(g.items) do
			origins[#origins + 1] = item.kind == "pending" and item.origin or ("agent:" .. tostring(item.edit))
		end
		local block
		if survives(g) or not same(new, old) then
			local start, first = g.a + c_delta, #T + 1
			blocks[#blocks + 1] = { old_lines = old, new_lines = new, start_line = start, end_line = start + #old - 1,
				new_start_line = first, new_end_line = first + #new - 1, prior_origins = origins }
			block = "block:" .. #blocks
		end
		local function origin_of(r)
			for _, item in ipairs(g.items) do
				if item.kind == "pending" and item.a <= r and r < item.b then return item.origin end
			end
			return nil
		end
		local cursor = g.a
		for _, e in ipairs(g.items) do
			if e.kind == "agent" then
				unchanged(cursor, e.a, origin_of, block)
				local src = {}
				for r = e.a, e.b - 1 do
					local o = origin_of(r)
					if o and src[#src] ~= o then src[#src + 1] = o end
				end
				src[#src + 1] = "agent:" .. tostring(e.edit)
				local first = #T + 1
				for _, text in ipairs(e.new) do T[#T + 1] = text end
				local kind = (e.b == e.a and "created") or (#e.new == 0 and "deleted") or "replaced"
				seg(kind, e.a, e.b, first, #e.new, src, block and { block } or {})
				cursor = math.max(cursor, e.b)
			end
		end
		unchanged(cursor, g.b, origin_of, block)
		c_delta = c_delta + #old - (g.b - g.a)
		row = g.b
	end
	unchanged(row, #view + 1, none)
	return T, blocks, segments
end

-- The tracked derivation. `pending` = {{a, b, old, origin}}: owned runs of pending members in current rows,
-- each with its allocated prior text (accepted rows are ordinary text; a rejected region shows its prior
-- text); `regions` from R.transport.
function R.tracked(view, pending, regions)
	local items = {}
	for _, p in ipairs(pending) do
		items[#items + 1] = { kind = "pending", a = p.a, b = p.b, old = p.old, origin = p.origin }
	end
	for _, r in ipairs(regions) do items[#items + 1] = r end
	local groups, why = groups_of(items)
	if not groups then return nil, why end
	local T, blocks, segments = assemble(view, groups)
	return { lines = T, blocks = blocks, segments = segments, coverage = "complete" }
end

-- Map rows through segments: forward (V -> T) or inverted (T -> V); a row in a replaced region maps to nil.
function R.map_row(segments, row, inverted)
	for _, s in ipairs(segments) do
		local from, to = s.src, s.dst
		if inverted then from, to = s.dst, s.src end
		if from.first and from.first <= row and row <= from.last then
			if s.kind == "unchanged" then return to.first + (row - from.first) end
			return nil
		end
	end
	return nil
end

----------------------------------------------------------------------
-- F-ADDENDUM-FALLBACK, rejection-aware
----------------------------------------------------------------------

-- Does agent edit `e` touch input contribution `c` ({first, last}; last < first = a pending deletion anchored
-- before row first)? Rows overlap, or one side's anchor falls strictly inside the other.
local function touches(c, e)
	local s, l, f, z = e.start_line, e.end_line, c.first, c.last
	if l >= s and z >= f then return s <= z and f <= l end
	if z >= f then return f < s and s <= z end
	if l >= s then return s < f and f <= l end
	return s == f
end

local function precedes(e, c)
	if e.end_line >= e.start_line then return e.end_line < c.first end
	return e.start_line <= c.first
end

-- Where each untouched contribution stands in the agent's rows (input rows shifted by the agent edits above it).
local function placed(contributions, edits)
	local out = {}
	for _, c in ipairs(contributions) do
		local touched, delta = false, 0
		for _, e in ipairs(edits) do
			if touches(c, e) then
				touched = true
				break
			end
			if precedes(e, c) then delta = delta + #(e.new_lines or {}) - #(e.old_lines or {}) end
		end
		if not touched then out[#out + 1] = { first = c.first + delta, count = c.last - c.first + 1, c = c } end
	end
	table.sort(out, function(x, y) return x.first < y.first end)
	return out
end

-- Is contribution `c` left untouched by the agent's own edits?
function R.untouched(c, edits)
	for _, e in ipairs(edits) do
		if touches(c, e) then return false end
	end
	return true
end

-- The rejection-aware rule ("### M0" run reconciliation): an input contribution ({first, last, old,
-- verdict_now} in input rows, resolved per surviving piece through recorded split genealogy) rejected during
-- the run and left untouched by the agent's own edits goes back to its prior text in the result; one the agent
-- edited or reintroduced stays. Returns the result rows and `keep`: the result rows of untouched contributions
-- still pending (or unresolved), whose pending origin FALLBACK must not lose.
function R.rejection_aware(agent_lines, contributions, edits)
	local T, keep, row = {}, {}, 1
	for _, p in ipairs(placed(contributions, edits)) do
		if p.c.verdict_now ~= "accepted" and p.first >= row then
			for r = row, p.first - 1 do T[#T + 1] = agent_lines[r] end
			if p.c.verdict_now == "rejected" then
				for _, text in ipairs(p.c.old or {}) do T[#T + 1] = text end
			else
				for r = p.first, p.first + p.count - 1 do
					T[#T + 1] = agent_lines[r]
					keep[#T] = true
				end
			end
			row = p.first + p.count
		end
	end
	for r = row, #agent_lines do T[#T + 1] = agent_lines[r] end
	return T, keep
end

-- Hunks from the retained accepted/operator text (`base_lines`, `C`) and the result, by the first-run fallback
-- (review_open.lua `fallback_blocks`): every unaccepted contribution stays pending, operator rows the result
-- lacks show as pending deletions, no input text is treated as accepted. A known pending origin's rows enter the
-- diff as rows no base text can equal, so equal bytes never fold a pending row into accepted text; the blocks
-- then carry the real rows. One partial V -> T segment names the failure: no positional map is claimed.
function R.fallback(base_lines, agent_lines, contributions, edits, reason, n_view)
	local T, keep = R.rejection_aware(agent_lines, contributions, edits)
	local tagged = {}
	for i, text in ipairs(T) do tagged[i] = keep[i] and ("\1yana pending origin\1" .. i) or text end
	local blocks = require("yana.review_open").fallback_blocks(join(base_lines), join(tagged))
	local dst = {}
	for k, b in ipairs(blocks) do
		local new = {}
		for r = b.new_start_line, b.new_end_line do new[#new + 1] = T[r] end
		b.new_lines, dst[k] = new, "block:" .. k
	end
	local segments = { { seg_id = 1, kind = "replaced", src = span(1, n_view or #base_lines), dst = span(1, #T),
		src_origins = { "fallback" }, dst_origins = dst } }
	return { lines = T, blocks = blocks, segments = segments, coverage = "partial", failure = reason }
end

return R
