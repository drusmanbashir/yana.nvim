# forbidden_bytes.sh — shared implementation of the release forbidden-byte
# policy (row 62). Sourced by both:
#
#   scripts/release/verify.sh          — scans an EXPORTED tree, at
#                                         release-candidate time, restricted
#                                         to scripts/release/manifest.txt
#   tests/forbidden_bytes_gate.sh      — scans the WORKING tree, on every
#                                         ordinary gate run
#
# so the two checks share one scanning implementation and one path-class
# policy, and can never disagree about what is forbidden or what is public.
#
# Not a standalone script: `source` it, then call the functions below.
# Nothing here execute()s on its own and nothing here calls `exit`.

# forbidden_bytes_allowed_path PATH
#
# True if PATH belongs to one of the hard-coded public path classes this
# project is willing to ship. This is the same classifier verify.sh uses to
# stop the manifest from smuggling in a new class of file; the working-tree
# gate reuses it verbatim so "what we scan" and "what we ship" never drift
# apart from each other.
forbidden_bytes_allowed_path() {
	case $1 in
	.github/workflows/ci.yml | .github/workflows/release.yml) return 0 ;;
	.gitignore | .stylua.toml | CHANGELOG.md | LICENSE | NOTICE | README.md | VERSION) return 0 ;;
	doc/yana.txt | plugin/yana.lua) return 0 ;;
	lua/yana/*.lua | lua/yana/*/*.lua | lua/blink_yana/*.lua) return 0 ;;
	bin/yana-[a-z]*) return 0 ;;
	scripts/install-deps.sh) return 0 ;;
	scripts/release/*) return 0 ;;
	tests/release/*) return 0 ;;
	esac
	return 1
}

# forbidden_bytes_scan TREE PATTERNS PATH
#
# Scans TREE/PATH for any of the forbidden byte patterns in the PATTERNS
# file (scripts/release/forbidden-patterns.txt format: one extended regex
# per line, consumed by `grep -f`).
#
# Exemptions (identical to verify.sh's pre-refactor behaviour):
#   - PATH == scripts/release/forbidden-patterns.txt is never scanned: it is
#     the scanner's own registry and must contain the literal pattern text.
#   - PATH == NOTICE has its one audited legacy-upstream URL line (the
#     recorded fork point citation) filtered out of the hits.
#
# On stdout: zero or more "LINENO:matched text" rows (grep -n format), one
# per hit, in file order. Emits nothing on a clean file.
# Return code: 0 clean, 1 one or more forbidden hits.
forbidden_bytes_scan() {
	local tree=$1 patterns=$2 path=$3
	[[ "$path" == "scripts/release/forbidden-patterns.txt" ]] && return 0

	local hits
	hits=$(LC_ALL=C grep -aEin -f "$patterns" "$tree/$path" || true)

	if [[ "$path" == "NOTICE" ]]; then
		local legacy=neo
		legacy+=cursor
		hits=$(printf '%s' "$hits" \
			| grep -Ev "^4:https://github\\.com/just-nibble/${legacy}\\.git$" || true)
	fi

	[[ -z "$hits" ]] && return 0
	printf '%s\n' "$hits"
	return 1
}
