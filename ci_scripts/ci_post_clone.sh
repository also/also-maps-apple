#!/bin/sh
# Xcode Cloud runs this after cloning, to generate the project. xcodebuild doesn't
# read the workflow's DEVELOPMENT_TEAM environment variable as a build setting, so
# pass it on through the gitignored Secrets.xcconfig.
# No API keys here: Release builds get them at run time (CredentialStore).
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

brew install xcodegen

echo "DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM" > Config/Secrets.xcconfig

xcodegen generate
