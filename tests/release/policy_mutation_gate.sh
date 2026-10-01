#!/usr/bin/env bash
# Refuses private files and machine-specific content even when someone adds
# them to the public manifest or puts them in a normally exempt text file.
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

python3 - "$tree" "$scratch" <<'PY'
import json, os, pathlib, subprocess, sys
tree, scratch = map(pathlib.Path, sys.argv[1:])
steps = json.loads((tree / ".github/workflows/release.yml").read_text())["jobs"]["draft"]["steps"]
guard = next((step for step in steps if step.get("name") == "Require successful CI for the tag commit"), None)
assert guard is not None, "release guard missing"
stub_dir = scratch / "ci-stub"
stub_dir.mkdir()
stub = stub_dir / "gh"
stub.write_text('#!/bin/sh\nprintf "%s\\n" "$CI_TEST_RESPONSE"\n')
stub.chmod(0o755)
sha = "1" * 40
cases = {
    "passed": (f"{sha}\tcompleted\tsuccess", True),
    "wrong-commit": (f"{'2' * 40}\tcompleted\tsuccess", False),
    "missing": ("", False),
    "failed": (f"{sha}\tcompleted\tfailure", False),
    "running": (f"{sha}\tin_progress\t", False),
}
for name, (response, accepted) in cases.items():
    env = dict(os.environ, PATH=str(stub_dir) + ":" + os.environ["PATH"],
               GITHUB_SHA=sha, GITHUB_REPOSITORY="example/plugin", CI_TEST_RESPONSE=response)
    result = subprocess.run(["bash", "-c", guard["run"]], env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == accepted, (name, result.stdout, result.stderr)
    if not accepted:
        assert "Release refused:" in result.stderr, (name, result.stderr)
    print(f"CI GUARD PASS: {name}")
PY

stable_tree=$(copy_case stable-control)
printf '%s\n' '0.1.0' >"$stable_tree/VERSION"
escaped_version=$(printf '%s' "$version" | sed 's/[.[\\*^$+?{}|()]/\\&/g')
sed -i "s/$escaped_version/0.1.0/g" "$stable_tree/CHANGELOG.md" "$stable_tree/doc/yana.txt"
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

# Private agent scratch roots must never ship in a public export
# (same class as the operator-home path pattern).
case_tree=$(copy_case agent-rw-path)
priv=/s/agent_
priv+=rw/tmp/private-leak
printf '\nleak: %s\n' "$priv" >>"$case_tree/README.md"
expect_red agent-rw-path "forbidden bytes in README.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

# Account names are arbitrary; rejecting only the developer's username is
# insufficient. SVG and ignore rules are text surfaces of the installed tree.
for surface in README.md .gitignore assets/yana-logo.svg scripts/release/forbidden-patterns.txt; do
	case_name="private-home-${surface//\//-}"
	case_tree=$(copy_case "$case_name")
	private_home=/home/
	private_home+=release-fixture/private-checkout
	printf '\n%s\n' "$private_home" >>"$case_tree/$surface"
	expect_red "$case_name" "forbidden bytes in $surface" \
		"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"
done

# Reordering valid rules must not exempt private paths in the registry itself.
case_tree=$(copy_case private-home-reordered-registry)
registry="$case_tree/scripts/release/forbidden-patterns.txt"
tac "$registry" >"$scratch/reordered-patterns"
cat "$scratch/reordered-patterns" >"$registry"
printf '\n%s\n' "$private_home" >>"$registry"
expect_red private-home-reordered-registry "forbidden bytes in scripts/release/forbidden-patterns.txt" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

# These historical exclusions must remain excluded even after a manifest
# edit. Each fixture otherwise has harmless bytes and exact file membership.
for forbidden in \
	lua/yana/debug_buffer_states.lua \
	lua/yana/debug_buffer_states_bundle.lua \
	nvim/lua/user/yana.lua \
	.github/workflows/tests.yml \
	bin/yana-ollama-agent \
	bin/yana-release \
	docs/repl.md \
	docs/security.md \
	assets/logo/private.svg \
	assets/yana-review-full-still.png \
	assets/yana-review-full.gif \
	assets/yana-review-full.mp4 \
	assets/yana-review-full.take.json \
	assets/yana-review.mp4 \
	assets/yana-review.take.json \
	scripts/release/README.md \
	scripts/release/hpc-smoke-remote.sh \
	scripts/release/manifest_policy.py \
	scripts/release/paths.conf \
	scripts/release/to-release.sh \
	tests/release/candidate_check_gate.sh \
	tests/release/candidate_history_exceptions_gate.sh \
	tests/release/health_yana_ui_smoke.lua \
	tests/release/install_remedy_smoke.lua \
	tests/release/yana_release_preflight_gate.sh \
	prompt.txt; do
	case_name="excluded-${forbidden//\//-}"
	case_tree=$(copy_case "$case_name")
	mkdir -p "$(dirname "$case_tree/$forbidden")"
	printf '%s\n' 'harmless bytes' >"$case_tree/$forbidden"
	LC_ALL=C sort -u -o "$case_tree/scripts/release/manifest.txt" \
		<(cat "$case_tree/scripts/release/manifest.txt"; printf '%s\n' "$forbidden")
	expect_red "$case_name" "manifest path outside the allowed public classes: $forbidden" \
		"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"
done

case_tree=$(copy_case version-drift)
printf '%s\n' '0.1.0-alpha.2' >"$case_tree/VERSION"
expect_red version-drift "help version does not equal VERSION" \
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

case_tree=$(copy_case dead-doc-link)
printf '\nSee [gone](docs/missing-page.md#top).\n' >>"$case_tree/README.md"
expect_red dead-doc-link "dead local link in README.md: docs/missing-page.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case escaping-doc-link)
printf '\nSee [up](../outside.md).\n' >>"$case_tree/README.md"
expect_red escaping-doc-link "local link leaves the exported tree in README.md: ../outside.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

# README's logo is an HTML <img src=...>, not a Markdown link.
case_tree=$(copy_case html-src-dead-link)
printf '\n<img src="assets/missing-logo.svg" alt="gone">\n' >>"$case_tree/README.md"
expect_red html-src-dead-link "dead local link in README.md: assets/missing-logo.svg" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

# The tarball, not the export, is what users unpack: an archive member list
# that drops assets/ ships README image links to nothing.
case_tree=$(copy_case archive-dead-link)
sed -i 's/^\tfind assets /\tfind /' "$case_tree/scripts/release/archive.sh"
mkdir -p "$scratch/archive-dead-link-out"
expect_red archive-dead-link "archive: dead local link in README.md: assets/yana-logo-wide.svg" \
	env SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/archive-dead-link-out"

# Independent of archive.sh's own check: read the built tarball and require
# every local link target of every archived .md to be an archive member.
case_tree=$(copy_case archive-link-closure)
mkdir -p "$scratch/archive-link-closure-out"
SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/archive-link-closure-out" >/dev/null
members="$scratch/archive-link-closure.members"
tar -tzf "$scratch/archive-link-closure-out/yana.nvim-$version.tar.gz" \
	| sed "s#^yana\.nvim-$version/##" | LC_ALL=C sort >"$members"
checked=0
while IFS= read -r doc; do
	while IFS= read -r target; do
		target=${target%%#*}
		case $target in '' | *://* | mailto:*) continue ;; esac
		resolved=$(realpath -m --relative-to=/r "/r/$(dirname "$doc")/$target")
		grep -Fqx -- "$resolved" "$members" || {
			echo "CONTROL FAIL: archived $doc links $target but the archive has no member $resolved" >&2
			exit 1
		}
		checked=$((checked + 1))
	done < <(grep -oE '\]\([^)[:space:]]+\)|src="[^"]+"' "$case_tree/$doc" | sed -E 's/^\]\((.*)\)$/\1/; s/^src="(.*)"$/\1/' || true)
done < <(grep -E '\.md$' "$members")
((checked > 0)) || { echo "CONTROL FAIL: no local links found in archived .md members" >&2; exit 1; }
echo "CONTROL PASS: all $checked local links in archived .md files name archive members"

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

case_tree=$(copy_case missing-ci-guard)
python3 - "$case_tree/.github/workflows/release.yml" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
steps = doc["jobs"]["draft"]["steps"]
steps[:] = [step for step in steps if step.get("name") != "Require successful CI for the tag commit"]
path.write_text(json.dumps(doc))
PY
expect_red missing-ci-guard "release must require exact-commit CI" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case bubblewrap-doc-drift)
sed -i 's/^  userns,$/  network,/' "$case_tree/README.md"
expect_red bubblewrap-doc-drift "Bubblewrap AppArmor profile differs in README.md" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case mode-drift)
chmod 600 "$case_tree/lua/yana/init.lua"
mkdir -p "$scratch/mode-out"
expect_red mode-drift "must be mode 644" \
	env SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/mode-out"

case_tree=$(copy_case yanad-py-executable)
chmod 755 "$case_tree/bin/lib/yanad/__init__.py"
mkdir -p "$scratch/yanad-py-out"
expect_red yanad-py-executable "must be mode 644" \
	env SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/yanad-py-out"

case_tree=$(copy_case overlay-sh-nonexec)
chmod 644 "$case_tree/bin/lib/yana-overlay/yanad.sh"
mkdir -p "$scratch/overlay-sh-out"
expect_red overlay-sh-nonexec "must be mode 755" \
	env SOURCE_DATE_EPOCH=1787170000 "$case_tree/scripts/release/archive.sh" "$case_tree" "$scratch/overlay-sh-out"

echo "POLICY MUTATION GATE PASS"
