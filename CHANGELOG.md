# Changelog

All notable changes to Yana are documented here. Versions follow Semantic
Versioning.

## Unreleased

### Security

- Removed the ambient-environment toggle that let `yana-turn finish` re-observe
  the workspace after classification instead of trusting the producer's own
  read, reopening the human-save race the fix it replaced had closed. An
  unsafe posture selectable by whatever an environment happens to export is a
  defect wearing a keystroke; the safe path is now the only path,
  unconditionally. A disposable mutation test preserves proof that restoring
  the unsafe behaviour turns the protection red; it is never live code.

## 0.1.0-alpha.1 - 2026-08-19

### Added

- Confined `cursor-agent` turns for ask and inline-edit workflows.
- Inline hunk review with per-hunk and per-file accept/reject decisions.
- Durable apply journal, crash recovery, workspace claims, and review timeline.
- Session resume, parallel panels, prompt queueing, and selection-scoped edits.
- Health diagnostics backed by the same dependency table as the turn preflight.
- Deterministic export, verification, and archive tooling (`scripts/release/`).

### Security

- Direct workspace-writing mode is disabled unless explicitly enabled.
- Confined turns fail closed when their host enforcement cannot be established.
