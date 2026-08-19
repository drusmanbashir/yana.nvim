# Changelog

All notable changes to Yana are documented here. Versions follow Semantic
Versioning.

## Unreleased

## 0.1.0-rc.1 - 2026-08-19

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
