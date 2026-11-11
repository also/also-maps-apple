#!/bin/sh
# The hook runs for every action, including failed actions. Only tag archives
# from main, never PRs (even if the destination branch is main).
set -eu

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ] ||
   [ "${CI_BRANCH:-}" != "main" ] ||
   [ -n "${CI_PULL_REQUEST_NUMBER:-}" ] ||
   [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
    echo "Skipping build tag: not an Xcode Cloud archive from main."
    exit 0
fi

if [ "${CI_XCODEBUILD_EXIT_CODE:-}" != "0" ]; then
    echo "Skipping build tag: xcodebuild did not succeed."
    exit 0
fi

if [ ! -d "${CI_ARCHIVE_PATH:-}" ]; then
    echo "Cannot tag build: CI_ARCHIVE_PATH is not an existing archive." >&2
    exit 1
fi

# Keep the helper beside this hook: source files elsewhere in the checkout
# aren't guaranteed to be available in the post-xcodebuild environment.
exec python3 "$(dirname "$0")/tag_build.py"
