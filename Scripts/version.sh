#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

TAG="$(git describe --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"

if [[ -n "$TAG" ]]; then
    BASE_VERSION="${TAG#v}"
    COMMITS_SINCE_TAG="$(git rev-list --count "$TAG"..HEAD)"
else
    BASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    COMMITS_SINCE_TAG="$(git rev-list --count HEAD)"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE_VERSION"
if [[ ! "$MAJOR" =~ ^[0-9]+$ || ! "$MINOR" =~ ^[0-9]+$ || ! "$PATCH" =~ ^[0-9]+$ ]]; then
    print -u2 "Invalid semantic version: $BASE_VERSION"
    exit 1
fi

print "$MAJOR.$MINOR.$((PATCH + COMMITS_SINCE_TAG))"
