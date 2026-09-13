#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
tmp=${YANA_HEADLESS_TMPDIR:-${TMPDIR:-/tmp}}
scratch=$(mktemp -d "$tmp/yana-fresh.XXXXXX")
turn_scratch=

preserve_failed_turn_evidence() {
  local evidence=${YANA_RELEASE_TURN_EVIDENCE:-}
  [[ -n "$evidence" && -n "$turn_scratch" && -d "$turn_scratch" ]] || return 0
  mkdir -p "$evidence"
  printf 'turn_rc=%s\nscratch=%s\nturn_scratch=%s\n' "${turn_rc:-unset}" "$scratch" "$turn_scratch" >"$evidence/metadata.txt" || true
  if [[ -d "$turn_scratch/ws" ]]; then
    cp -a "$turn_scratch/ws" "$evidence/workspace" 2>/dev/null || true
  fi
  local upper
  upper=$(find "$turn_scratch/state" -type d -path '*/layer/upper' -print -quit 2>/dev/null || true)
  if [[ -n "$upper" ]]; then
    cp -a "$upper" "$evidence/upper" 2>/dev/null || true
  fi
}

# Every yanad this harness starts runs with --root inside one of its own
# mktemp roots, so the process table -- not a pid file -- names what to stop.
# Empty roots are skipped: an empty root would match every yanad on the host.
yanad_pids_under() {
  local root pattern
  for root in "$@"; do
    [[ -n "$root" ]] || continue
    pattern=$(printf '%s' "$root" | sed 's/[][\.*^$+?(){}|]/\\&/g')
    pgrep -f -- "-m yanad --root $pattern/" || true
  done
}

signal_yanad_under() {
  local sig=$1 pid=$2 root cmdline
  shift 2
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 0
  for root in "$@"; do
    [[ -n "$root" && "$cmdline" == *"-m yanad --root $root/"* ]] || continue
    kill "-$sig" "$pid" 2>/dev/null || true
    return 0
  done
}

wait_yanads_gone() {
  local seconds=$1 deadline
  shift
  deadline=$((SECONDS + seconds))
  while [[ -n "$(yanad_pids_under "$@")" ]]; do
    (( SECONDS < deadline )) || return 1
    sleep 0.1
  done
}

# yanad does not exit when its clients do, and during teardown a second
# daemon can take a root's pid file over, so never wait passively and never
# trust one pid-file read: TERM what the process table shows, KILL what
# ignores TERM, then rescan for a daemon that started meanwhile.
stop_yanads_under() {
  local pass pid pids
  for pass in 1 2 3; do
    pids=$(yanad_pids_under "$@")
    [[ -n "$pids" ]] || return 0
    for pid in $pids; do
      signal_yanad_under TERM "$pid" "$@"
    done
    wait_yanads_gone 5 "$@" && continue
    for pid in $(yanad_pids_under "$@"); do
      printf 'fresh install: yanad pid=%s ignored TERM for 5s; sending KILL\n' "$pid" >&2
      signal_yanad_under KILL "$pid" "$@"
    done
    wait_yanads_gone 2 "$@" || {
      printf 'fresh install: yanad survived KILL pids=[%s]\n' "$(yanad_pids_under "$@" | tr '\n' ' ')" >&2
      return 1
    }
  done
  pids=$(yanad_pids_under "$@" | tr '\n' ' ')
  [[ -n "${pids// /}" ]] || return 0
  printf 'fresh install: yanad still starting under harness roots after 3 stop passes pids=[%s]\n' "${pids% }" >&2
  return 1
}

cleanup_fresh_install() {
  local exit_rc=$? shutdown_rc=0 survivors
  preserve_failed_turn_evidence
  stop_yanads_under "$scratch" "$turn_scratch" || shutdown_rc=$?
  survivors=$(yanad_pids_under "$scratch" "$turn_scratch" | tr '\n' ' ')
  if (( shutdown_rc != 0 )) || [[ -n "${survivors// /}" ]]; then
    printf 'FRESH INSTALL CLEANUP FAIL: yanad shutdown rc=%s survivors=[%s]; scratch kept: %s %s\n' \
      "$shutdown_rc" "${survivors% }" "$scratch" "$turn_scratch" >&2
    exit 1
  fi
  rm -rf "$scratch" ${turn_scratch:+"$turn_scratch"}
  exit "$exit_rc"
}
trap cleanup_fresh_install EXIT

while IFS= read -r name; do
	case "$name" in
	YANA_UI_ROOT|YANA_HEADLESS_TMPDIR|YANA_RELEASE_TURN_EVIDENCE) ;;
	*) echo "fresh-install: undeclared YANA_* variable reached the harness" >&2; exit 1 ;;
	esac
done < <(env | awk -F= '$1 ~ /^YANA_/{print $1}')

readonly YANA_UI_COMMIT=c18ee3ed9edd3c865abbc1a9c4c64bf5d9cf8e57
ui_root=${YANA_UI_ROOT:-}
if [[ -n "$ui_root" ]]; then
	ui_root=$(realpath "$ui_root")
fi
if [[ -z "$ui_root" || ! -d "$ui_root" ]]; then
	ui_root="$scratch/yana-ui"
	echo "fresh-install: cloning pinned drusmanbashir/yana-ui $YANA_UI_COMMIT" >&2
	git clone --filter=blob:none https://github.com/drusmanbashir/yana-ui.git "$ui_root" >&2
	git -C "$ui_root" checkout --detach "$YANA_UI_COMMIT" >&2
fi
[[ -d "$ui_root/lua/yana_ui" ]] || {
	echo "fresh-install: yana-ui checkout has no lua/yana_ui package: $ui_root" >&2
	exit 1
}
[[ $(git -C "$ui_root" rev-parse HEAD) == "$YANA_UI_COMMIT" ]] || {
	echo "fresh-install: yana-ui checkout is not pinned to $YANA_UI_COMMIT: $ui_root" >&2
	exit 1
}

home="$scratch/home"
config="$scratch/config"
data="$scratch/data"
state="$scratch/state"
cache="$scratch/cache"
plugin="$data/nvim/site/pack/release/start/yana.nvim"
mkdir -p "$home" "$config/nvim" "$plugin" "$state" "$cache"
cp -a "$tree/." "$plugin/"

env -i \
	HOME="$home" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin" \
	XDG_CONFIG_HOME="$config" \
	XDG_DATA_HOME="$data" \
	XDG_STATE_HOME="$state" \
	XDG_CACHE_HOME="$cache" \
	PYTHONPATH="$plugin/bin/lib" \
	LC_ALL=C TZ=UTC \
	"$nvim" --headless -u NONE -i NONE \
	--cmd "set packpath^=$data/nvim/site" \
	--cmd "set rtp^=$ui_root" \
	--cmd 'packloadall' \
	-l "$plugin/tests/release/smoke.lua"

printf 'FRESH INSTALL PASS nvim=%s root=%s\n' "$($nvim --version | head -1)" "$plugin"

# ---------------------------------------------------------------------------
# TURN SMOKE: setup()+panel-open above proves the export installs and loads,
# but it never submits a prompt, so a runtime module reachable only from
# inside a real turn -- direct require() like lua/yana/agent.lua's
# require("yana.vendor_stream"), or a guarded pcall(require, ...) like
# lua/yana/inline_diff.lua's cross-file undo -- is invisible to it. Drive
# ONE turn against the SAME installed tree ($plugin, not $tree/dev) that
# smoke.lua just proved installs, via tests/release/turn_smoke.lua: hunk
# appears, accept it, undo, assert no Lua error AND that undo actually went
# through yana's own handler rather than silently falling back to Neovim's.
#
# Needs real bwrap confinement (mode=inline), same requirement as
# tests/release/confined_turn_gate.sh: the overlay applies `--tmpfs /tmp`
# while building the sandbox, so a scratch under /tmp binds in empty and the
# turn cannot run. Same resolution order as that gate: an explicit
# YANA_HEADLESS_TMPDIR wins, then a TMPDIR that is itself not under /tmp,
# else refuse rather than hand the overlay a root that cannot work.
if [[ -n ${YANA_HEADLESS_TMPDIR:-} ]]; then
	jail_tmpdir=$YANA_HEADLESS_TMPDIR
elif [[ -n ${TMPDIR:-} && $TMPDIR != /tmp && $TMPDIR != /tmp/* ]]; then
	jail_tmpdir=$TMPDIR
else
	echo "fresh-install: refusing the turn smoke -- overlay workspace root needs YANA_HEADLESS_TMPDIR or a TMPDIR outside /tmp (the jail mounts a fresh tmpfs over /tmp)" >&2
	exit 65
fi
mkdir -p "$jail_tmpdir"
turn_scratch=$(mktemp -d "$jail_tmpdir/yana-fresh-turn.XXXXXX")

set +e
env -i \
	HOME="$home" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin:/usr/sbin:/sbin" \
	XDG_CONFIG_HOME="$config" \
	XDG_DATA_HOME="$data" \
	XDG_STATE_HOME="$state" \
	XDG_CACHE_HOME="$cache" \
	YANA_TURN_SMOKE_SCRATCH="$turn_scratch" \
	PYTHONPATH="$plugin/bin/lib" \
	LC_ALL=C TZ=UTC \
	"$nvim" --clean --headless -u NONE -i NONE \
	--cmd "set rtp^=$plugin" \
	--cmd "set rtp^=$ui_root" \
	-l "$plugin/tests/release/turn_smoke.lua"
turn_rc=$?
set -e

if [[ $turn_rc == 65 ]]; then
	echo "fresh-install: turn smoke INCONCLUSIVE -- bwrap unavailable" >&2
	exit 65
fi
[[ $turn_rc == 0 ]] || exit "$turn_rc"

printf 'FRESH INSTALL TURN SMOKE PASS nvim=%s root=%s\n' "$($nvim --version | head -1)" "$plugin"
