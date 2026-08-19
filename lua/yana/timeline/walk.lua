-- Timeline walk — executes a return to an entry. PINNED INTERFACE.
local M = {}

--- What a walk WOULD do, without doing it. The surface shows this before any
--- confirmation, so the operator learns the shape of the walk in advance.
--- @return table plan  { steps = TimelineEntry[], buffer_count = n, durable_count = n, blocked = entry|nil }
function M.plan(workspace, rel, target_id)
	return require("yana.timeline.walk_impl").plan(workspace, rel, target_id)
end

--- Execute. NEWEST-TO-OLDEST, one step at a time, STOP ON FIRST FAILURE.
--- Not atomic, and never reported as if it were: both revert primitives loop and
--- stop at the first conflict. On stopping, report exactly which prefix
--- committed, leave the cursor at the true position, and reconcile buffer
--- against disk.
--- @return table result { committed = TimelineEntry[], stopped_at = entry|nil, reason = string|nil }
function M.execute(workspace, rel, target_id, opts)
	return require("yana.timeline.walk_impl").execute(workspace, rel, target_id, opts)
end

return M
