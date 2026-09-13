#!/usr/bin/env bash
# Fetch yana.nvim's one required dependency exactly as an anonymous user would:
# the URL and commit in scripts/release/yana-ui.pin, cloned with no credential
# helper, no global/system git config, no terminal prompt, and a throwaway HOME.
# Used by tests/release/fresh_install.sh and the release container build, so no
# release proof can pass on a host checkout or a private repository.
#
# Usage: fetch-yana-ui.sh DEST   (DEST must not exist)
set -euo pipefail

[[ $# == 1 ]] || { echo "Usage: $0 DEST" >&2; exit 64; }
dest=$1
pin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yana-ui.pin"
[[ -f "$pin" ]] || { echo "fetch-yana-ui: pin missing: $pin" >&2; exit 1; }
read -r url commit _ <"$pin"
[[ ${url:-} =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${commit:-} =~ ^[0-9a-f]{40}$ ]] || {
	echo "fetch-yana-ui: malformed pin (want: https://github.com/OWNER/REPO SHA): $pin" >&2
	exit 1
}
[[ ! -e "$dest" ]] || { echo "fetch-yana-ui: destination exists: $dest" >&2; exit 1; }

anon_home=$(mktemp -d "${TMPDIR:-/tmp}/yana-ui-anon-home.XXXXXX")
trap 'rm -rf "$anon_home"' EXIT
anon_git() {
	env -i PATH=/usr/bin:/bin HOME="$anon_home" LC_ALL=C \
		GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		git "$@"
}

echo "fetch-yana-ui: anonymous clone $url at $commit" >&2
anon_git clone -q --no-checkout "$url" "$dest" >&2 \
	|| { echo "fetch-yana-ui: anonymous clone refused: $url" >&2; exit 1; }
anon_git -C "$dest" checkout -q --detach "$commit" >&2 \
	|| { echo "fetch-yana-ui: pinned commit $commit not found in $url" >&2; exit 1; }
[[ $(anon_git -C "$dest" rev-parse HEAD) == "$commit" \
	&& $(anon_git -C "$dest" config --get remote.origin.url) == "$url" \
	&& -f "$dest/lua/yana_ui/init.lua" ]] || {
	echo "fetch-yana-ui: $dest is not $url at $commit with lua/yana_ui" >&2
	exit 1
}
printf 'fetch-yana-ui: OK %s %s\n' "$url" "$commit" >&2
