#!/bin/sh
# Xcode Cloud runs this after cloning. The project is generated and signing
# lives in the gitignored Secrets.xcconfig; set DEVELOPMENT_TEAM in the workflow.
# No API keys yet, so these builds launch but don't stream the Google tiles.
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

brew install xcodegen

cat > Config/Secrets.xcconfig <<SECRETS
DEVELOPMENT_TEAM = $DEVELOPMENT_TEAM
CODE_SIGN_STYLE = Automatic
SECRETS

xcodegen generate
