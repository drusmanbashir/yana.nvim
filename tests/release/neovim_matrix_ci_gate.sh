#!/usr/bin/env bash
# Local, fail-capable gate for the CI "Fresh Neovim matrix" contract, run against
# an export of COMMIT (the shipped files only):
#   - tests/release/neovim_matrix_policy.py: workflow install versions == matrix file
#   - each supported version (0.11.2, 0.12.4): turn_dialog_smoke.lua (the End-turn
#     ask ends a decided turn with no UI; stubs keep their answer), then the full
#     fresh install + turn smoke
#   - 0.10.4: fresh_install --expect-refusal passes, and the bare positive path
#     stays red (control)
#
# Usage: neovim_matrix_ci_gate.sh [COMMIT]   (network: Neovim tarballs, yana-ui.nvim)
# Env: YANA_HEADLESS_TMPDIR (or TMPDIR) outside /tmp, required.
#      YANA_NVIM_CACHE optional dir holding VERSION/nvim-linux-x86_64/bin/nvim.
set -euo pipefail

root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
commit=${1:-HEAD}
tmp=${YANA_HEADLESS_TMPDIR:-${TMPDIR:-}}
case $tmp in
"" | /tmp | /tmp/*)
	echo "neovim_matrix_ci_gate: set YANA_HEADLESS_TMPDIR or TMPDIR outside /tmp (the jail mounts a tmpfs over /tmp)" >&2
	exit 65
	;;
esac
cache=${YANA_NVIM_CACHE:-}
# fresh_install refuses undeclared YANA_* variables; pass only the declared ones.
while IFS= read -r name; do
	case $name in
	YANA_HEADLESS_TMPDIR | YANA_RELEASE_TURN_EVIDENCE) ;;
	*) unset "$name" ;;
	esac
done < <(env | awk -F= '$1 ~ /^YANA_/{print $1}')
mkdir -p "$tmp"
work=$(mktemp -d "$tmp/yana-neovim-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
export YANA_HEADLESS_TMPDIR=$tmp

echo ">>> export $commit"
export_dir=$work/export
"$root/scripts/release/export.sh" "$commit" "$export_dir"

echo ">>> neovim_matrix_policy"
python3 "$export_dir/tests/release/neovim_matrix_policy.py" "$export_dir"

resolve_nvim() {
	local version=$1
	if [[ -n $cache && -x $cache/$version/nvim-linux-x86_64/bin/nvim ]]; then
		printf '%s\n' "$cache/$version/nvim-linux-x86_64/bin/nvim"
		return 0
	fi
	"$export_dir/scripts/release/install-neovim.sh" "$version" "$work/nvim-$version" | tail -1
}

dialog_smoke() {
	local version=$1 bin=$2
	mkdir -p "$work/dialog-$version/home" "$work/dialog-$version/state"
	env -i \
		HOME="$work/dialog-$version/home" \
		PATH="$(dirname "$bin"):/usr/bin:/bin" \
		XDG_STATE_HOME="$work/dialog-$version/state" \
		XDG_CACHE_HOME="$work/dialog-$version/state" \
		LC_ALL=C TZ=UTC \
		"$bin" --clean --headless -u NONE -i NONE \
		-l "$export_dir/tests/release/turn_dialog_smoke.lua" 2>&1 | tee "$work/dialog-$version.log"
	grep -qF 'ALL PASS: turn dialog smoke' "$work/dialog-$version.log"
}

for version in 0.11.2 0.12.4; do
	bin=$(resolve_nvim "$version")
	echo ">>> $version turn dialog smoke"
	dialog_smoke "$version" "$bin"
	echo ">>> $version fresh install positive"
	"$export_dir/tests/release/fresh_install.sh" "$export_dir" "$bin" | tee "$work/$version.log"
	grep -qF 'FRESH INSTALL PASS' "$work/$version.log"
	grep -qF 'FRESH INSTALL TURN SMOKE PASS' "$work/$version.log"
done

echo ">>> 0.10.4 expected refusal"
bin104=$(resolve_nvim 0.10.4)
"$export_dir/tests/release/fresh_install.sh" "$export_dir" "$bin104" --expect-refusal | tee "$work/0.10.4.log"
grep -qF 'FRESH INSTALL REFUSAL PASS' "$work/0.10.4.log"

set +e
"$export_dir/tests/release/fresh_install.sh" "$export_dir" "$bin104" >"$work/red-positive.out" 2>&1
rc=$?
set -e
if ((rc == 0)) || grep -qF 'FRESH INSTALL PASS' "$work/red-positive.out"; then
	echo "NEOVIM MATRIX CI GATE FAIL: fresh_install without --expect-refusal passed on 0.10.4" >&2
	exit 1
fi
echo "CONTROL PASS: 0.10.4 positive path stays red without --expect-refusal (rc=$rc)"

echo "NEOVIM MATRIX CI GATE PASS commit=$(git -C "$root" rev-parse "$commit^{commit}")"
