local hunk_identity = require("yana.hunk_identity")
-- The hunk ledger's MEMBERSHIP-LIFECYCLE mutators: load_snapshot, rebuild,
-- split and merge.
--
-- These are METHODS ON THE SAME `Ledger` metatable -- `install` writes them onto the
-- table hunk_ledger.lua builds -- so every caller keeps calling `ledger:rebuild(...)`,
-- `ledger:split(...)` and the rest with the signatures they have always had. This
-- module is never required by anyone but hunk_ledger.lua.
--
-- Grouped by what they share: each one REPLACES MEMBERSHIP (the hunk list
-- itself) rather than a field on one hunk, each one drops `last_batch`, and the
-- three that change the pending COUNT log `hunk_ledger.membership`.
--
-- Pure bookkeeping, same as its parent: no vim APIs, no diffing, no repaint.
local log = require("yana.log")

local M = {}

--- install(Ledger, helpers) -- helpers are hunk_ledger.lua's own file-locals:
--- assert_open, index_of, signal_dirty, rebuild_reasons. They
--- are passed in rather than duplicated so there is exactly one definition
--- of each.
function M.install(Ledger, helpers)
	local assert_open = helpers.assert_open
	local index_of = helpers.index_of
	local signal_dirty = helpers.signal_dirty
	local REBUILD_REASONS = helpers.rebuild_reasons

	-- `U` must not replay decisions or reconstruct from live fragments.
	function Ledger:load_snapshot(blocks)
		assert_open(self, "load_snapshot")
		if type(blocks) ~= "table" then
			error("hunk_ledger: load_snapshot takes a block list", 2)
		end
		self.hunks = blocks
		self.last_batch = nil
		for _, block in ipairs(self.hunks) do
			block.initial_new_count = block.initial_new_count or #(block.new_lines or {})
			if block.verdict == nil then
				block.verdict = "pending"
			end
			self:seed_row_owners(block, true)
		end
		signal_dirty(self)
	end

	-- ONE MAPPING, OLD HUNK TO NEW, AND IT DRIVES BOTH ANSWERS: which name the
	-- new block carries, and which verdict. It is built from `rebuild_ancestor`
	-- (the owner's explicit statement) and the model index, and from nothing
	-- else -- see the lineage block inside the loop. A decided hunk that the
	-- mapping never names is retained, spliced in buffer order (A4).
	--
	-- VERDICT USED TO HAVE ITS OWN, WIDER MAPPING, keyed on the concatenated
	-- old_lines/new_lines. It was the same manufactured identity the lineage
	-- carrier had already lost, only louder: an unrelated block that happens to
	-- propose the same bytes at row 40 came out of a rebuild `rejected` because
	-- a hunk at row 2 had been rejected, while the very same call correctly
	-- refused it that hunk's NAME (probe `VERDICT_BY_BYTES row40_verdict=rejected
	-- row40_lineage_eq_row2=false`). A wrong verdict is a silent wrong decision
	-- on the user's code, so bytes now decide neither.
	function Ledger:rebuild(new_blocks, reason)
		if not REBUILD_REASONS[reason] then
			error("hunk_ledger: invalid rebuild reason: " .. tostring(reason), 2)
		end
		assert_open(self, "rebuild")
		if type(new_blocks) ~= "table" then
			error("hunk_ledger: rebuild takes a list of built, stamped blocks", 2)
		end
		local pending_before = self:count()
		-- Keyed on EVERY hunk this ledger holds, decided or not: an index means
		-- the same hunk on both sides whatever its verdict, and the verdict a
		-- pending ancestor hands over is "pending" anyway.
		local lineage_by_model = {}
		for _, block in ipairs(self.hunks) do
			if block.model_index ~= nil then
				lineage_by_model[block.model_index] = block
			end
		end
		local seen_model = {}
		local matched = {}
		for _, block in ipairs(new_blocks) do
			if block.model_index ~= nil then
				if seen_model[block.model_index] then
					error("hunk_ledger: duplicate model_index in rebuild geometry: " .. tostring(block.model_index), 2)
				end
				seen_model[block.model_index] = true
			end
			-- LINEAGE CROSSES THE REBUILD BY NAME, NEVER BY BYTES. A rebuild
			-- re-derives THIS buffer's geometry and hands back new tables for
			-- hunks that mostly already exist; a recorded frame names the old
			-- table, so the name has to travel to the new one or every reversal
			-- taken before a rebuild becomes unresolvable. There are exactly TWO
			-- carriers, and neither reads a byte:
			--   * `block.rebuild_ancestor` -- the EXPLICIT mapping the rebuild
			--     owner supplies, hunk by hunk, because it is the only party
			--     that knows which old hunk each new one continues (see
			--     review_turn.lua's applier-refusal rebuild).
			--   * the model index, when the new block has one: it is assigned
			--     from the immutable model mirror and means the same hunk on
			--     both sides.
			-- CONTENT USED TO BE A THIRD, and it manufactured names: a rebuild
			-- that hands back an unrelated block proposing the same bytes took
			-- the dead hunk's lineage and a recorded frame then restored into a
			-- stranger (probe `REBUILD_BY_BYTES inherited=lin-1`). Bytes may
			-- validate a name (`hunk_identity.looks_like`); they may never make
			-- one. A block with no ancestor here is a new hunk and is stamped
			-- as one.
			local ancestor = block.rebuild_ancestor
				or (block.model_index ~= nil and lineage_by_model[block.model_index])
				or nil
			-- One-shot: the mapping describes THIS rebuild and must not be read
			-- again by the next one, which has its own owner and its own answer.
			block.rebuild_ancestor = nil
			-- THE SAME ancestor answers the verdict question. A block with no
			-- ancestor is a new hunk: new name, and pending, whatever it looks
			-- like. A block that already sits on this ledger (the split children
			-- review_turn hands back as themselves) keeps the verdict it has.
			if ancestor then
				matched[ancestor] = true
				if ancestor ~= block then
					block.verdict = ancestor.verdict
				end
			elseif not index_of(self.hunks, block) then
				block.verdict = "pending"
			end
			hunk_identity.inherit(block, ancestor)
			hunk_identity.stamp(block)
		end
		local result = {}
		for _, block in ipairs(new_blocks) do
			result[#result + 1] = block
		end
		for _, block in ipairs(self.hunks) do
			if block.verdict ~= "pending" and not matched[block] and not index_of(result, block) then
				local at = #result + 1
				for i, placed in ipairs(result) do
					if (placed.new_start_line or math.huge) > (block.new_start_line or 0) then
						at = i
						break
					end
				end
				table.insert(result, at, block)
			end
		end
		self.hunks = result
		for _, block in ipairs(self.hunks) do
			self:seed_row_owners(block, true)
		end
		self.last_batch = nil
		signal_dirty(self)
		local pending_after = self:count()
		if pending_before ~= pending_after then
			local model_indices = {}
			for _, block in ipairs(new_blocks) do
				model_indices[#model_indices + 1] = block.model_index
			end
			log.lifecycle_info("hunk_ledger.membership", {
				mutator = "rebuild",
				reason = reason,
				pending_before = pending_before,
				pending_after = pending_after,
				model_indices = model_indices,
			})
		end
	end

	-- Splits ONE pending hunk into several. Verdict-preserving
	-- (pending in, pending out); children are spliced at the parent's list
	-- position, in the ascending buffer order the caller already sorted them
	-- into; children must NOT inherit the parent's model_index (`rebuild` raises
	-- on a duplicate), so they carry `model_index = nil`, a name of their own
	-- (`lineage_id`) and the recorded genealogy back to the parent. Pure
	-- bookkeeping: no vim APIs, no repaint.
	function Ledger:split(block, children)
	  assert_open(self, "split")
	  local idx = index_of(self.hunks, block)
	  if not idx then
	    error("hunk_ledger: split on a hunk this ledger does not own", 2)
	  end
	  if block.verdict ~= "pending" then
	    error("hunk_ledger: split on a non-pending hunk", 2)
	  end
	  if type(children) ~= "table" or #children == 0 then
	    error("hunk_ledger: split needs at least one child", 2)
	  end
	  local pending_before = self:count()
	  local parent_model_index = block.model_index
	  local result = {}
	  for i = 1, idx - 1 do
	    result[#result + 1] = self.hunks[i]
	  end
	  for _, child in ipairs(children) do
	    child.initial_new_count = child.initial_new_count or #(child.new_lines or {})
	    -- A split child is a NEW hunk, not the parent under another name, so it
	    -- is stamped rather than made to inherit: two children that happen to
	    -- propose the same bytes must still be two different hunks.
	    hunk_identity.stamp(child)
	    child.model_index = nil
	    -- THE GENEALOGY, RECORDED WHERE IT IS KNOWN. A child leaves this function
	    -- with no model index and a content key that is a SUBSET of the parent's, so
	    -- from here on nothing downstream can say which hunk it was carved out of --
	    -- and a rebuild handed the model's whole hunk back (an applier refusal) would
	    -- drop the children and orphan every recorded frame that names them. These
	    -- two fields are the only link, and they are written at the one place that
	    -- still holds both tables. They record the parent's NAME, never its bytes.
	    child.split_parent_lineage_id = block.lineage_id
	    child.split_parent_model_index = parent_model_index
	    -- The child is a fresh table (review_hunk_split.lua): with no model_join
	    -- of its own, an accept/reject downstream would log model_index = nil
	    -- with no reason at all. Name the reason here, at the one place that
	    -- knows it dropped.
	    child.model_join = "lost_at_split"
	    child.verdict = "pending"
	    result[#result + 1] = child
	  end
	  for i = idx + 1, #self.hunks do
	    result[#result + 1] = self.hunks[i]
	  end
	  self.hunks = result
	  -- THE PARENT'S BAND IS THIS TRANSITION'S BUSINESS, and this is the one
	  -- place that knows the split consumed it. A split parent is neither
	  -- absorbed (the edit landed on the children) nor moved by `shift_span`, so
	  -- the recorder that writes absolute pre-edit bands never saw it and the
	  -- transition carried NO frame for it at all. The undo then merged the
	  -- parent back with the anchors the split had narrowed -- owning row 1 of
	  -- the rows 1-3 it spans -- and the band stopped following its own text.
	  -- A field the record omits is one no reversal can
	  -- restore.
	  --
	  -- This is the case `remember_shifted_geometry` already handles for a
	  -- forward MERGE's parents, so the repair is to put the parent in the moved
	  -- set it belongs to, not to teach the replay a new trick. GEOMETRY-ONLY:
	  -- reversing the split restores the parent's proposal and membership, and
	  -- only its band needs the absolute inverse. Outside a watcher group there
	  -- is no group to note into and this does nothing.
	  local history = self.buffer_history
	  if history and history.note_shifted then
	    history:note_shifted(history.current_group, { block })
	  end
	  for _, child in ipairs(children) do
	    self:seed_row_owners(child)
	  end
	  self.last_batch = nil
	  signal_dirty(self)
	  log.lifecycle_info("hunk_ledger.membership", {
	    mutator = "split",
	    pending_before = pending_before,
	    pending_after = self:count(),
	    parent_model_index = parent_model_index,
	    children = #children,
	  })
	end

	-- Merges several pending hunks (already in ascending buffer order) into one.
	-- Same contract as split, run in reverse: verdict-preserving, no inherited
	-- model_index, pure bookkeeping.
	function Ledger:merge(members, merged)
	  assert_open(self, "merge")
	  if type(members) ~= "table" or #members < 2 then
	    error("hunk_ledger: merge needs at least two members", 2)
	  end
	  local pending_before = self:count()
	  local first_idx = nil
	  local member_set = {}
	  local member_model_indices = {}
	  for _, member in ipairs(members) do
	    local idx = index_of(self.hunks, member)
	    if not idx then
	      error("hunk_ledger: merge on a hunk this ledger does not own", 2)
	    end
	    if member.verdict ~= "pending" then
	      error("hunk_ledger: merge on a non-pending hunk", 2)
	    end
	    member_set[member] = true
	    member_model_indices[#member_model_indices + 1] = member.model_index
	    if first_idx == nil or idx < first_idx then
	      first_idx = idx
	    end
	  end
	  merged.model_index = nil
	  -- Same as a split child: the merged block is a new hunk with its own name.
	  hunk_identity.stamp(merged)
	  merged.initial_new_count = merged.initial_new_count or #(merged.new_lines or {})
	  -- Same reason as split's children (above): the merged block is a fresh
	  -- table too, and would otherwise log model_index = nil unexplained.
	  merged.model_join = "lost_at_merge"
	  merged.verdict = "pending"
	  local result = {}
	  local placed = false
	  for i, existing in ipairs(self.hunks) do
	    if member_set[existing] then
	      if i == first_idx then
	        result[#result + 1] = merged
	        placed = true
	      end
	    else
	      result[#result + 1] = existing
	    end
	  end
	  if not placed then
	    result[#result + 1] = merged
	  end
	  self.hunks = result
	  self:seed_row_owners(merged)
	  self.last_batch = nil
	  signal_dirty(self)
	  log.lifecycle_info("hunk_ledger.membership", {
	    mutator = "merge",
	    pending_before = pending_before,
	    pending_after = self:count(),
	    member_model_indices = member_model_indices,
	    members = #members,
	  })
	  -- Hand the caller the inverse of what we just consumed. `merge` blanks the
	  -- merged block's model_index (:206) and stamps model_join = "lost_at_merge"
	  -- (:210), and takes the members off the list entirely, so nothing downstream
	  -- can reconstruct the membership it destroyed. The record names the PIVOT
	  -- (the slot the merged block took -- the LOWEST member index, so a splice
	  -- back lands on the correct side of the bystander above it), the members it
	  -- consumed BY IDENTITY in ascending order, and each member's pre-merge model
	  -- tag (`Ledger:split`, the reverse primitive, blanks a child's model_index
	  -- and overwrites its model_join, so a record without these cannot restore
	  -- the members it puts back). `try_merge` pushes this onto the undo row; the
	  -- route back is `Ledger:split(merged, record.members)`.
	  local before = {}
	  for i, member in ipairs(members) do
	    before[i] = { model_index = member_model_indices[i], model_join = member.model_join }
	  end
	  return { pivot = first_idx, members = members, before = before }
	end
end

return M
