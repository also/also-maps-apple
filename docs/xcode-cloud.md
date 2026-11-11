# Xcode Cloud build tags

`ci_scripts/ci_post_xcodebuild.sh` creates an annotated `build/<number>` Git tag
after a successful archive from `main`. For example, Xcode Cloud build 42 gets
`build/42`, pointing at `CI_COMMIT`, with the workflow and build URL in its
annotation. It checks `CI_XCODEBUILD_EXIT_CODE` explicitly and requires an
existing archive; failed actions, non-archive actions, other branches and PRs
don't create tags.

This records that at least one archive action succeeded. It does not certify
that every platform passed, or that later TestFlight/App Store processing or
distribution succeeded. Multiple platform archives can create the same tag:
an existing tag is accepted only when it points at the same commit, and tags
are never moved. Authentication, network and conflicting-tag errors fail the
hook so a missing build tag is visible.

## Authentication

Create a [fine-grained GitHub personal access token](https://github.com/settings/personal-access-tokens/new):

1. Choose **also** as the resource owner.
2. Choose **Only select repositories**, then **also-maps-apple**.
3. Set repository permission **Contents: Read and write**. Metadata read access
   is included automatically; no other permissions are needed for this repo.
4. Set an expiration and generate the token. If the organization requires
   approval, have an owner approve it before using it.
5. In App Store Connect, open the app's **Xcode Cloud** tab, edit each workflow
   that archives `main`, and add `GITHUB_BUILD_TAG_TOKEN` under **Environment →
   Environment Variables**, with the token as its value and **Secret** enabled.

The value is the token alone, without a username or `Bearer` prefix. The token's
owner must have write access to this repository, and any repository tag rules
must permit that account to create `build/*`. Rotate the workflow secret when
the token expires. Xcode Cloud's existing GitHub connection does not expose its
credentials to build scripts, so this separate token is needed.

Keep this workflow triggered by branch changes on `main`. If a workflow also
builds on tag changes, exclude `build/*` from its tag triggers to avoid creating
another build for every tag. Add the secret before merging this change: a
successful archive without it fails the tagging hook.

## Lookup

```
git fetch origin --tags
git show build/42                    # build → commit and Cloud build URL
git tag --points-at <commit-sha>      # commit → build(s)
git diff build/41 build/42           # changes between builds
```

An app's marketing version (such as `1.0`) can cover several builds. Use the
build number from TestFlight or App Store Connect to identify the exact commit.
This does not change the app's version or build-number settings.

## Validation

Run `python3 -m unittest discover -s ci_scripts/tests`. The tests use mocked
GitHub responses and never create real tags.

References: Apple's [script hooks](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
[environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference),
[source-control security](https://developer.apple.com/xcode-cloud/security/), and
GitHub's [Git references API](https://docs.github.com/en/rest/git/refs).
