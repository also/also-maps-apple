#!/bin/sh
# Run as a build phase: writes BuildInfo.plist into the app's resources, saying
# which checkout, branch and commit the build came from, for Settings >
# Advanced to show (Sources/Settings/BuildInfo.swift). It describes the
# checkout when the build ran, not when the app launched.
#
# Release builds get none: it would ship the builder's checkout path.
set -eu

out="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildInfo.plist"
rm -f "$out"
[ "$CONFIGURATION" = "Release" ] && exit 0

mkdir -p "$(dirname "$out")"
plutil -create xml1 "$out"
plutil -insert checkout -string "$SRCROOT" "$out"
plutil -insert configuration -string "$CONFIGURATION" "$out"
plutil -insert builtAt -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$out"

# The rest needs git and a checkout; a source archive has neither.
cd "$SRCROOT"
commit=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
plutil -insert commit -string "$commit" "$out"
# Empty on a detached HEAD.
branch=$(git branch --show-current)
[ -n "$branch" ] && plutil -insert branch -string "$branch" "$out"
# Untracked files count separately: new sources are built, but so much else
# sits untracked in a checkout that one number would always say "changed".
modified=$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')
untracked=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
plutil -insert modifiedFiles -integer "$modified" "$out"
plutil -insert untrackedFiles -integer "$untracked" "$out"
