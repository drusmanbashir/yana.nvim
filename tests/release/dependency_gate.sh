#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-deps.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

mapfile -t required < <(
	"$nvim" --clean --headless -u NONE -i NONE \
		--cmd "set rtp^=$tree" \
		-c "lua io.write(table.concat(require('yana.dependencies').required_executables('inline'), '\\n') .. '\\n')" \
		-c qa
)

# bwrap_userns_row() (lua/yana/dependencies.lua) probes the kernel by
# actually launching bwrap with a trivial no-op payload, `true`, INSIDE the
# sandbox it builds -- that probe's own PATH is inherited from whatever
# spawned nvim, i.e. the narrowed PATH this harness builds below. `true` is
# not a Yana dependency (it names no package a real install could be missing
# -- every POSIX host ships coreutils), so it does not belong in
# required_executables()'s list; it is an implementation detail of the
# kernel probe, and this harness's job is to keep that probe truthful, not to
# grow the product's own dependency surface for it. Root-caused 2026-08-21
# (order B4 Part B3): omitting it here reproduced
# `bwrap: execvp true: No such file or directory` on the exported tree.
# `type -P`, not `command -v`: true is also a bash BUILTIN, and `command -v`
# reports a builtin by its bare name with no path, which would make the
# symlink below point at itself (ELOOP) instead of at the real external
# binary bwrap's execve actually needs.
true_bin=$(type -P true)
[[ -n "$true_bin" ]] || { echo "dependency gate host lacks true" >&2; exit 2; }

for missing in "${required[@]}"; do
	path="$scratch/path-$missing"
	mkdir -p "$path"
	ln -s "$true_bin" "$path/true"
	for command in "${required[@]}"; do
		[[ "$command" == "$missing" ]] && continue
		resolved=$(command -v "$command")
		[[ -n "$resolved" ]] || { echo "dependency gate host lacks $command" >&2; exit 2; }
		ln -s "$resolved" "$path/$command"
	done
	env -i \
		HOME="$scratch/home-$missing" \
		PATH="$path" \
		RELEASE_MISSING_EXEC="$missing" \
		XDG_CONFIG_HOME="$scratch/config-$missing" \
		XDG_DATA_HOME="$scratch/data-$missing" \
		XDG_STATE_HOME="$scratch/state-$missing" \
		XDG_CACHE_HOME="$scratch/cache-$missing" \
		LC_ALL=C TZ=UTC \
		"$nvim" --clean --headless -u NONE -i NONE \
		--cmd "set rtp^=$tree" -l "$tree/tests/release/dependency_smoke.lua"
done

optional_path="$scratch/path-optional"
mkdir -p "$optional_path"
ln -s "$true_bin" "$optional_path/true"
for command in "${required[@]}"; do
	resolved=$(command -v "$command")
	[[ -n "$resolved" ]] || { echo "dependency gate host lacks $command" >&2; exit 2; }
	ln -s "$resolved" "$optional_path/$command"
done
env -i \
	HOME="$scratch/home-optional" \
	PATH="$optional_path" \
	XDG_CONFIG_HOME="$scratch/config-optional" \
	XDG_DATA_HOME="$scratch/data-optional" \
	XDG_STATE_HOME="$scratch/state-optional" \
	XDG_CACHE_HOME="$scratch/cache-optional" \
	LC_ALL=C TZ=UTC \
	"$nvim" --clean --headless -u NONE -i NONE \
	--cmd "set rtp^=$tree" -l "$tree/tests/release/optional_dependencies_smoke.lua"

env -i \
	HOME="$scratch/home-agent" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin" \
	RELEASE_AGENT_SCRATCH="$scratch/moved-agent" \
	XDG_CONFIG_HOME="$scratch/config-agent" \
	XDG_DATA_HOME="$scratch/data-agent" \
	XDG_STATE_HOME="$scratch/state-agent" \
	XDG_CACHE_HOME="$scratch/cache-agent" \
	LC_ALL=C TZ=UTC \
	"$nvim" --clean --headless -u NONE -i NONE \
	--cmd "set rtp^=$tree" -l "$tree/tests/release/agent_path_smoke.lua"

printf 'DEPENDENCY GATE PASS rows=%d\n' "${#required[@]}"
