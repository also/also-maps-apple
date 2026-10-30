#!/bin/sh
# Xcode Cloud runs this after cloning. The project is generated and signing
# lives in the gitignored Secrets.xcconfig, so write the team that owns the app.
# No API keys yet, so these builds launch but don't stream the Google tiles.
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

brew install xcodegen

cat > Config/Secrets.xcconfig <<SECRETS
DEVELOPMENT_TEAM = RU9XZG48W2
CODE_SIGN_STYLE = Automatic
SECRETS

xcodegen generate
