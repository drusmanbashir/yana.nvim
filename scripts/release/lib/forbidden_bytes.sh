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
	local spec_dir=spec specs_dir=specs handoff_dir=handoff handoffs_dir=handoffs
	local agents_name=AGENTS
	agents_name+=.md
	case $1 in
	# Keep private development, diagnostic capture and operator configuration out
	# even if a manifest edit names them.
	*/"$agents_name" | "$agents_name" | "$spec_dir"/* | "$specs_dir"/* \
		| */"$spec_dir"/* | */"$specs_dir"/* \
		| "$handoff_dir"/* | "$handoffs_dir"/* | notes/* | mcpyana/* | .agent/* | */.agent/* \
		| .claude/* | */.claude/* | worktrees/* | */worktrees/* \
		| evidence/* | .evidence/* | out/* \
		| lua/yana/"$agents_name" | lua/yana/debug_buffer_states.lua \
		| lua/yana/debug_buffer_states_bundle.lua | nvim/lua/user/yana.lua \
		| tools/buffer-snapshot-triple.sh | prompt.txt \
		| .github/workflows/tests.yml | bin/yana-ollama-agent | bin/yana-release \
		| docs/repl.md | docs/security.md | assets/logo/* \
		| assets/yana-review-full-still.png | assets/yana-review-full.gif \
		| assets/yana-review-full.mp4 | assets/yana-review-full.take.json \
		| assets/yana-review.mp4 | assets/yana-review.take.json \
		| scripts/release/README.md | scripts/release/hpc-smoke-remote.sh \
		| scripts/release/manifest_policy.py | scripts/release/paths.conf \
		| scripts/release/to-release.sh \
		| tests/release/candidate_check_gate.sh \
		| tests/release/candidate_history_exceptions_gate.sh \
		| tests/release/health_yana_ui_smoke.lua \
		| tests/release/install_remedy_smoke.lua \
		| tests/release/yana_release_preflight_gate.sh) return 1 ;;
	.github/workflows/ci.yml | .github/workflows/release.yml) return 0 ;;
	.gitignore | .stylua.toml | CHANGELOG.md | LICENSE | NOTICE | README.md | VERSION) return 0 ;;
	assets/*.gif | assets/*.mp4 | assets/*.png | assets/*.svg) return 0 ;;
	doc/yana.txt | plugin/yana.lua) return 0 ;;
	docs/*.md) return 0 ;;
	lua/yana/*.lua | lua/yana/*/*.lua | lua/blink_yana/*.lua) return 0 ;;
	bin/yana-[a-z]*) return 0 ;;
	bin/yanad) return 0 ;;
	bin/lib/yanad/*.py) return 0 ;;
	bin/lib/yana-overlay/*.sh) return 0 ;;
	scripts/install-deps.sh | scripts/release/*) return 0 ;;
	tests/release/*) return 0 ;;
	tests/headless/lib/hunks.lua) return 0 ;;
	tests/lib/sigsafe.sh) return 0 ;;
	esac
	return 1
}

# forbidden_bytes_binary_path PATH
#
# True if PATH belongs to an approved public binary asset class. These paths
# are allowed to ship but are not UTF-8 text and cannot be scanned line-wise.
forbidden_bytes_binary_path() {
	case $1 in
	assets/*.gif | assets/*.mp4 | assets/*.png) return 0 ;;
	esac
	return 1
}

# forbidden_bytes_scan TREE PATTERNS PATH
#
# Scans TREE/PATH for any of the forbidden byte patterns in the PATTERNS
# file (scripts/release/forbidden-patterns.txt format: one extended regex
# per line, consumed by `grep -f`).
#
# Exemptions: the registry is scanned for private paths while its other patterns
# are exempt from matching themselves. NOTICE's one audited upstream repository URL line
# (the recorded fork point citation)
# filtered out of the hits. The exemption is keyed to the URL's own text, not to a line
# number: NOTICE is prose that gets edited, and coupling the exemption to "line 4" broke
# on the first legitimate rewrite that moved the line.
#
# On stdout: zero or more "LINENO:matched text" rows (grep -n format), one
# per hit, in file order. Emits nothing on a clean file.
# Return code: 0 clean, 1 one or more forbidden hits.
forbidden_bytes_scan() {
	local tree=$1 patterns=$2 path=$3
	forbidden_bytes_binary_path "$path" && return 0

	local hits
	hits=$(LC_ALL=C grep -aEin -f "$patterns" "$tree/$path" || true)
	if [[ "$path" == ".gitignore" ]]; then
		# These two exact entries ignore private policy scratch inside the source
		# checkout. Other additions remain subject to the public-content scan.
		local spec_dir=spec
		hits=$(printf '%s\n' "$hits" \
			| grep -Ev "^[0-9]+:${spec_dir}/council/(runs/|LATEST)$" || true)
	fi
	if [[ "$path" == "scripts/release/forbidden-patterns.txt" ]]; then
		# The registry's non-path prohibitions name their own patterns. Still scan
		# it for account-specific home and agent scratch paths.
		local private_patterns
		private_patterns=$(mktemp)
		printf '%s\n' '/(home)/[^/[:space:]]+' '/(s)/agent_[[:alnum:]_.-]+' \
			| grep -Fxf "$patterns" >"$private_patterns"
		hits=$(LC_ALL=C grep -aEin -f "$private_patterns" "$tree/$path" || true)
		rm -f "$private_patterns"
	fi

	if [[ "$path" == "NOTICE" ]]; then
		local legacy=neo
		legacy+=cursor
		hits=$(printf '%s' "$hits" \
			| grep -Ev "^[0-9]+:https://github\\.com/just-nibble/${legacy}\\.git$" || true)
	fi

	[[ -z "$hits" ]] && return 0
	printf '%s\n' "$hits"
	return 1
}
