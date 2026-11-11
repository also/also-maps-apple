"""Network-free checks for the Cloud hook and GitHub tag creation."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


CI_SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("tag_build", CI_SCRIPTS / "tag_build.py")
tag_build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tag_build)
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
ENV = {
    "GITHUB_BUILD_TAG_TOKEN": "test-token",
    "CI_BUILD_NUMBER": "42",
    "CI_COMMIT": COMMIT,
    "CI_BUILD_URL": "https://appstoreconnect.apple.com/build/42",
    "CI_WORKFLOW": "Main archives",
}


def http_error(code):
    return HTTPError("https://api.github.com/test", code, "Test error", {}, None)


def response(obj):
    return io.BytesIO(json.dumps(obj).encode())


def ref(sha, kind="commit"):
    return {"object": {"type": kind, "sha": sha}}


class GitHubTagsTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, ENV, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_responses(self, *items):
        with patch.object(tag_build, "urlopen", side_effect=items) as api:
            with patch("sys.stdout", new_callable=io.StringIO):
                tag_build.main()
        return api.call_args_list

    def test_creates_annotated_tag_at_exact_cloud_commit(self):
        calls = self.run_responses(http_error(404), response({"sha": "tag-object"}), response({}))
        requests = [call.args[0] for call in calls]
        self.assertTrue(requests[0].full_url.endswith("/ref/tags/build/42"))
        annotation = json.loads(requests[1].data)
        self.assertEqual(annotation["object"], COMMIT)
        self.assertEqual(annotation["type"], "commit")
        self.assertEqual(annotation["tag"], "build/42")
        self.assertIn(ENV["CI_BUILD_URL"], annotation["message"])
        self.assertIn(ENV["CI_WORKFLOW"], annotation["message"])
        self.assertEqual(json.loads(requests[2].data), {
            "ref": "refs/tags/build/42", "sha": "tag-object",
        })
        for request in requests:
            self.assertNotIn(ENV["GITHUB_BUILD_TAG_TOKEN"], request.full_url)
            self.assertEqual(request.get_header("Authorization"), "Bearer test-token")

    def test_existing_annotated_tag_is_a_noop(self):
        calls = self.run_responses(response(ref("tag-object", "tag")), response(ref(COMMIT)))
        self.assertTrue(all(call.args[0].get_method() == "GET" for call in calls))

    def test_existing_lightweight_tag_is_a_noop(self):
        self.assertEqual(len(self.run_responses(response(ref(COMMIT)))), 1)

    def test_conflicting_tag_is_never_moved(self):
        with patch.object(tag_build, "urlopen", return_value=response(ref(OTHER_COMMIT))) as api:
            with self.assertRaisesRegex(RuntimeError, "Refusing to move"):
                tag_build.main()
        self.assertEqual(api.call_count, 1)

    def test_concurrent_archive_creates_same_tag(self):
        calls = self.run_responses(
            http_error(404), response({"sha": "unused-tag-object"}), http_error(422),
            response(ref("winning-tag-object", "tag")), response(ref(COMMIT)),
        )
        self.assertEqual(len(calls), 5)

    def test_concurrent_conflicting_tag_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Refusing to move"):
            self.run_responses(
                http_error(404), response({"sha": "tag-object"}), http_error(422),
                response(ref(OTHER_COMMIT)),
            )

    def test_validation_error_without_existing_tag_fails(self):
        with self.assertRaises(HTTPError):
            self.run_responses(
                http_error(404), response({"sha": "tag-object"}), http_error(422), http_error(404),
            )

    def test_auth_error_fails_without_creating_a_tag(self):
        with patch.object(tag_build, "urlopen", side_effect=http_error(403)) as api:
            with self.assertRaises(HTTPError):
                tag_build.main()
        self.assertEqual(api.call_count, 1)

    def test_missing_token_and_invalid_metadata_make_no_requests(self):
        for changes in ({"GITHUB_BUILD_TAG_TOKEN": ""}, {"CI_COMMIT": ""}, {"CI_BUILD_NUMBER": "../42"}):
            with self.subTest(changes=changes), patch.dict(os.environ, changes):
                with patch.object(tag_build, "urlopen") as api:
                    with self.assertRaises(RuntimeError):
                        tag_build.main()
                    api.assert_not_called()


class HookTests(unittest.TestCase):
    def run_hook(self, changes):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hook = root / "ci_post_xcodebuild.sh"
            hook.write_bytes((CI_SCRIPTS / hook.name).read_bytes())
            # Proves the real shell guards reach the helper only when eligible.
            (root / "tag_build.py").write_text("print('TAG_HELPER_CALLED')\n")
            archive = root / "Also Maps.xcarchive"
            archive.mkdir()
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("CI_", "GITHUB_BUILD_"))}
            env.update({
                "CI_XCODE_CLOUD": "TRUE", "CI_BRANCH": "main",
                "CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0",
                "CI_ARCHIVE_PATH": str(archive),
            })
            env.update(changes)
            return subprocess.run(["/bin/sh", str(hook)], env=env, cwd="/",
                                  text=True, capture_output=True)

    def test_successful_archive_calls_helper_from_any_working_directory(self):
        result = self.run_hook({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TAG_HELPER_CALLED", result.stdout)

    def test_ineligible_actions_never_call_helper(self):
        for changes in (
            {"CI_XCODEBUILD_EXIT_CODE": "65"}, {"CI_XCODEBUILD_EXIT_CODE": ""},
            {"CI_XCODEBUILD_ACTION": "build"}, {"CI_XCODEBUILD_ACTION": "test-without-building"},
            {"CI_BRANCH": "feature"}, {"CI_BRANCH": ""},
            {"CI_PULL_REQUEST_NUMBER": "71"}, {"CI_XCODE_CLOUD": ""},
        ):
            with self.subTest(changes=changes):
                result = self.run_hook(changes)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("TAG_HELPER_CALLED", result.stdout)

    def test_missing_archive_fails_without_calling_helper(self):
        result = self.run_hook({"CI_ARCHIVE_PATH": "/nonexistent/archive"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("TAG_HELPER_CALLED", result.stdout)


if __name__ == "__main__":
    unittest.main()
