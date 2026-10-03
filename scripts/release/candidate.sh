#!/usr/bin/env bash
set -euo pipefail

# Candidate public repository: build an orphan-root import from an exported
# tree, and check that a candidate remote carries only allowed public history
# (release test YT-13). `check` runs against a local bare repository before
# operator approval and against the GitHub remote after push; it never writes
# to the remote.
#
# Incremental history policy (check):
#   - Advertised refs: HEAD, refs/heads/main, and exact SemVer refs/tags/v…;
#     advertised HEAD SHA must equal refs/heads/main.
#   - Every advertised tag is fetched and must peel to a commit on main;
#     peel VERSION must equal the tag name without v.
#   - main is linear with exactly one root.
#   - HEAD tree paths equal HEAD manifest; verify.sh runs on HEAD.
#   - Per-commit main history (NUL-safe ls-tree): tree paths equal that
#     commit's manifest; each path passes public path policy, except the
#     narrow retired helper bin/yana-ollama-agent (accepted only via that
#     explicit exception, not the bin/yana-* wildcard); every path's blob is
#     checked for NUL, UTF-8, and forbidden bytes (shared blobs re-checked
#     under each path). Listing/read errors fail closed.
#
# Tag modes:
#   default / --allow-untagged-head — HEAD may lack tag v$VERSION.
#   --require-version-tag — annotated tag v$VERSION must exist on main.

usage() {
	printf 'Usage: %s build EXPORTED_TREE BARE_DIR\n' "$0" >&2
	printf '       %s check REMOTE_URL [--allow-untagged-head|--require-version-tag]\n' "$0" >&2
	exit 64
}

fail=0
note_fail() { echo "CANDIDATE FAIL: $*" >&2; fail=1; }

build() {
	local tree bare version
	tree=$(realpath "$1")
	bare=$2
	[[ -f "$tree/VERSION" && -f "$tree/scripts/release/manifest.txt" ]] \
		|| { echo "candidate build: not an exported tree: $tree" >&2; exit 1; }
	[[ ! -e "$tree/.git" ]] || { echo "candidate build: tree already has .git" >&2; exit 1; }
	[[ ! -e "$bare" ]] || { echo "candidate build: output already exists: $bare" >&2; exit 1; }
	version=$(tr -d '\r\n' <"$tree/VERSION")
	"$tree/scripts/release/verify.sh" "$tree" >/dev/null
	git init -q -b main "$tree"
	git -C "$tree" -c user.name="Yana Release" -c user.email="release@invalid" add -A
	git -C "$tree" -c user.name="Yana Release" -c user.email="release@invalid" \
		commit -q -m "Yana v$version initial import"
	[[ -z "$(git -C "$tree" log --format=%P -n 1)" ]] \
		|| { echo "candidate build: import commit has a parent" >&2; exit 1; }
	git init -q --bare -b main "$bare"
	git -C "$tree" push -q "$(realpath "$bare")" main
	printf 'CANDIDATE BUILD PASS version=%s commit=%s bare=%s\n' \
		"$version" "$(git -C "$tree" rev-parse HEAD)" "$bare"
}

semver_tag_ok() {
	[[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]]
}

# Retired files still require tree==manifest. Setup files additionally require
# their exact historical commit/path/blob entry; new occurrences are refused.
retired_history_exception() {
	local path=$1 commit=$2 blob=$3
	[[ "$path" == "bin/yana-ollama-agent" ]] && return 0
	history_exception HISTORY_RETIRED_PATH_EXCEPTIONS "$commit" "$path" "$blob"
}

# Exact legacy-history exceptions. Public main history published before
# 0.1.0-alpha.7 cannot be rewritten without orphaning the v0.1.0-alpha.5 tag.
# Each entry accepts ONE blob at ONE path in ONE commit ("COMMIT PATH BLOB"),
# and never at the advertised HEAD, so a replay in any new commit, a changed
# blob, or a new path still fails. Proven by
# tests/release/candidate_history_exceptions_gate.sh.
#
# Tracked but not in that commit's manifest: the README logos added by
# a7a60922 (docs(readme): logo header) and kept by d3027d89 (revert of the
# withdrawn 0.1.0-alpha.6 publication).
readonly HISTORY_UNMANIFESTED_EXCEPTIONS=(
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c assets/yana-logo.svg c111389fc2f5e15d446ff36e80852402c9c7073f"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c assets/yana-logo-wide.svg 689a82cfe87f042dd661567e9f3841ddb4a54440"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b assets/yana-logo.svg c111389fc2f5e15d446ff36e80852402c9c7073f"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b assets/yana-logo-wide.svg 689a82cfe87f042dd661567e9f3841ddb4a54440"
)
# Forbidden-byte hits: the pre-rename NOTICE whose upstream licence header names
# the forked project, in 42615dbe (relicense), dec5e271 and 32049860.
readonly HISTORY_FORBIDDEN_BYTES_EXCEPTIONS=(
	"42615dbe02aa6b08bbd30e736c429d9abd087430 NOTICE fb18d15a1927efc89409fb6cc77085e0481de172"
	"dec5e27153c63e0529731ac5ba017028ddb0504b NOTICE fb18d15a1927efc89409fb6cc77085e0481de172"
	"320498604b018c62aeb80cc8238e22020f2029f0 NOTICE fb18d15a1927efc89409fb6cc77085e0481de172"
)
# Private-path rules are fingerprinted so their literal prefixes occur only in
# the registry. Exceptions require an exact published commit/path/blob, a
# declared file, and a clean secondary scan with only these rules removed.
readonly PRIVATE_PATH_PATTERN_SHA256S=(
	33a8bc77e3cd8a51c35e64aafe315e4f447abddf693e2d79f0335ae1420d0130
	12846e174cfd4dc69202bc9c66ff3f586ca1e18d7cfba204a1d6c6e4a8e5c7d7
)
readonly HISTORY_PRIVATE_PATH_FILES=(
	README.md
	bin/yana-overlay
	bin/yana-sandbox
	doc/yana.txt
	lua/yana/config.lua
	lua/yana/debug_keys.lua
	lua/yana/health.lua
	lua/yana/inline_diff.lua
	lua/yana/review_hunk_split.lua
	lua/yana/review_watch_ownership.lua
	lua/yana/timeline/retrace.lua
	scripts/release/candidate.sh
	scripts/release/forbidden-patterns.txt
	scripts/release/verify.sh
	tests/release/blink_gate.sh
	tests/release/confined_turn_gate.sh
	tests/release/dependency_gate.sh
	tests/release/fresh_install.sh
	tests/release/gate.sh
	tests/release/helper_gate.sh
	tests/release/policy_mutation_gate.sh
)
readonly HISTORY_PRIVATE_PATH_EXCEPTIONS=(
	"0a28a882bd28f4c2992ae222efc25254d6bd15d0 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"0a28a882bd28f4c2992ae222efc25254d6bd15d0 lua/yana/health.lua 9a0ea52438a46fffb32805d064a6462e35911121"
	"0a28a882bd28f4c2992ae222efc25254d6bd15d0 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"0a28a882bd28f4c2992ae222efc25254d6bd15d0 scripts/release/verify.sh 319a66568d35f7d2d8c01c1e22cb0da35600bd24"
	"158edf6a78c8fd33e70feceeed873f974449c292 bin/yana-sandbox 0b898c9d4df88d90500accb42a7470b50a26b064"
	"158edf6a78c8fd33e70feceeed873f974449c292 doc/yana.txt 9685d3795a83fcfb1571cfadb28dbad71230be13"
	"158edf6a78c8fd33e70feceeed873f974449c292 lua/yana/health.lua ffe2ea782880baf2c735778192815cd38538971d"
	"158edf6a78c8fd33e70feceeed873f974449c292 scripts/release/forbidden-patterns.txt cd0f94a93b08a9fd310b9f0f4fc6b38c42fc9882"
	"158edf6a78c8fd33e70feceeed873f974449c292 scripts/release/verify.sh a965e55c339b62964d472ba3512d7b529b246434"
	"320498604b018c62aeb80cc8238e22020f2029f0 bin/yana-overlay f8c1ba7d24de089aff0832164c6fbe5cc33bfc23"
	"320498604b018c62aeb80cc8238e22020f2029f0 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"320498604b018c62aeb80cc8238e22020f2029f0 doc/yana.txt 70b417e60e9d71dca3a67b9072d2b81a5fc2a204"
	"320498604b018c62aeb80cc8238e22020f2029f0 lua/yana/config.lua e2d30b58f58cef5376942d3e5f840a45f5043c06"
	"320498604b018c62aeb80cc8238e22020f2029f0 lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"320498604b018c62aeb80cc8238e22020f2029f0 lua/yana/inline_diff.lua caf793af8272b43b417cc1fb2a2d441f931ad47b"
	"320498604b018c62aeb80cc8238e22020f2029f0 lua/yana/timeline/retrace.lua b0868fe28b536915e6b0e9924ea92ca287206d50"
	"320498604b018c62aeb80cc8238e22020f2029f0 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"320498604b018c62aeb80cc8238e22020f2029f0 scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"417296195c34106b677da88c6c221982fff88774 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"417296195c34106b677da88c6c221982fff88774 lua/yana/config.lua 84c2de174ab6f8831c275e610bc9de71ee18b9dd"
	"417296195c34106b677da88c6c221982fff88774 lua/yana/health.lua 60807bdcc5aab93803d08c9122d3e509a10c4ac5"
	"417296195c34106b677da88c6c221982fff88774 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"417296195c34106b677da88c6c221982fff88774 scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 bin/yana-overlay f8c1ba7d24de089aff0832164c6fbe5cc33bfc23"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 doc/yana.txt 70b417e60e9d71dca3a67b9072d2b81a5fc2a204"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 lua/yana/config.lua e2d30b58f58cef5376942d3e5f840a45f5043c06"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 lua/yana/health.lua 36d3a8dba0e035880058e2e9e9ed74330a8345d2"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 lua/yana/inline_diff.lua caf793af8272b43b417cc1fb2a2d441f931ad47b"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 lua/yana/timeline/retrace.lua b0868fe28b536915e6b0e9924ea92ca287206d50"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 README.md cfdee9016ee7492ae14cd6b87db7c2806ec7de0b"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 doc/yana.txt 6c5ff960ba27cbeabb47098c8efda9bee48df9a7"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 lua/yana/config.lua e9fece2078e33b8770a492bdfe94b2afeb6ee592"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 lua/yana/inline_diff.lua 54b56b14751ca1bdfc190c679f7407455e93403e"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 lua/yana/timeline/retrace.lua 71df249ab3a6d206dbe15e7d03cc653b4e5c574b"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 scripts/release/verify.sh 4fdd3069b3d1e7bfce9e73bf1f2b9fdf1e01a809"
	"69103f004f467dd270cdd7ccb5d894c071a95173 bin/yana-sandbox 0b898c9d4df88d90500accb42a7470b50a26b064"
	"69103f004f467dd270cdd7ccb5d894c071a95173 doc/yana.txt 42de623f5716a31bedcdec76059e778f119bb8fc"
	"69103f004f467dd270cdd7ccb5d894c071a95173 lua/yana/health.lua 83a36863bc6aa42a1d0b3766d70143b04f01950e"
	"69103f004f467dd270cdd7ccb5d894c071a95173 lua/yana/review_hunk_split.lua 902fc2a21d3fe282c6c2aba899686faec7ab5228"
	"69103f004f467dd270cdd7ccb5d894c071a95173 lua/yana/review_watch_ownership.lua f20b47613cc91f30fffec08f9291092dda9f3602"
	"69103f004f467dd270cdd7ccb5d894c071a95173 scripts/release/forbidden-patterns.txt cd0f94a93b08a9fd310b9f0f4fc6b38c42fc9882"
	"69103f004f467dd270cdd7ccb5d894c071a95173 scripts/release/verify.sh a965e55c339b62964d472ba3512d7b529b246434"
	"7489edc36a692bce8b28e1e2c84d0209afa3adc3 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"7489edc36a692bce8b28e1e2c84d0209afa3adc3 lua/yana/health.lua 60807bdcc5aab93803d08c9122d3e509a10c4ac5"
	"7489edc36a692bce8b28e1e2c84d0209afa3adc3 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"7489edc36a692bce8b28e1e2c84d0209afa3adc3 scripts/release/verify.sh 1f20aad3285c22f3424f49405f7f35fe201c0d6a"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb bin/yana-sandbox 0b898c9d4df88d90500accb42a7470b50a26b064"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb doc/yana.txt 54d4a5b17f141b6dd6cc064988079c89a5e3aadf"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb lua/yana/debug_keys.lua b01c44090de42d93123cf7b842ee5eb027a27372"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb lua/yana/health.lua 52695d8e5cb3e771b129e0679e1b7d1fea04cf90"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb lua/yana/review_hunk_split.lua 902fc2a21d3fe282c6c2aba899686faec7ab5228"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb lua/yana/review_watch_ownership.lua f20b47613cc91f30fffec08f9291092dda9f3602"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb scripts/release/verify.sh 978fd81a493d7c09fa87270bc4340f67af70add4"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c README.md 8445fe55f09ff6a15e9baeca8d453f0cbc13f8da"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c doc/yana.txt 6c5ff960ba27cbeabb47098c8efda9bee48df9a7"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c lua/yana/config.lua e9fece2078e33b8770a492bdfe94b2afeb6ee592"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c lua/yana/inline_diff.lua 54b56b14751ca1bdfc190c679f7407455e93403e"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c lua/yana/timeline/retrace.lua 71df249ab3a6d206dbe15e7d03cc653b4e5c574b"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c scripts/release/verify.sh 4fdd3069b3d1e7bfce9e73bf1f2b9fdf1e01a809"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d bin/yana-sandbox 0b898c9d4df88d90500accb42a7470b50a26b064"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d doc/yana.txt 7c4a58921a7ef82139e88a875f113f9e657533f3"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d lua/yana/health.lua 83a36863bc6aa42a1d0b3766d70143b04f01950e"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d lua/yana/review_hunk_split.lua 902fc2a21d3fe282c6c2aba899686faec7ab5228"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d lua/yana/review_watch_ownership.lua f20b47613cc91f30fffec08f9291092dda9f3602"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d scripts/release/forbidden-patterns.txt cd0f94a93b08a9fd310b9f0f4fc6b38c42fc9882"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d scripts/release/verify.sh a965e55c339b62964d472ba3512d7b529b246434"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 scripts/release/candidate.sh 1dabf1ccf27669ee319ec66fd6fa547abef8fa23"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 scripts/release/verify.sh 9b03bf07f59ab476eca8077d8d54f358f259df1b"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/blink_gate.sh 786ffa1050c860b47b5abe553674e979a2d4662e"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/confined_turn_gate.sh 7f3b4bfa8911139b12bc99980921953704b8439f"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/dependency_gate.sh ab5b8ba28301a4d77560d78bd2a7704ea40cff59"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/fresh_install.sh 265fa8a2536cd02b9b30430d5f0f5b7eb6895f34"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/gate.sh 3dfbe5ed20906a5ebc9f6d0425781e5b08338c2f"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/helper_gate.sh d4d0c991300fb4581e95493bb051d6197641b745"
	"c6e97e8717c0d5ccfae179ab1cf79a16f84f3b93 tests/release/policy_mutation_gate.sh 8c4e6c5ad879c5f96c4ae9971f16c44d3be17407"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b README.md 8445fe55f09ff6a15e9baeca8d453f0cbc13f8da"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b doc/yana.txt 6c5ff960ba27cbeabb47098c8efda9bee48df9a7"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b lua/yana/config.lua e9fece2078e33b8770a492bdfe94b2afeb6ee592"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b lua/yana/inline_diff.lua 54b56b14751ca1bdfc190c679f7407455e93403e"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b lua/yana/timeline/retrace.lua 71df249ab3a6d206dbe15e7d03cc653b4e5c574b"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b scripts/release/verify.sh 4fdd3069b3d1e7bfce9e73bf1f2b9fdf1e01a809"
	"dec5e27153c63e0529731ac5ba017028ddb0504b README.md fdaa5224a485eb2f03d2b1b0ced54146c26f84e8"
	"dec5e27153c63e0529731ac5ba017028ddb0504b bin/yana-overlay f8c1ba7d24de089aff0832164c6fbe5cc33bfc23"
	"dec5e27153c63e0529731ac5ba017028ddb0504b bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"dec5e27153c63e0529731ac5ba017028ddb0504b doc/yana.txt 70b417e60e9d71dca3a67b9072d2b81a5fc2a204"
	"dec5e27153c63e0529731ac5ba017028ddb0504b lua/yana/config.lua e2d30b58f58cef5376942d3e5f840a45f5043c06"
	"dec5e27153c63e0529731ac5ba017028ddb0504b lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"dec5e27153c63e0529731ac5ba017028ddb0504b lua/yana/inline_diff.lua caf793af8272b43b417cc1fb2a2d441f931ad47b"
	"dec5e27153c63e0529731ac5ba017028ddb0504b lua/yana/timeline/retrace.lua b0868fe28b536915e6b0e9924ea92ca287206d50"
	"dec5e27153c63e0529731ac5ba017028ddb0504b scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"dec5e27153c63e0529731ac5ba017028ddb0504b scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c lua/yana/config.lua 12b75d623587663c56d2ffd4bdd74ce3db8653ba"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c lua/yana/health.lua 60807bdcc5aab93803d08c9122d3e509a10c4ac5"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 bin/yana-overlay f8c1ba7d24de089aff0832164c6fbe5cc33bfc23"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 doc/yana.txt 70b417e60e9d71dca3a67b9072d2b81a5fc2a204"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 lua/yana/config.lua e2d30b58f58cef5376942d3e5f840a45f5043c06"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 lua/yana/health.lua 36d3a8dba0e035880058e2e9e9ed74330a8345d2"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 lua/yana/inline_diff.lua caf793af8272b43b417cc1fb2a2d441f931ad47b"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 lua/yana/timeline/retrace.lua b0868fe28b536915e6b0e9924ea92ca287206d50"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 scripts/release/verify.sh 2fa32c79cc6129036aaa2111f34afd55bc20cc1d"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 README.md d6a2b90c2a28eea4b0e651b8d6b49af9a001bd96"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 bin/yana-sandbox 3801796811668c8c5a2f4d80d2cf68209be47cbd"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 doc/yana.txt 6c5ff960ba27cbeabb47098c8efda9bee48df9a7"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 lua/yana/config.lua e9fece2078e33b8770a492bdfe94b2afeb6ee592"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 lua/yana/health.lua 1cbda453e46b403e3cb1d8826432f8569f514bf9"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 lua/yana/inline_diff.lua 54b56b14751ca1bdfc190c679f7407455e93403e"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 lua/yana/timeline/retrace.lua 71df249ab3a6d206dbe15e7d03cc653b4e5c574b"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 scripts/release/forbidden-patterns.txt 4af141cf6607f09b22f25dd9e13c3985bc0156ca"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 scripts/release/verify.sh 4fdd3069b3d1e7bfce9e73bf1f2b9fdf1e01a809"
)
readonly HISTORY_RETIRED_PATH_EXCEPTIONS=(
	"158edf6a78c8fd33e70feceeed873f974449c292 prompt.txt f6ff9cca9f06883f3096ad2a51774bb52cecca15"
	"158edf6a78c8fd33e70feceeed873f974449c292 scripts/install-deps.sh 6e5379273f605791d44210c2f5c96b90617077e9"
	"320498604b018c62aeb80cc8238e22020f2029f0 scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
	"417296195c34106b677da88c6c221982fff88774 scripts/install-deps.sh 3f81b16fb060835ba9fdb1d4be742875bedcb84f"
	"42615dbe02aa6b08bbd30e736c429d9abd087430 scripts/install-deps.sh 3f81b16fb060835ba9fdb1d4be742875bedcb84f"
	"540fd07fc58b6c78b430ef27d9567bf3091412e9 scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
	"69103f004f467dd270cdd7ccb5d894c071a95173 scripts/install-deps.sh 665f7e808171081956ff2f7a9092f23021a89cd1"
	"7489edc36a692bce8b28e1e2c84d0209afa3adc3 scripts/install-deps.sh 3f81b16fb060835ba9fdb1d4be742875bedcb84f"
	"7a2fe1ecb80e3a84e18ba659c551d80814fe51bb scripts/install-deps.sh 665f7e808171081956ff2f7a9092f23021a89cd1"
	"a7a60922fcf426e524ca1ccb1905d9b6fa44471c scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
	"c2b76a60d65016ef8fd3bcc61139a7e40ea8ae6d scripts/install-deps.sh 665f7e808171081956ff2f7a9092f23021a89cd1"
	"d3027d895bf8abe387af45fb47eb77c58e2e8b3b scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
	"dec5e27153c63e0529731ac5ba017028ddb0504b scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
	"e4fb25691dcd79e287f7847b3f4ea8c8f9449b3c scripts/install-deps.sh 3f81b16fb060835ba9fdb1d4be742875bedcb84f"
	"edaff51e254f61a0d1ac0c90f8ac75c5d74ee954 scripts/install-deps.sh 3f81b16fb060835ba9fdb1d4be742875bedcb84f"
	"f842a14c13548eb4696252c5d62339fd9c49aed0 scripts/install-deps.sh 826d166f67e4673ca622e82abdab878bd04f0903"
)

history_patterns_minus_private=
history_head=

# history_exception TABLE COMMIT PATH BLOB: true only for an exact row of TABLE
# and only when COMMIT is not the advertised HEAD.
history_exception() {
	local -n rows=$1
	local row
	[[ -n $2 && $2 != "$history_head" ]] || return 1
	for row in "${rows[@]}"; do
		[[ $row == "$2 $3 $4" ]] && return 0
	done
	return 1
}

# private_path_history_exception HIST_ROOT PATH COMMIT BLOB: an exact private-path
# row for a declared file, not at HEAD, whose blob is clean once the private path
# pattern is removed from the registry.
private_path_history_exception() {
	local hist_root=$1 path=$2 commit=$3 blob=$4
	[[ -n $history_patterns_minus_private ]] || return 1
	[[ " ${HISTORY_PRIVATE_PATH_FILES[*]} " == *" $path "* ]] || return 1
	history_exception HISTORY_PRIVATE_PATH_EXCEPTIONS "$commit" "$path" "$blob" || return 1
	forbidden_bytes_scan "$hist_root" "$history_patterns_minus_private" "$path" >/dev/null
}

# Path-class check for history: the retired helper is NOT accepted via the
# bin/yana-* wildcard — only via retired_history_exception.
history_path_class_ok() {
	local path=$1
	if [[ $path == bin/yana-ollama-agent ]]; then
		return 1
	fi
	forbidden_bytes_allowed_path "$path"
}

scan_text_blob() {
	local hist_root=$1 patterns=$2 path=$3 commit=$4 blob=$5
	local hits

	if forbidden_bytes_binary_path "$path"; then
		return 0
	fi
	if [[ $(LC_ALL=C tr -dc '\0' <"$hist_root/$path" | wc -c) -gt 0 ]]; then
		note_fail "NUL bytes in main history: $path"
		return 0
	fi
	if ! iconv -f UTF-8 -t UTF-8 "$hist_root/$path" >/dev/null 2>&1; then
		note_fail "not valid UTF-8 in main history: $path"
		return 0
	fi
	set +e
	hits=$(forbidden_bytes_scan "$hist_root" "$patterns" "$path")
	local rc=$?
	set -e
	if ((rc != 0)); then
		if history_exception HISTORY_FORBIDDEN_BYTES_EXCEPTIONS "$commit" "$path" "$blob"; then
			echo "CANDIDATE HISTORY EXCEPTION: forbidden bytes accepted commit=$commit path=$path blob=$blob"
		elif private_path_history_exception "$hist_root" "$path" "$commit" "$blob"; then
			echo "CANDIDATE HISTORY EXCEPTION: private path accepted commit=$commit path=$path blob=$blob"
		else
			note_fail "forbidden bytes in main history: $path"
		fi
	fi
}

# Fail-closed per-commit audit of main (not side branches).
audit_main_history() {
	local clone=$1 scratch=$2
	local lib=$clone/scripts/release/lib/forbidden_bytes.sh
	local patterns=$clone/scripts/release/forbidden-patterns.txt
	local hist_root=$scratch/hist_blob
	local c path mode type sha

	[[ -f $lib && -f $patterns ]] || {
		note_fail "clone missing forbidden-byte policy ($lib / $patterns)"
		return
	}
	# shellcheck source=lib/forbidden_bytes.sh
	source "$lib"

	if ! git -C "$clone" rev-list main >"$scratch/commits"; then
		note_fail "cannot list main history"
		return
	fi
	history_head=$(git -C "$clone" rev-parse main)

	# The registry minus the private path pattern, for private-path rows only. A
	# registry without that pattern leaves the private-path exceptions unavailable.
	history_patterns_minus_private=$scratch/patterns-minus-private
	: >"$history_patterns_minus_private"
	local pattern_line fingerprint private_pattern_seen=0
	while IFS= read -r pattern_line || [[ -n $pattern_line ]]; do
		local matched_private=0 private_fingerprint
		fingerprint=$(printf '%s' "$pattern_line" | sha256sum | cut -c1-64)
		for private_fingerprint in "${PRIVATE_PATH_PATTERN_SHA256S[@]}"; do
			if [[ $fingerprint == "$private_fingerprint" ]]; then
				matched_private=1
				private_pattern_seen=$((private_pattern_seen + 1))
				break
			fi
		done
		if ((matched_private)); then
			continue
		fi
		printf '%s\n' "$pattern_line" >>"$history_patterns_minus_private"
	done <"$patterns"
	((private_pattern_seen == ${#PRIVATE_PATH_PATTERN_SHA256S[@]})) || history_patterns_minus_private=

	mkdir -p "$hist_root"
	while IFS= read -r c; do
		[[ -n $c ]] || continue

		if ! git -C "$clone" ls-tree -r -z --full-tree "$c" >"$scratch/lstree.$c"; then
			note_fail "cannot list tree for commit $c"
			continue
		fi

		: >"$scratch/tree_paths"
		while IFS= read -r -d '' ent; do
			# ls-tree -z lines: MODE TYPE SHA\tPATH
			mode=${ent%% *}
			rest=${ent#* }
			type=${rest%% *}
			rest=${rest#* }
			sha=${rest%%$'\t'*}
			path=${rest#*$'\t'}
			[[ -n $path ]] || {
				note_fail "empty path in tree listing for $c"
				continue
			}
			# Reject path names that themselves carry forbidden identity text.
			if printf '%s' "$path" | LC_ALL=C grep -aEq -f "$patterns"; then
				note_fail "forbidden bytes in historical path name: $path"
			fi
			if [[ $type == blob ]] && history_exception HISTORY_UNMANIFESTED_EXCEPTIONS "$c" "$path" "$sha"; then
				echo "CANDIDATE HISTORY EXCEPTION: unmanifested path accepted commit=$c path=$path blob=$sha"
			else
				printf '%s\n' "$path" >>"$scratch/tree_paths"
			fi

			[[ $type == blob ]] || continue
			if retired_history_exception "$path" "$c" "$sha"; then
				:
			elif history_path_class_ok "$path"; then
				:
			else
				note_fail "history path outside public classes (commit $c): $path"
				continue
			fi

			mkdir -p "$hist_root/$(dirname -- "$path")"
			if ! git -C "$clone" cat-file blob "$sha" >"$hist_root/$path"; then
				note_fail "cannot read blob $sha at $path (commit $c)"
				continue
			fi
			scan_text_blob "$hist_root" "$patterns" "$path" "$c" "$sha"
			rm -f "$hist_root/$path"
		done <"$scratch/lstree.$c"

		if ! git -C "$clone" show "$c:scripts/release/manifest.txt" >"$scratch/manifest.$c" 2>/dev/null; then
			note_fail "manifest missing at commit $c"
			continue
		fi
		LC_ALL=C sort -u "$scratch/tree_paths" >"$scratch/tree_sorted"
		LC_ALL=C sort -u "$scratch/manifest.$c" >"$scratch/manifest_sorted"
		if ! diff -q "$scratch/manifest_sorted" "$scratch/tree_sorted" >/dev/null; then
			note_fail "tree paths differ from manifest at commit $c"
			diff -u "$scratch/manifest_sorted" "$scratch/tree_sorted" >&2 || true
		fi

		# Every manifest path must satisfy history path policy (incl. retired).
		while IFS= read -r path; do
			[[ -n $path ]] || continue
			if [[ $path == prompt.txt || $path == scripts/install-deps.sh ]]; then
				manifest_blob=$(git -C "$clone" rev-parse "$c:$path" 2>/dev/null || true)
			else
				manifest_blob=
			fi
			if retired_history_exception "$path" "$c" "$manifest_blob"; then
				continue
			fi
			if ! history_path_class_ok "$path"; then
				note_fail "manifest path outside public classes at commit $c: $path"
			fi
		done <"$scratch/manifest.$c"
	done <"$scratch/commits"
}

check() {
	local url=$1
	local tag_mode=${2:---allow-untagged-head}
	case $tag_mode in
	--allow-untagged-head | --require-version-tag) ;;
	*)
		echo "candidate check: unknown tag mode: $tag_mode" >&2
		usage
		;;
	esac

	local clone scratch
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-candidate.XXXXXX")
	trap "rm -rf '$scratch'" EXIT
	clone=$scratch/clone

	local head_sha="" main_sha=""
	local -a adv_tags=()
	local sha ref tag

	if ! git ls-remote "$url" >"$scratch/ls-remote"; then
		note_fail "cannot ls-remote $url"
		(( fail == 0 )) || exit 1
		exit 1
	fi

	while IFS=$'\t' read -r sha ref; do
		[[ -n $ref ]] || continue
		case $ref in
		HEAD)
			head_sha=$sha
			;;
		refs/heads/main)
			main_sha=$sha
			;;
		refs/tags/*)
			tag=${ref#refs/tags/}
			# Peel lines (tag^{}) are informational; validate the tag name only.
			if [[ $tag == *^{} ]]; then
				continue
			fi
			if ! semver_tag_ok "$tag"; then
				note_fail "remote advertises malformed release tag: $tag"
				continue
			fi
			adv_tags+=("$tag")
			;;
		*)
			note_fail "remote advertises a ref outside the public set: $ref"
			;;
		esac
	done <"$scratch/ls-remote"

	[[ -n $main_sha ]] || note_fail "remote does not advertise refs/heads/main"
	[[ -n $head_sha ]] || note_fail "remote does not advertise HEAD"
	if [[ -n $main_sha && -n $head_sha && $main_sha != "$head_sha" ]]; then
		note_fail "advertised HEAD does not equal refs/heads/main"
	fi

	git clone -q --single-branch --branch main "$url" "$clone"

	# Fetch every advertised SemVer tag explicitly (do not rely on auto-follow).
	local t
	for t in "${adv_tags[@]}"; do
		if ! git -C "$clone" fetch -q origin "refs/tags/$t:refs/tags/$t" 2>/dev/null; then
			note_fail "cannot fetch advertised tag $t"
			continue
		fi
		if ! git -C "$clone" rev-parse -q --verify "refs/tags/$t" >/dev/null; then
			note_fail "advertised tag missing after fetch: $t"
		fi
	done

	local head_commit version roots merges
	head_commit=$(git -C "$clone" rev-parse HEAD)
	version=$(tr -d '\r\n' <"$clone/VERSION")

	mapfile -t roots < <(git -C "$clone" rev-list --max-parents=0 main)
	((${#roots[@]} == 1)) || note_fail "main does not have exactly one root (${#roots[@]} found)"
	[[ -z "$(git -C "$clone" log -1 --format=%P "${roots[0]}")" ]] \
		|| note_fail "root commit unexpectedly has a parent"
	mapfile -t merges < <(git -C "$clone" rev-list --min-parents=2 main)
	((${#merges[@]} == 0)) || note_fail "main is non-linear (merge commit present)"

	local saw_version_tag=0 peel tag_version
	for t in "${adv_tags[@]}"; do
		if ! peel=$(git -C "$clone" rev-parse "$t^{commit}" 2>/dev/null); then
			note_fail "tag $t does not peel to a commit"
			continue
		fi
		if ! git -C "$clone" merge-base --is-ancestor "$peel" "$head_commit"; then
			note_fail "tag $t does not point into main"
			continue
		fi
		tag_version=$(git -C "$clone" show "$peel:VERSION" | tr -d '\r\n')
		[[ $tag_version == "${t#v}" ]] \
			|| note_fail "tag $t VERSION mismatch (peel has '$tag_version')"
		if [[ $t == "v$version" ]]; then
			saw_version_tag=1
		fi
	done

	# No unexpected local tags beyond the advertised set.
	while IFS= read -r ref; do
		case $ref in
		refs/tags/*)
			tag=${ref#refs/tags/}
			local found=0
			for t in "${adv_tags[@]}"; do
				[[ $t == "$tag" ]] && found=1 && break
			done
			((found == 1)) || note_fail "unexpected local tag after fetch: $tag"
			;;
		esac
	done < <(git -C "$clone" for-each-ref --format='%(refname)' refs/tags)

	if [[ $tag_mode == --require-version-tag ]]; then
		((saw_version_tag == 1)) \
			|| note_fail "required tag v$version is missing (--require-version-tag)"
	fi

	[[ "$(git -C "$clone" remote)" == "origin" ]] || note_fail "unexpected remote set"

	git -C "$clone" ls-tree -r --name-only HEAD | LC_ALL=C sort >"$scratch/head_paths"
	LC_ALL=C sort -u "$clone/scripts/release/manifest.txt" >"$scratch/manifest_paths"
	if ! diff -u "$scratch/manifest_paths" "$scratch/head_paths" >&2; then
		note_fail "HEAD tree paths differ from HEAD manifest"
	fi

	"$clone/scripts/release/verify.sh" "$clone" || note_fail "verify.sh failed on the fresh clone"

	# A rejected candidate needs no full-history audit. Keep that expensive scan
	# for trees whose refs, tags and HEAD export have passed their own checks.
	(( fail == 0 )) || return 1
	audit_main_history "$clone" "$scratch"

	(( fail == 0 )) || exit 1
	printf 'CANDIDATE CHECK PASS url=%s commit=%s tag_mode=%s\n' \
		"$url" "$(git -C "$clone" rev-parse HEAD)" "$tag_mode"
}

# Sourced (tests/release/candidate_history_exceptions_gate.sh): define only.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

case "${1:-}" in
build)
	[[ $# == 3 ]] || usage
	build "$2" "$3"
	;;
check)
	[[ $# == 2 || $# == 3 ]] || usage
	check "$2" "${3:---allow-untagged-head}"
	;;
*) usage ;;
esac
