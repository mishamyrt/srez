#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Run make publish VERSION=X.Y.Z}"
: "${VERSION_BUNDLE:?VERSION_BUNDLE is not set}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$VERSION_BUNDLE" =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected VERSION=X.Y.Z and a positive VERSION_BUNDLE." >&2
    exit 1
fi
command -v git-cliff >/dev/null || { echo "Install git-cliff: brew install git-cliff" >&2; exit 1; }
if [[ -n "$(git status --porcelain -- . ':(exclude)Makefile')" ]]; then
    echo "Commit or stash changes before publishing (only Makefile may be modified)." >&2
    exit 1
fi
branch=$(git symbolic-ref --short HEAD)
git remote get-url origin >/dev/null
tag="v$VERSION"
if git show-ref --verify --quiet "refs/tags/$tag"; then
    echo "Tag $tag already exists." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git-cliff --offline --tag "$tag" --output "$work/CHANGELOG.md"
sed -E -e "s/^VERSION := .*/VERSION := $VERSION/" \
    -e "s/^VERSION_BUNDLE := .*/VERSION_BUNDLE := $VERSION_BUNDLE/" Makefile > "$work/Makefile"
cat "$work/Makefile" > Makefile
mv "$work/CHANGELOG.md" CHANGELOG.md
make App/Info.plist
git add Makefile CHANGELOG.md
git commit -m "chore: release $VERSION"
git tag -a "$tag" -m "release $tag"
git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"
