#!/usr/bin/env bash
# Top-level release gate: export + reproducible archive + fresh install +
# yana-ui dependency + confined turn + public Docker six-turn proof.
#
# Env:
#   YANA_RELEASE_SKIP_CONTAINER_SMOKE=1  — local bounded runs only; skips the
#     Docker proof. Release/CI must leave this unset. Docker missing while the
#     smoke is required is a FAIL (not a silent skip).
set -euo pipefail

root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
commit=${1:-HEAD}
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "$tmp/yana-release-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Capture gate-local flags, then drop every YANA_* so fresh_install / smoke
# hermeticism is not poisoned by an operator session (YANA_DEV, vendor profile, …).
# fresh_install allowlists only YANA_HEADLESS_TMPDIR and YANA_RELEASE_TURN_EVIDENCE.
skip_container=${YANA_RELEASE_SKIP_CONTAINER_SMOKE:-0}
keep_headless=${YANA_HEADLESS_TMPDIR-}
keep_evidence=${YANA_RELEASE_TURN_EVIDENCE-}
while IFS= read -r name; do
	unset "$name" || true
done < <(env | awk -F= '$1 ~ /^YANA_/ { print $1 }')
[[ -n $keep_headless ]] && export YANA_HEADLESS_TMPDIR=$keep_headless
[[ -n $keep_evidence ]] && export YANA_RELEASE_TURN_EVIDENCE=$keep_evidence

"$root/scripts/release/export.sh" "$commit" "$work/export"
epoch=$(git -C "$root" show -s --format=%ct "$commit")
(umask 022; SOURCE_DATE_EPOCH=$epoch "$work/export/scripts/release/archive.sh" "$work/export" "$work/a")
sleep 1
(umask 077; TZ=Pacific/Auckland SOURCE_DATE_EPOCH=$epoch "$work/export/scripts/release/archive.sh" "$work/export" "$work/b")
cmp "$work/a/yana.nvim-"*.tar.gz "$work/b/yana.nvim-"*.tar.gz
"$work/export/tests/release/fresh_install.sh" "$work/export" "$(command -v nvim)"
"$work/export/tests/release/yana_ui_dependency_gate.sh" "$work/export" "$(command -v nvim)"
DEV_CHECKOUT="$root" "$work/export/tests/release/confined_turn_gate.sh" "$work/export" "$(command -v nvim)"

if [[ $skip_container == 1 ]]; then
	echo "RELEASE GATE: skipping container_smoke (YANA_RELEASE_SKIP_CONTAINER_SMOKE=1 — local bounded run only)" >&2
else
	# Host UI / repo checkout must not contaminate the public Docker proof.
	set +e
	env -u YANA_UI_ROOT -u YANA_REPO_DIR \
		"$root/tests/release/container_smoke.sh" "$commit"
	smoke_rc=$?
	set -e
	if [[ $smoke_rc == 2 ]]; then
		echo "RELEASE GATE FAIL: container_smoke unavailable (docker missing/daemon down); required unless YANA_RELEASE_SKIP_CONTAINER_SMOKE=1" >&2
		exit 1
	fi
	[[ $smoke_rc == 0 ]] || exit "$smoke_rc"
fi

echo "RELEASE GATE PASS"
