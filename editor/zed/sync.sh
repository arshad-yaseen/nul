#!/usr/bin/env bash
#
# Point the Zed extension at the grammar as it stands right now.
#
# Zed does not read the grammar out of the working tree. It clones the
# repository named in extension.toml, checks out `rev`, and compiles
# editor/grammar/src/parser.c to wasm. So a grammar change reaches the editor
# only once it is generated, committed, and the rev is moved. This script does
# the generate, the copy, and the rev, and tells you about the commit.
#
#   ./editor/zed/sync.sh            generate, copy queries, move rev to HEAD
#   ./editor/zed/sync.sh --commit   commit the grammar first, then all of that
#
# After it runs: in Zed, `zed: reload extensions`, or install the dev extension
# once from the extensions page with `editor/zed` as the directory.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
grammar="$root/editor/grammar"
extension="$root/editor/zed"
language="$extension/languages/nul"

cd "$root"

# The generated parser is what Zed compiles, so it has to be current.
echo "generating the parser"
(cd "$grammar" && ./node_modules/.bin/tree-sitter generate)

# highlights and injections are written once, in the grammar, and copied here.
# Every other query file differs between editors and is written by hand.
echo "copying the shared queries"
cp "$grammar/queries/highlights.scm" "$language/highlights.scm"
cp "$grammar/queries/injections.scm" "$language/injections.scm"

if [ "${1:-}" = "--commit" ]; then
    git add "$grammar" "$extension"
    if git diff --cached --quiet; then
        echo "nothing to commit"
    else
        git commit -q -m "update the Nul grammar"
        echo "committed"
    fi
fi

if ! git diff --quiet -- "$grammar" || ! git diff --cached --quiet -- "$grammar"; then
    echo
    echo "  warning: editor/grammar has uncommitted changes."
    echo "  Zed builds from a commit, so it will not see them. Run with --commit."
    echo
fi

# Zed fetches one revision by its sha over file://, which git refuses to serve
# unless the repository allows an unadvertised object to be asked for.
git config uploadpack.allowAnySHA1InWant true

rev=$(git rev-parse HEAD)
manifest="$extension/extension.toml"

# The repository url is absolute and machine-local, so keep it honest too.
/usr/bin/sed -i '' \
    -e "s|^repository = \"file://.*\"|repository = \"file://$root\"|" \
    -e "s|^rev = \".*\"|rev = \"$rev\"|" \
    "$manifest"

echo "grammar pinned to $rev"
