#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 ]] || { echo "Usage: $0 EXPORTED_TREE" >&2; exit 64; }
tree=$(realpath "$1")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-policy-mutations.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
version=$(tr -d '\r\n' <"$tree/VERSION")

copy_case() {
	local name=$1
	cp -a "$tree" "$scratch/$name"
	printf '%s\n' "$scratch/$name"
}

expect_red() {
	local name=$1 expected=$2
	shift 2
	local output="$scratch/$name.out"
	if "$@" >"$output" 2>&1; then
		echo "MUTATION FAIL: $name stayed green" >&2
		exit 1
	fi
	grep -Fq "$expected" "$output" || {
		echo "MUTATION FAIL: $name red for the wrong reason" >&2
		sed 's/^/  /' "$output" >&2
		exit 1
	}
	echo "MUTATION PASS: $name -> $expected"
}

legacy_upper=NEO
legacy_upper+=CURSOR

stable_tree=$(copy_case stable-control)
printf '%s\n' '0.1.0' >"$stable_tree/VERSION"
sed -i 's/0\.1\.0-alpha\.1/0.1.0/g' "$stable_tree/CHANGELOG.md" "$stable_tree/doc/yana.txt"
"$stable_tree/scripts/release/verify.sh" "$stable_tree" 'v0.1.0' >/dev/null
echo "CONTROL PASS: stable tag and stable tree agree"

case_tree=$(copy_case missing-pattern)
sed -i "/^${legacy_upper}$/d" "$case_tree/scripts/release/forbidden-patterns.txt"
expect_red missing-pattern "required scanner pattern missing" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case extra-file)
printf '%s\n' 'return {}' >"$case_tree/lua/yana/unlisted.lua"
expect_red extra-file "exported files differ from manifest" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case legacy-bytes)
printf '%s%s\n' neo cursor >>"$case_tree/README.md"
expect_red legacy-bytes "forbidden bytes in README.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case version-drift)
printf '%s\n' '0.1.0-alpha.2' >"$case_tree/VERSION"
expect_red version-drift "CHANGELOG has no dated release heading" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" 'v0.1.0-alpha.2'

case_tree=$(copy_case mutable-action)
sed -i 's/actions\/checkout@[0-9a-f]\{40\}/actions\/checkout@main/' "$case_tree/.github/workflows/ci.yml"
expect_red mutable-action "unpinned or unapproved action" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case gzip-metadata)
sed -i 's/gzip -n -c/gzip -c/' "$case_tree/scripts/release/archive.sh"
mkdir -p "$scratch/gzip-a" "$scratch/gzip-b"
SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/gzip-a" >/dev/null
sleep 1
SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/gzip-b" >/dev/null
if cmp -s "$scratch/gzip-a/yana.nvim-$version.tar.gz" "$scratch/gzip-b/yana.nvim-$version.tar.gz"; then
	echo "MUTATION FAIL: gzip metadata regression stayed byte-identical" >&2
	exit 1
fi
echo "MUTATION PASS: gzip metadata regression changes archive bytes"

case_tree=$(copy_case manifest-smuggle)
smuggle_dir=sp
smuggle_dir+=ec
mkdir -p "$case_tree/$smuggle_dir"
printf '%s\n' 'harmless bytes' >"$case_tree/$smuggle_dir/leak.txt"
LC_ALL=C sort -o "$case_tree/scripts/release/manifest.txt" \
	<(cat "$case_tree/scripts/release/manifest.txt"; printf '%s/leak.txt\n' "$smuggle_dir")
expect_red manifest-smuggle "manifest path outside the allowed public classes" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case nul-bytes)
printf 'wide\0identity\n' >>"$case_tree/README.md"
expect_red nul-bytes "NUL bytes in README.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case job-level-uses)
python3 - "$case_tree/.github/workflows/release.yml" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.loads(open(path).read())
doc["jobs"]["evil"] = {"uses": "attacker/repo/.github/workflows/x.yml@main"}
open(path, "w").write(json.dumps(doc))
PY
expect_red job-level-uses "declares job-level uses" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case secrets-index)
python3 - "$case_tree/.github/workflows/ci.yml" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.loads(open(path).read())
job = next(iter(doc["jobs"].values()))
job["steps"][0].setdefault("env", {})["SNEAK"] = "${{ secrets['DEPLOY_KEY'] }}"
open(path, "w").write(json.dumps(doc))
PY
expect_red secrets-index "references the secrets context" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case job-permissions)
python3 - "$case_tree/.github/workflows/release.yml" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.loads(open(path).read())
job = next(iter(doc["jobs"].values()))
job["permissions"] = {"contents": "write", "id-token": "write"}
open(path, "w").write(json.dumps(doc))
PY
expect_red job-permissions "declares job-level permissions" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case mode-drift)
chmod 600 "$case_tree/lua/yana/init.lua"
mkdir -p "$scratch/mode-out"
expect_red mode-drift "must be mode 644" \
	env SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/mode-out"

echo "POLICY MUTATION GATE PASS"
