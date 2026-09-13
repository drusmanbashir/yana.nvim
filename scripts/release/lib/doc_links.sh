# shellcheck shell=bash
# Local links in shipped Markdown, shared by verify.sh (export tree) and
# archive.sh (archive member list) so both check the same link set.
#
# Link forms shipped today: inline [text](target) and ![alt](target), and the
# HTML src="target" / href="target" attributes README's logo uses. Anchors are
# stripped; scheme URLs, mailto: and pure #anchors are not local.

# doc_links_targets FILE
# Print each local link target in FILE, one per line.
doc_links_targets() {
	local target
	{ grep -oE '\]\([^)[:space:]]+\)|(src|href)="[^"]+"' "$1" || true; } \
		| sed -E 's/^\]\((.*)\)$/\1/; s/^(src|href)="(.*)"$/\2/' \
		| while IFS= read -r target; do
			target=${target%%#*}
			case $target in '' | *://* | mailto:*) continue ;; esac
			printf '%s\n' "$target"
		done
}

# doc_links_resolve DOC TARGET
# Print TARGET resolved against DOC's directory, relative to the tree root.
# A result of `..` or `../*` leaves the tree.
doc_links_resolve() {
	realpath -m --relative-to=/r "/r/$(dirname "$1")/$2"
}
