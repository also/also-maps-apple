"""Create an annotated build/<number> tag using Xcode Cloud's exact commit."""

import json
import os
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    token = os.environ.get("GITHUB_BUILD_TAG_TOKEN", "")
    if not token:
        raise RuntimeError("Set the secret GITHUB_BUILD_TAG_TOKEN in the Xcode Cloud workflow.")
    number = os.environ.get("CI_BUILD_NUMBER", "")
    commit = os.environ.get("CI_COMMIT", "")
    if not re.fullmatch(r"[0-9]+", number) or not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        raise RuntimeError("CI_BUILD_NUMBER or CI_COMMIT is missing or invalid.")

    tag = f"build/{number}"
    api = "https://api.github.com/repos/also/also-maps-apple/git"

    def request(path, data=None):
        req = Request(
            f"{api}/{path}",
            data=None if data is None else json.dumps(data).encode("utf-8"),
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "also-maps-xcode-cloud",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        with urlopen(req, timeout=30) as response:
            return json.load(response)

    def existing_commit():
        try:
            obj = request(f"ref/tags/{tag}")["object"]
        except HTTPError as error:
            if error.code == 404:
                return None
            raise
        if obj["type"] == "tag":
            obj = request(f"tags/{obj['sha']}")["object"]
        if obj["type"] != "commit":
            raise RuntimeError(f"{tag} does not point directly to a commit or annotated commit tag.")
        return obj["sha"]

    def verify_existing(sha):
        if sha.lower() != commit.lower():
            raise RuntimeError(f"Refusing to move {tag}: it points to {sha}, not {commit}.")
        print(f"{tag} already points to {commit}.")

    existing = existing_commit()
    if existing is not None:
        verify_existing(existing)
        return

    message = (
        f"Xcode Cloud build {number}\n\n"
        f"Commit: {commit}\n"
        f"Workflow: {os.environ.get('CI_WORKFLOW', '')}\n"
        f"Build: {os.environ['CI_BUILD_URL']}\n"
    )
    obj = request("tags", {"tag": tag, "message": message, "object": commit, "type": "commit"})
    try:
        request("refs", {"ref": f"refs/tags/{tag}", "sha": obj["sha"]})
    except HTTPError as error:
        # Another platform's archive may have created the ref concurrently.
        if error.code != 422:
            raise
        existing = existing_commit()
        if existing is None:
            raise
        verify_existing(existing)
        return
    print(f"Created {tag} at {commit}.")


if __name__ == "__main__":
    try:
        main()
    except HTTPError as error:
        # Don't dump requests or headers: they contain the workflow's token.
        sys.exit(f"Build tagging failed: GitHub returned HTTP {error.code}. Check token access and tag rules.")
    except URLError:
        sys.exit("Build tagging failed: unable to reach GitHub.")
    except (RuntimeError, KeyError) as error:
        sys.exit(f"Build tagging failed: {error}")
