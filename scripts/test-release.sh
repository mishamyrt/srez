#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/App" "$work/repo/scripts"
cp Makefile cliff.toml .gitignore "$work/repo/"
cp App/Info.plist.tpl "$work/repo/App/"
cp scripts/publish.sh "$work/repo/scripts/"
git init --quiet --bare "$work/remote.git"
cd "$work/repo"
git init --quiet --initial-branch=main
git config user.name "Release Test"
git config user.email "release-test@example.invalid"
git config commit.gpgsign false
git config tag.gpgsign false
git remote add origin "$work/remote.git"
echo first > fixture.md
git add .
git commit --quiet -m "feat: first feature"

make publish VERSION=1.2.3 VERSION_BUNDLE=7 > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; exit 1; }
[[ $(git rev-parse HEAD) == $(git --git-dir="$work/remote.git" rev-parse refs/heads/main) ]]
[[ $(git rev-parse HEAD) == $(git --git-dir="$work/remote.git" rev-parse 'refs/tags/v1.2.3^{commit}') ]]
[[ -z $(git status --porcelain) ]]
grep -q '^VERSION := 1.2.3$' Makefile
grep -q '^VERSION_BUNDLE := 7$' Makefile
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist) == 1.2.3 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' App/Info.plist) == 7 ]]
grep -Eq '^## \[1\.2\.3\]\(https://github.com/mishamyrt/srez/releases/tag/v1\.2\.3\)' CHANGELOG.md
grep -q 'First feature' CHANGELOG.md

# Command-line overrides must regenerate the plist, even when it already exists.
make App/Info.plist VERSION=1.2.4 VERSION_BUNDLE=8
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist) == 1.2.4 ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' App/Info.plist) == 8 ]]
if make App/Info.plist VERSION=invalid > "$work/invalid.log" 2>&1; then
    echo "Invalid versions must be rejected." >&2
    exit 1
fi

echo second >> fixture.md
git add fixture.md
head_before=$(git rev-parse HEAD)
if make publish VERSION=1.2.4 > "$work/dirty.log" 2>&1; then
    echo "Publishing must reject unrelated staged changes." >&2
    exit 1
fi
[[ $(git rev-parse HEAD) == "$head_before" ]]
git commit --quiet -m "fix: second fix"
make publish VERSION=1.2.4 VERSION_BUNDLE=8 > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; exit 1; }
grep -Eq '^## \[1\.2\.4\].*/compare/v1\.2\.3\.\.v1\.2\.4' CHANGELOG.md
grep -q 'Second fix' CHANGELOG.md
if make publish VERSION=1.2.4 > "$work/duplicate.log" 2>&1; then
    echo "Publishing must reject existing tags." >&2
    exit 1
fi
[[ -z $(git status --porcelain) ]]
echo "Release command, changelog, plist overrides and publication guards passed."
