#!/usr/bin/env bash
# Build the PGXN distribution zip from a committed git revision.
#
#   scripts/release.sh            # zip of HEAD, version from META.json
#   scripts/release.sh v0.10.3    # zip of a tag (or any commit)
#   make dist                     # same as the first form
#
# Output: pg_stat_index_queries-<version>.zip in the repository root, with
# every file under pg_stat_index_queries-<version>/ as PGXN expects. Only
# tracked files are included (git archive), so build products, ci-local-logs/
# and lab-out/ never get in; bench/results/ (raw benchmark output) and
# compiled objects are excluded explicitly as well.
#
# This script only builds the zip. It does not tag, push, or upload anything.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
rev=${1:-HEAD}

# The version comes from META.json at that revision, not the working tree.
if ! git cat-file -e "$rev:META.json" 2>/dev/null; then
	echo "error: $rev has no committed META.json" >&2
	exit 1
fi
version=$(git show "$rev:META.json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')
name=pg_stat_index_queries-$version
out=$repo/$name.zip

if [ "$rev" = HEAD ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "warning: uncommitted changes are not included (archiving HEAD)" >&2
fi

git archive --format=zip --prefix="$name/" -o "$out" "$rev" -- . \
	':(exclude)bench/results' \
	':(exclude)ci-local-logs' \
	':(exclude)lab-out' \
	':(exclude,glob)**/*.o' \
	':(exclude,glob)**/*.so' \
	':(exclude,glob)**/*.dylib' \
	':(exclude,glob)**/*.bc'

echo "$out"
