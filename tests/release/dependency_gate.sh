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

for missing in "${required[@]}"; do
	path="$scratch/path-$missing"
	mkdir -p "$path"
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
