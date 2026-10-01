#!/usr/bin/env bash
# Optional helper for the README "Prerequisites" steps: checks Neovim and the
# agent CLIs, installs Bubblewrap and, on Ubuntu, adds the AppArmor permission
# Bubblewrap needs. Keep its packages and profile in step with README.md.
#
# Run as your normal user: Neovim and agent CLIs usually live on that user's
# PATH. Every system command is printed and runs with sudo only after "y".
# Self-contained, so it also works when downloaded on its own.
set -uo pipefail

docs=https://github.com/drusmanbashir/yana.nvim/blob/main/docs/installation.md
profile_path=/etc/apparmor.d/yana-bwrap
profile='abi <abi/4.0>,
include <tunables/global>
profile yana-bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}'

usage() {
	cat <<'USAGE'
Usage: install-deps.sh [--run]

Checks Yana's prerequisites and offers to install what is missing. Run it as
your normal user; it asks before every sudo command and changes nothing if
you answer no.
USAGE
}

case "${1:-}" in
	-h | --help) usage; exit 0 ;;
	"" | --run) ;;
	*) usage >&2; exit 64 ;;
esac

sudo=(sudo)
((EUID == 0)) && sudo=()
fail=0

say() { printf '%s\n' "$*"; }

# A failed read (no terminal, EOF) answers no.
confirm() {
	local answer=""
	read -r -p "Proceed? [y/N] " answer || answer=""
	[[ "$answer" == [yY] ]]
}

# privileged "CMD ARGS" ... -- shows every command, asks once, runs them in order.
privileged() {
	local cmd
	say "About to run:"
	for cmd in "$@"; do say "  ${sudo[*]:+${sudo[*]} }$cmd"; done
	confirm || { say "Skipped."; return 1; }
	for cmd in "$@"; do
		# shellcheck disable=SC2086 # each command is a fixed, space-split word list
		"${sudo[@]}" $cmd || return 1
	done
}

check_neovim() {
	local version major minor patch
	version=$(nvim --version 2>/dev/null) || version=""
	version=${version%%$'\n'*}
	version=${version#NVIM v}
	IFS=. read -r major minor patch <<<"${version%%[-+]*}"
	if [[ "$major$minor$patch" =~ ^[0-9]+$ ]] \
		&& ((major > 0 || minor > 11 || (minor == 11 && patch >= 2))); then
		say "ok    Neovim $version"
		return
	fi
	say "need  Neovim 0.11.2+ (found: ${version:-none}). Install it: $docs#system-requirements"
	fail=1
}

check_agents() {
	local exe backend found=0
	for exe in claude:claude codex:codex cursor-agent:cursor; do
		backend=${exe#*:}
		exe=${exe%%:*}
		if command -v "$exe" >/dev/null 2>&1; then
			say "ok    $exe (backend = \"$backend\")"
			found=1
		fi
	done
	((found)) && return
	say "need  an agent CLI: Claude Code, Codex or Cursor. Install one: $docs#system-requirements"
	fail=1
}

install_bubblewrap() {
	local cmd
	if command -v bwrap >/dev/null 2>&1 && command -v capsh >/dev/null 2>&1; then
		say "ok    Bubblewrap and capsh"
		return
	fi
	if command -v apt-get >/dev/null 2>&1; then
		cmd="apt-get install -y bubblewrap libcap2-bin"
	elif command -v dnf >/dev/null 2>&1; then
		cmd="dnf install -y bubblewrap libcap"
	elif command -v pacman >/dev/null 2>&1; then
		cmd="pacman -S --needed bubblewrap libcap"
	else
		say "need  the packages that provide bwrap and capsh: $docs#system-requirements"
		fail=1
		return
	fi
	privileged "$cmd"
	if command -v bwrap >/dev/null 2>&1 && command -v capsh >/dev/null 2>&1; then
		say "ok    Bubblewrap and capsh"
	else
		say "need  Bubblewrap and capsh"
		fail=1
	fi
}

bwrap_starts() { bwrap --ro-bind / / --unshare-user true >/dev/null 2>&1; }

allow_bubblewrap() {
	local restrict="" existing tmp
	command -v bwrap >/dev/null 2>&1 || return
	if bwrap_starts; then
		say "ok    Bubblewrap can start its sandbox"
		return
	fi
	read -r restrict 2>/dev/null </proc/sys/kernel/apparmor_restrict_unprivileged_userns
	if [[ "$restrict" != 1 ]]; then
		say "need  Bubblewrap cannot start here (container or kernel setting): $docs#troubleshooting"
		fail=1
		return
	fi
	existing=$(grep -rl /usr/bin/bwrap /etc/apparmor.d/ 2>/dev/null)
	if [[ -n "$existing" && "$existing" != "$profile_path" ]]; then
		say "need  an AppArmor profile for /usr/bin/bwrap already exists:"
		say "$existing"
		say "      Ask your administrator to add 'userns,' to it and reload it with"
		say "      sudo apparmor_parser -r FILE. Do not add a second profile."
		fail=1
		return
	fi
	if [[ -z "$existing" ]]; then
		say "Ubuntu restricts user namespaces. This profile lets Bubblewrap use them:"
		say "$profile"
		tmp=$(mktemp) || { fail=1; return; }
		printf '%s\n' "$profile" >"$tmp"
		privileged "apt-get install -y apparmor" "install -m 0644 $tmp $profile_path" \
			"apparmor_parser -r $profile_path"
		rm -f "$tmp"
	else
		privileged "apparmor_parser -r $profile_path"
	fi
	if bwrap_starts; then
		say "ok    Bubblewrap can start its sandbox"
	else
		say "need  Bubblewrap still cannot start: $docs#troubleshooting"
		fail=1
	fi
}

check_neovim
check_agents
if [[ "$(uname -s)" == Darwin ]]; then
	say "note  macOS runs agentic mode only; Bubblewrap is not needed."
else
	install_bubblewrap
	allow_bubblewrap
fi

if ((fail)); then
	say "Some prerequisites still need attention (see 'need' above)."
	exit 1
fi
say "Prerequisites are ready. Continue with the Neovim setup in the README."
