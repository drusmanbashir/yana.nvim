#!/usr/bin/env bash
# Host command: prove a fresh scripts/release/export.sh tree starts inside
# Docker with a pinned base image + pinned Neovim — without mounting a git
# checkout — then drive six real turns (2× agentic, 2× inline, 2× ask) in
# separate --network=none containers with distinct state roots.
#
# Usage: tests/release/container_smoke.sh [COMMIT]
# Env:
#   YANA_CONTAINER_SMOKE_KEEP=1  keep image after the run (default: remove)
#   YANA_CONTAINER_SMOKE_DOCKER  docker binary (default: docker)
#   TMPDIR / YANA_HEADLESS_TMPDIR  staging root (must be writable)
#
# Exit: 0 PASS, 1 FAIL, 2 SKIP (docker missing / daemon unreachable), 64 usage
set -euo pipefail

root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
commit=${1:-HEAD}
DOCKER=${YANA_CONTAINER_SMOKE_DOCKER:-docker}
dockerfile=$root/tests/release/Dockerfile.container-smoke
inner=$root/tests/release/container_smoke_run.sh
matrix=$root/scripts/release/neovim-matrix.txt

readonly BASE_IMAGE='ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517'
readonly NVIM_VERSION=0.12.4
# Overlay turns need bwrap userns + a real FS under /var/yana/scratch.
# Docker's container root is already overlayfs; yana-overlay cannot stack
# another overlay there (same reason tests/distro_gate.sh mounts /state).
readonly TURN_RUN_OPTS=(
	--privileged
	--security-opt label=disable
	--network=none
	--mount type=volume,dst=/var/yana/scratch
)
pin=$root/scripts/release/yana-ui.pin
fetch=$root/scripts/release/fetch-yana-ui.sh

# Red control: host UI / local path must not be able to make this gate pass.
if [[ -n ${YANA_UI_ROOT:-} ]]; then
	echo "CONTAINER SMOKE FAIL: YANA_UI_ROOT is set ($YANA_UI_ROOT); public Docker proof forbids host UI" >&2
	exit 1
fi

if ! command -v "$DOCKER" >/dev/null 2>&1; then
	echo "CONTAINER SMOKE: SKIPPED — docker binary missing" >&2
	exit 2
fi
if ! "$DOCKER" info >/dev/null 2>&1; then
	echo "CONTAINER SMOKE: SKIPPED — docker daemon unreachable" >&2
	exit 2
fi

[[ -f $dockerfile && -f $inner && -f $matrix && -f $pin && -x $fetch ]] || {
	echo "CONTAINER SMOKE FAIL: missing Dockerfile, run script, neovim-matrix.txt, yana-ui pin or fetch script" >&2
	exit 1
}
# Dockerfile must not COPY a host yana-ui tree.
if grep -E 'COPY[[:space:]].*yana-ui|COPY[[:space:]].*YANA_UI' "$dockerfile"; then
	echo "CONTAINER SMOKE FAIL: Dockerfile copies host yana-ui (public fetch required)" >&2
	exit 1
fi
read -r ui_url ui_commit _ <"$pin"

nvim_url=
nvim_sha=
while read -r ver url sha _; do
	[[ -n $ver && $ver != \#* ]] || continue
	if [[ $ver == "$NVIM_VERSION" ]]; then
		nvim_url=$url
		nvim_sha=$sha
		break
	fi
done <"$matrix"
[[ -n $nvim_url && -n $nvim_sha ]] || {
	echo "CONTAINER SMOKE FAIL: neovim-matrix.txt has no $NVIM_VERSION row" >&2
	exit 1
}

tmp=${YANA_HEADLESS_TMPDIR:-${TMPDIR:-/tmp}}
work=$(mktemp -d "$tmp/yana-container-smoke.XXXXXX")
image=yana-release-container-smoke:$(date -u +%Y%m%dT%H%M%SZ)-$$
keep=${YANA_CONTAINER_SMOKE_KEEP:-0}

cleanup() {
	local rc=$?
	if [[ $keep != 1 ]]; then
		"$DOCKER" rmi -f "$image" >/dev/null 2>&1 || true
	else
		echo "CONTAINER SMOKE: keeping image $image (YANA_CONTAINER_SMOKE_KEEP=1)" >&2
	fi
	rm -rf "$work"
	exit "$rc"
}
trap cleanup EXIT

echo "CONTAINER SMOKE: base=$BASE_IMAGE nvim=v$NVIM_VERSION commit=$(git -C "$root" rev-parse "$commit") yana-ui=$ui_url@$ui_commit"
"$root/scripts/release/export.sh" "$commit" "$work/export"
# Build context = export + inner runner only (no Yana checkout, no yana-ui bytes).
if [[ -e $work/yana-ui || -e $work/export/.git ]]; then
	echo "CONTAINER SMOKE FAIL: build context leaked host UI or .git" >&2
	exit 1
fi
test -f "$work/export/tests/release/container_six_turns.lua"
test -x "$work/export/tests/release/six_turns_agent" || chmod 755 "$work/export/tests/release/six_turns_agent"
cp -a "$inner" "$work/container_smoke_run.sh"
cp -a "$dockerfile" "$work/Dockerfile"
"$DOCKER" build \
	--build-arg "BASE_IMAGE=$BASE_IMAGE" \
	--build-arg "NVIM_VERSION=$NVIM_VERSION" \
	--build-arg "NVIM_URL=$nvim_url" \
	--build-arg "NVIM_SHA256=$nvim_sha" \
	-t "$image" \
	"$work"

echo "CONTAINER SMOKE: positive run"
"$DOCKER" run --rm --network=none "$image" positive >"$work/positive.log" 2>&1
cat "$work/positive.log"
grep -q 'ALL PASS: yana release smoke' "$work/positive.log" || {
	echo "CONTAINER SMOKE FAIL: positive run missing release-smoke ALL PASS" >&2
	exit 1
}
grep -q 'CONTAINER SMOKE POSITIVE PASS' "$work/positive.log" || {
	echo "CONTAINER SMOKE FAIL: positive run missing POSITIVE PASS line" >&2
	exit 1
}

echo "CONTAINER SMOKE: negative control (empty packpath must refuse require('yana'))"
"$DOCKER" run --rm --network=none "$image" negative >"$work/negative.log" 2>&1
cat "$work/negative.log"
grep -q 'CONTAINER SMOKE NEGATIVE PASS' "$work/negative.log" || {
	echo "CONTAINER SMOKE FAIL: negative control did not pass" >&2
	exit 1
}

# --- Six turns: three separate containers, three state roots, network none ---
declare -A state_roots=()
for turn_mode in agentic inline ask; do
	echo "CONTAINER SMOKE: six-turns mode=$turn_mode (dedicated container)"
	set +e
	"$DOCKER" run --rm "${TURN_RUN_OPTS[@]}" "$image" "turns-$turn_mode" \
		>"$work/turns-$turn_mode.log" 2>&1
	turn_rc=$?
	set -e
	cat "$work/turns-$turn_mode.log" || true
	[[ $turn_rc == 0 ]] || {
		echo "CONTAINER SMOKE FAIL: six-turns container exited $turn_rc for $turn_mode" >&2
		exit 1
	}
	grep -qF "SIX-TURNS PASS mode=$turn_mode" "$work/turns-$turn_mode.log" || {
		echo "CONTAINER SMOKE FAIL: six-turns missing PASS for $turn_mode" >&2
		exit 1
	}
	grep -qF 'PASS: zero yanad survivors' "$work/turns-$turn_mode.log" || {
		echo "CONTAINER SMOKE FAIL: six-turns missing zero-yanad assertion for $turn_mode" >&2
		exit 1
	}
	sr=$(awk '/^STATE_ROOT mode='"$turn_mode"' /{print $3; exit}' "$work/turns-$turn_mode.log")
	[[ -n $sr ]] || {
		echo "CONTAINER SMOKE FAIL: missing STATE_ROOT marker for $turn_mode" >&2
		exit 1
	}
	state_roots[$turn_mode]=$sr
done

# Distinct state roots across modes (no cross-mode reuse).
if [[ ${state_roots[agentic]} == "${state_roots[inline]}" \
	|| ${state_roots[agentic]} == "${state_roots[ask]}" \
	|| ${state_roots[inline]} == "${state_roots[ask]}" ]]; then
	echo "CONTAINER SMOKE FAIL: modes shared a state root: ${state_roots[*]}" >&2
	exit 1
fi
echo "SIX-TURNS STATE ROOTS DISTINCT agentic=${state_roots[agentic]} inline=${state_roots[inline]} ask=${state_roots[ask]}"

# Explicit aggregate assertion the operator greps.
grep -qF 'SIX-TURNS PASS mode=agentic' "$work/turns-agentic.log"
grep -qF 'SIX-TURNS PASS mode=inline' "$work/turns-inline.log"
grep -qF 'SIX-TURNS PASS mode=ask' "$work/turns-ask.log"
echo "SIX-TURNS PASS total=6 modes=agentic,inline,ask turns_per_mode=2"

# Red control: deliberate cross-mode state reuse must FAIL.
echo "CONTAINER SMOKE: red control turns-cross-mode-reuse (must fail)"
set +e
"$DOCKER" run --rm "${TURN_RUN_OPTS[@]}" "$image" turns-cross-mode-reuse \
	>"$work/turns-cross.log" 2>&1
cross_rc=$?
set -e
cat "$work/turns-cross.log"
[[ $cross_rc != 0 ]] || {
	echo "CONTAINER SMOKE FAIL: cross-mode reuse control stayed green" >&2
	exit 1
}
grep -qF 'TURNS CROSS-MODE REUSE FAIL' "$work/turns-cross.log" || {
	echo "CONTAINER SMOKE FAIL: cross-mode reuse control red for the wrong reason" >&2
	exit 1
}
echo "PASS: cross-mode reuse control stayed red"

printf 'CONTAINER SMOKE PASS image_base=%s nvim=v%s commit=%s six_turns=6\n' \
	"$BASE_IMAGE" "$NVIM_VERSION" "$(git -C "$root" rev-parse "$commit^{commit}")"
