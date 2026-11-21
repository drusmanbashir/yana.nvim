#!/usr/bin/env bash
# Optional helper for the README "Prerequisites" steps: checks Neovim and the
# agent CLIs and offers to install the MCP tools listed in README.md.
#
# Run as your normal user: Neovim and agent CLIs usually live on that user's
# PATH. Every system command is printed and runs with sudo only after "y".
# Self-contained, so it also works when downloaded on its own.
set -uo pipefail

docs=https://github.com/drusmanbashir/yana.nvim/blob/main/docs/installation.md

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

if ((EUID == 0)); then
	echo "Run this as your normal user; it calls sudo only where needed." >&2
	exit 64
fi
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
	for cmd in "$@"; do say "  sudo $cmd"; done
	confirm || { say "Skipped."; return 1; }
	for cmd in "$@"; do
		# shellcheck disable=SC2086 # each command is a fixed, space-split word list
		sudo $cmd || return 1
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
	for exe in claude:claude codex:codex cursor-agent:cursor grok:grok; do
		backend=${exe#*:}
		exe=${exe%%:*}
		if command -v "$exe" >/dev/null 2>&1; then
			say "ok    $exe (backend = \"$backend\")"
			found=1
		fi
	done
	((found)) && return
	say "need  an agent CLI: Claude Code, Codex, Cursor or Grok. Install one: $docs#system-requirements"
	fail=1
}

install_mcp_dependencies() {
	local cmd tool
	local -a missing=()
	for tool in python3 rg; do
		if command -v "$tool" >/dev/null 2>&1; then
			say "ok    $tool"
		else
			case $tool in
				rg) missing+=(ripgrep) ;;
				*) missing+=("$tool") ;;
			esac
		fi
	done
	if (( ${#missing[@]} == 0 )); then
		return
	fi
	if command -v apt-get >/dev/null 2>&1; then
		cmd="apt-get install -y ${missing[*]}"
	elif command -v dnf >/dev/null 2>&1; then
		cmd="dnf install -y ${missing[*]}"
	elif command -v pacman >/dev/null 2>&1; then
		cmd="pacman -S --needed ${missing[*]/python3/python}"
	else
		say "need  ${missing[*]}: $docs#system-requirements"
		fail=1
		return
	fi
	privileged "$cmd" || fail=1
}

check_neovim
check_agents
if [[ "$(uname -s)" == Darwin ]]; then
	say "note  macOS runs agentic mode only."
else
	install_mcp_dependencies
fi

if ((fail)); then
	say "Some prerequisites still need attention (see 'need' above)."
	exit 1
fi
say "Prerequisites are ready. Continue with the Neovim setup in the README."
