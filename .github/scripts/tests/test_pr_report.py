import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error


SPEC = importlib.util.spec_from_file_location("pr_report", Path(__file__).resolve().parents[1] / "pr_report.py")
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)
HEAD = "a" * 40
BASE = "b" * 40
PR = {"number": 35, "state": "open", "draft": False, "title": "Routing refactor",
      "body": "Extract the pipeline", "head": {"sha": HEAD}, "base": {"sha": BASE}}
COMMITS = [{"sha": HEAD, "commit": {"message": "refactor(routing): extract pipeline\n\ndecision(api): use callbacks"}}]
FILES = [{"filename": "apps/routing/src/routing.erl", "status": "modified",
          "patch": "+compensation_test() ->\n+    ?assertEqual(ok, compensate())."}]


def existing_comment(login="github-actions[bot]"):
    return {"id": 42, "user": {"login": login, "type": "Bot"},
            "body": f"<!-- pr-report:v1 head={HEAD} -->\nPrevious useful note"}


class ModelTests(unittest.TestCase):
    def test_bounded_input_covers_files_and_reports_omissions(self):
        files = [{"filename": f"src/{i}.erl", "patch": "+\tюникод\n" * 10000} for i in range(105)]
        value = report.model_input(PR, COMMITS, files, False, False)
        self.assertLessEqual(len(value), report.MAX_INPUT_CHARS)
        data = json.loads(value)
        self.assertEqual(5, data["files_omitted"])
        self.assertEqual(100, len(data["files"]))
        self.assertTrue(all(f["patch"] and f["patch_shortened"] for f in data["files"]))

    def test_missing_patch_is_distinct_from_shortened_patch(self):
        data = json.loads(report.model_input(PR, [], [{"filename": "file.erl"}], True, True))
        self.assertTrue(data["commit_context_incomplete"])
        self.assertTrue(data["file_api_cap_reached"])
        self.assertTrue(data["files"][0]["patch_unavailable"])
        self.assertFalse(data["files"][0]["patch_shortened"])

    def test_credentials_are_redacted_from_input(self):
        pr = dict(PR, body="sk-or-v1-" + "x" * 40)
        self.assertNotIn("x" * 40, report.model_input(pr, [], [], False, False))

    def invoke(self, result):
        response = MagicMock()
        response.__enter__.return_value = io.StringIO(json.dumps(result))
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": "test-secret"}), \
                patch.object(report.urllib.request, "urlopen", return_value=response) as urlopen:
            note = report.generate_note(PR, COMMITS, FILES, report.DEFAULT_MODEL)
        return note, urlopen.call_args.args[0]

    def test_free_request_and_inert_output(self):
        note, request = self.invoke({"choices": [{"finish_reason": "stop", "message": {
            "content": "Пайплайн <!-- fake marker --> @team test-secret"}}]})
        payload = json.loads(request.data)
        self.assertEqual(report.DEFAULT_MODEL, payload["model"])
        self.assertEqual({"prompt": 0, "completion": 0, "request": 0}, payload["provider"]["max_price"])
        self.assertNotIn("tools", payload)
        self.assertNotIn("test-secret", note)
        self.assertNotIn("<!--", note)
        self.assertNotIn("@team", note)

    def test_paid_model_never_makes_a_request(self):
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": "test-secret"}), \
                patch.object(report.urllib.request, "urlopen") as urlopen:
            with self.assertRaisesRegex(ValueError, "free model"):
                report.generate_note(PR, [], [], "vendor/paid")
            urlopen.assert_not_called()

    def test_incomplete_or_empty_answers_are_not_published(self):
        for result in ({}, {"choices": []}, {"choices": [{"finish_reason": "length", "message": {"content": "Partial"}}]},
                       {"choices": [{"finish_reason": "stop", "message": {"content": ""}}]}):
            with self.subTest(result=result), self.assertRaisesRegex(RuntimeError, "complete note"):
                self.invoke(result)

    def test_rate_limit_error_does_not_leak_response(self):
        error = urllib.error.HTTPError("https://openrouter.ai", 429, "sensitive upstream message", {}, None)
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": "test-secret"}), \
                patch.object(report.urllib.request, "urlopen", side_effect=error) as urlopen:
            with self.assertRaisesRegex(RuntimeError, "^OpenRouter HTTP 429$"):
                report.generate_note(PR, [], [], report.DEFAULT_MODEL)
            self.assertEqual(1, urlopen.call_count)

    def test_eunit_inside_source_is_detected(self):
        self.assertEqual(["compensation_test"], report.new_test_cases(FILES[0]["filename"], FILES[0]["patch"]))
        body = report.render("valitydev/paycore", 35, HEAD, COMMITS, FILES, None, note="Note")
        self.assertIn("compensation\\_test", body)
        self.assertIn("Commit context (author-reported)", body)
        self.assertNotIn("### Commits", body)
        self.assertNotIn("extract pipeline", body)


class LifecycleTests(unittest.TestCase):
    def run_event(self, action, comments=None, note="Новая записка", draft=False, label=None, snapshots=None):
        self.api = MagicMock()
        self.snapshots = iter(snapshots) if snapshots else None

        def request(method, path, data=None):
            if method == "GET":
                return next(self.snapshots) if self.snapshots else copy.deepcopy(PR)
            return {}

        def paged(path, cap):
            if path.endswith("/comments"):
                return comments or [], False
            if path.endswith("/commits"):
                return COMMITS, False
            if path.endswith("/files"):
                return FILES, False
            raise AssertionError(path)

        self.api.request.side_effect = request
        self.api.paged.side_effect = paged
        event = {"action": action, "pull_request": dict(PR, draft=draft), "label": {"name": label}}
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps(event))
            env = {"GITHUB_REPOSITORY": "valitydev/paycore", "GITHUB_TOKEN": "github-token",
                   "GITHUB_EVENT_PATH": str(event_path)}
            with patch.dict(os.environ, env, clear=True), patch.object(report, "API", return_value=self.api), \
                    patch.object(report, "generate_note", side_effect=note if isinstance(note, Exception) else None,
                                 return_value=note) as generate:
                self.generate = generate
                report.main()

    def mutations(self):
        return [c for c in self.api.request.call_args_list if c.args[0] != "GET"]

    def test_initial_report_is_created_once(self):
        self.run_event("opened")
        self.assertEqual(["POST"], [c.args[0] for c in self.mutations()])
        self.generate.assert_called_once()

    def test_draft_waits_until_ready(self):
        self.run_event("opened", draft=True)
        self.generate.assert_not_called()
        self.api.request.assert_not_called()
        self.run_event("ready_for_review")
        self.assertEqual("POST", self.mutations()[0].args[0])

    def test_ready_again_does_not_regenerate_even_with_new_head(self):
        comment = existing_comment()
        comment["body"] = comment["body"].replace(HEAD, "c" * 40)
        self.run_event("ready_for_review", comments=[comment])
        self.generate.assert_not_called()
        self.assertFalse(self.mutations())

    def test_push_edits_reopen_and_other_labels_do_not_use_quota(self):
        for action in ("synchronize", "edited", "reopened", "labeled", "unlabeled"):
            with self.subTest(action=action):
                self.run_event(action, label="unrelated")
                self.api.request.assert_not_called()
                self.generate.assert_not_called()

    def test_refresh_updates_same_comment_even_on_same_head_and_removes_label(self):
        self.run_event("labeled", comments=[existing_comment()], label=report.REFRESH_LABEL)
        mutations = self.mutations()
        self.assertEqual(["PATCH", "DELETE"], [c.args[0] for c in mutations])
        self.assertTrue(mutations[0].args[1].endswith("/comments/42"))
        self.assertIn("Новая записка", mutations[0].args[2]["body"])
        self.assertTrue(mutations[1].args[1].endswith("/labels/refresh-pr-report"))

    def test_label_can_create_report_for_an_existing_pr(self):
        self.run_event("labeled", label=report.REFRESH_LABEL)
        self.assertEqual(["POST", "DELETE"], [c.args[0] for c in self.mutations()])

    def test_failed_refresh_retains_previous_note_and_label(self):
        with self.assertRaisesRegex(RuntimeError, "previous comment retained"):
            self.run_event("labeled", comments=[existing_comment()], label=report.REFRESH_LABEL,
                           note=RuntimeError("OpenRouter HTTP 429"))
        self.assertFalse(self.mutations())

    def test_initial_failure_publishes_factual_context_and_allows_retry(self):
        with self.assertRaisesRegex(RuntimeError, "factual report published"):
            self.run_event("opened", note=RuntimeError("OPENROUTER_API_KEY is not configured"))
        mutations = self.mutations()
        self.assertEqual(["POST"], [c.args[0] for c in mutations])
        self.assertIn("AI-записка недоступна", mutations[0].args[2]["body"])

    def test_other_bot_cannot_impersonate_report_owner(self):
        self.run_event("opened", comments=[existing_comment("another[bot]")])
        self.assertEqual("POST", self.mutations()[0].args[0])

    def test_stale_head_is_not_published(self):
        changed = copy.deepcopy(PR)
        changed["head"]["sha"] = "d" * 40
        with self.assertRaisesRegex(RuntimeError, "changed during generation"):
            self.run_event("opened", snapshots=[PR, PR, changed])
        self.assertFalse(self.mutations())

    def test_changed_base_before_generation_does_not_use_quota(self):
        changed = copy.deepcopy(PR)
        changed["base"]["sha"] = "d" * 40
        with self.assertRaisesRegex(RuntimeError, "changed while collecting"):
            self.run_event("opened", snapshots=[PR, changed])
        self.generate.assert_not_called()
        self.assertFalse(self.mutations())


if __name__ == "__main__":
    unittest.main()
