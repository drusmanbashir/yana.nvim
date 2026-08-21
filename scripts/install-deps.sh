#!/usr/bin/env bash
# scripts/install-deps.sh -- the one command a fresh clone needs before its
# first confined turn. Checks yana's required system dependencies and prints
# ONE copy-paste install command with real package names for this machine's
# distro; with --run, offers to run it (and the cursor-agent installer)
# after showing the exact command and asking [y/N].
#
# Package-name mapping validated against live Ubuntu 24.04 (apt) and Fedora
# (dnf) containers: packets/freshdep-audit-20260820.md Part 1b. The pacman
# column follows that packet's Part 3 proposal but was NOT run against a
# live Arch machine -- best-effort, not independently verified.
#
# Mirrors the required-executable list in lua/yana/dependencies.lua's
# confined_executables and the same package-name table as its
# EXEC_PACKAGE_HINT -- this script must run standalone, before Neovim (or
# Lua) exists on a fresh clone, so it carries its own copy; keep both in
# sync when either changes. Sqlite3/md5sum (optional session-discovery
# helpers, not preflight blockers) are intentionally not checked here --
# see `:checkhealth yana` for those.
#
# Uses only bash builtins and `command -v` to detect and report -- no
# grep/sed/awk/find, since those are exactly the kind of thing this script
# may be reporting as missing. It never runs apt/dnf/pacman/sudo/curl
# without --run, and never without printing the exact command and getting a
# literal "y" first.
#
# Usage:
#   scripts/install-deps.sh          Check only. Touches nothing.
#   scripts/install-deps.sh --run    Check, then offer to install what's
#                                     missing (sudo package install, and/or
#                                     the cursor-agent curl installer).
#                                     Asks [y/N] before each; never silent.
set -uo pipefail

usage() {
	cat >&2 <<'USAGE'
Usage: scripts/install-deps.sh [--run]

  (no flags)  Check yana's required dependencies and print ONE copy-paste
              install command for whatever is missing on this distro.
              Never touches the system.
  --run       Same check, then offer to run the install command via sudo
              and the cursor-agent installer via curl. Shows the exact
              command and asks [y/N] before each one; never runs silently.
USAGE
}

run=0
case "${1:-}" in
	--run) run=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		usage
		exit 64
		;;
esac

# Required executables for confined-mode turns (ask/inline), mirrored from
# lua/yana/dependencies.lua's confined_executables, PLUS python3: this
# installer runs once, before Neovim (and any config it would read) ever
# loads, so it cannot know whether the operator's config will set
# `inline_exec_allowlist` and make python3 a hard preflight blocker there
# too -- it installs python3 unconditionally rather than have a later config
# change silently need a second install pass.
required=(
	bash bwrap capsh python3 realpath sha256sum flock mount umount find stat
	awk sed grep sort cut tr date hostname getent id mkdir mktemp rmdir chmod
	cp mv rm cat touch readlink dirname basename
)

# exe:apt:dnf:pacman -- a blank field falls back to the exe's own name,
# which is correct for most of the list above (sed, grep, python3, id,
# mkdir, ... really are their own package on every mainstream distro; only
# the rows below are not).
pkg_map='
bwrap:bubblewrap:bubblewrap:bubblewrap
capsh:libcap2-bin:libcap:libcap
flock:util-linux:util-linux:util-linux
mount:util-linux:util-linux:util-linux
umount:util-linux:util-linux:util-linux
find:findutils:findutils:findutils
awk:gawk:gawk:gawk
getent:libc-bin:glibc-common:glibc
hostname:hostname:hostname:inetutils
'

package_for() {
	local exe=$1 distro=$2 e apt dnf pacman field
	while IFS=: read -r e apt dnf pacman; do
		[[ "$e" == "$exe" ]] || continue
		case "$distro" in
			apt) field=$apt ;;
			dnf) field=$dnf ;;
			pacman) field=$pacman ;;
			*) field="" ;;
		esac
		if [[ -n "$field" ]]; then
			printf '%s' "$field"
			return
		fi
	done <<<"$pkg_map"
	printf '%s' "$exe"
}

detect_distro() {
	local id="" id_like="" key value guess=""
	if [[ -r /etc/os-release ]]; then
		while IFS='=' read -r key value; do
			value=${value%\"}
			value=${value#\"}
			case "$key" in
				ID) id=$value ;;
				ID_LIKE) id_like=$value ;;
			esac
		done </etc/os-release
	fi
	local hay=" $id $id_like "
	case "$hay" in
		*" debian "* | *" ubuntu "*) guess=apt ;;
		*" fedora "* | *" rhel "*) guess=dnf ;;
		*" arch "*) guess=pacman ;;
	esac
	if [[ "$guess" == apt ]] && command -v apt-get >/dev/null 2>&1; then
		printf 'apt'
		return
	elif [[ "$guess" == dnf ]] && command -v dnf >/dev/null 2>&1; then
		printf 'dnf'
		return
	elif [[ "$guess" == pacman ]] && command -v pacman >/dev/null 2>&1; then
		printf 'pacman'
		return
	fi
	# os-release didn't say, or lied -- fall back to whichever package
	# manager binary actually exists.
	if command -v apt-get >/dev/null 2>&1; then
		printf 'apt'
	elif command -v dnf >/dev/null 2>&1; then
		printf 'dnf'
	elif command -v pacman >/dev/null 2>&1; then
		printf 'pacman'
	else
		printf 'unknown'
	fi
}

check_missing() {
	missing=()
	for exe in "${required[@]}"; do
		command -v "$exe" >/dev/null 2>&1 || missing+=("$exe")
	done
	if command -v cursor-agent >/dev/null 2>&1; then
		cursor_agent_missing=0
	else
		cursor_agent_missing=1
	fi
}

confirm() {
	local prompt=$1 answer=""
	# Read from stdin, not /dev/tty: this script is run directly from a repo
	# checkout (never curl-piped), so stdin already is the real terminal in
	# ordinary interactive use. A failed or empty read (no terminal attached,
	# EOF) answers "" here, which the caller below treats as decline -- fail
	# closed, never an accidental yes.
	read -r -p "$prompt " answer || answer=""
	[[ "$answer" == "y" || "$answer" == "Y" ]]
}

missing=()
cursor_agent_missing=0
check_missing

if ((${#missing[@]} == 0)) && ((!cursor_agent_missing)); then
	echo "install-deps: all required dependencies are present."
	exit 0
fi

distro=$(detect_distro)
echo "yana: missing required dependencies (detected package manager: $distro)"
echo

pkg_cmd=()
if ((${#missing[@]} > 0)); then
	echo "Missing: ${missing[*]}"
	declare -A seen=()
	pkgs=()
	for exe in "${missing[@]}"; do
		p=$(package_for "$exe" "$distro")
		if [[ -z "${seen[$p]:-}" ]]; then
			pkgs+=("$p")
			seen[$p]=1
		fi
	done
	case "$distro" in
		apt) pkg_cmd=(sudo apt-get install -y "${pkgs[@]}") ;;
		dnf) pkg_cmd=(sudo dnf install -y "${pkgs[@]}") ;;
		pacman) pkg_cmd=(sudo pacman -S --needed "${pkgs[@]}") ;;
		*)
			echo "Distro not recognised automatically -- install the package that provides" \
				"each of the executables above using your package manager, then re-run this script."
			;;
	esac
	if ((${#pkg_cmd[@]} > 0)); then
		echo
		echo "  ${pkg_cmd[*]}"
	fi
	echo
fi

if ((cursor_agent_missing)); then
	echo "cursor-agent is not on PATH. Install it with:"
	echo
	echo "  curl https://cursor.com/install -fsS | bash"
	echo
fi

if ((!run)); then
	echo "Re-run with --run to install the above (asks before every step), or run" \
		"':checkhealth yana' inside Neovim for the full picture."
	exit 1
fi

if ((${#pkg_cmd[@]} > 0)); then
	echo "About to run:"
	echo "  ${pkg_cmd[*]}"
	if confirm "Proceed? [y/N]"; then
		"${pkg_cmd[@]}"
	else
		echo "Skipped."
	fi
fi

if ((cursor_agent_missing)); then
	if command -v curl >/dev/null 2>&1; then
		echo "About to run:"
		echo "  curl https://cursor.com/install -fsS | bash"
		if confirm "Proceed? [y/N]"; then
			curl https://cursor.com/install -fsS | bash
		else
			echo "Skipped."
		fi
	else
		echo "curl not found -- install cursor-agent manually: https://cursor.com/install"
	fi
fi

check_missing
if ((${#missing[@]} == 0)) && ((!cursor_agent_missing)); then
	echo "install-deps: all required dependencies are now present."
	exit 0
fi

still=("${missing[@]}")
((cursor_agent_missing)) && still+=("cursor-agent")
echo "install-deps: still missing: ${still[*]}"
exit 1
