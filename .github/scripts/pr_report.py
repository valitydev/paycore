#!/usr/bin/env python3
"""Maintain one PR note, initially or on the refresh-pr-report label.

Runs in pull_request_target from the trusted base branch, never evaluates PR code.
Standard library only; no external Python packages required.
"""
from __future__ import annotations

import html
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

MARKER = "<!-- pr-report:v1 "
MARKER_RE = re.compile(r"^<!-- pr-report:v1 head=([0-9a-f]{40}) -->")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REFRESH_LABEL = "refresh-pr-report"
DEFAULT_MODEL = "nvidia/nemotron-3.5-super-vl:free"
MAX_INPUT_CHARS = 120000
PROMPT_PATH = Path(__file__).resolve().parents[1] / "prompts" / "pr-report.md"
CONTEXT = re.compile(r"^(intent|decision|rejected|constraint|learned)\(([^)\r\n]+)\):\s*(.+)$")
TEST_FILE = re.compile(
    r"(?:^|/)(?:tests?|specs?|__tests__)/|"
    r"(?:\.test|\.spec)\.[jt]sx?$|(?:_test\.go|_tests?\.erl|_SUITE\.erl)$|"
    r"(?:Tests?\.cs|Tests?\.java|Tests?\.kt)$",
    re.IGNORECASE,
)
TEST_CALL = re.compile(r"\b(?:it|test)(?:\.(?:skip|only|todo))?\s*\(\s*(['\"`])(.+?)\1")
PY_TEST = re.compile(r"\b(?:async\s+)?def\s+(test_\w+)\s*\(")
GO_TEST = re.compile(r"\bfunc\s+(Test[A-Za-z0-9_]+)\s*\(")
ERL_TEST = re.compile(r"^([a-z][A-Za-z0-9_]*_test_?)\s*\(")
CS_TEST = re.compile(r"\b(?:public|private|protected|internal)\s+(?:(?:async|static)\s+)*(?:\w+(?:<[^>]+>)?\s+)+([A-Za-z_]\w*)\s*\(")
SECRET = re.compile(r"\b(?:gh[pousr]_[\w]{16,}|github_pat_[\w]{16,}|AKIA[A-Z0-9]{16}|sk-[A-Za-z0-9_-]{20,})\b")


def plain(data: object, limit: int = 250) -> str:
    """Turn untrusted commit metadata into a single escaped Markdown line."""
    value = re.sub(r"[\x00-\x1f\x7f]+", " ", str(data or ""))
    value = SECRET.sub("[REDACTED TOKEN]", " ".join(value.split()))
    value = value[:limit] + ("…" if len(value) > limit else "")
    value = html.escape(value, quote=False)
    return re.sub(r"([\\`*_{}\[\]()#+!|~>])", r"\\\1", value)


def inline_code(value: str, limit: int = 220) -> str:
    value = SECRET.sub("[REDACTED TOKEN]", str(value)[:limit])
    return "`" + value.replace("`", "'").replace("\n", " ").replace("<", "&lt;").replace(">", "&gt;") + "`"


def new_test_cases(filename: str, patch: str | None) -> list[str]:
    """Candidate names from added lines only; intentionally not a full test inventory."""
    if not patch or not (TEST_FILE.search(filename) or filename.endswith(".erl")):
        return []
    added = [line[1:].strip() for line in patch.splitlines()
             if line.startswith("+") and not line.startswith("+++")]
    result: list[str] = []
    pending_attribute = False
    for line in added:
        if filename.endswith(".cs") and re.search(r"\[(?:Fact|Theory|Test|TestMethod|TestCase)(?:\]|\()", line):
            pending_attribute = True
            continue
        if pending_attribute:
            if match := CS_TEST.search(line):
                result.append(match.group(1))
                pending_attribute = False
                continue
            if line and not line.startswith(("[", "//")):
                pending_attribute = False
        for pattern in (TEST_CALL, PY_TEST, GO_TEST):
            if match := pattern.search(line):
                result.append(match.group(2) if pattern is TEST_CALL else match.group(1))
        if filename.endswith(".erl") and (match := ERL_TEST.match(line)):
            result.append(match.group(1))
    return list(dict.fromkeys(result))


def changes_since(commits: list[dict], previous: str | None, head: str) -> str:
    if not previous:
        return "Initial report. Further updates require the refresh-pr-report label."
    if previous == head:
        return "Regenerated on request for the same HEAD."
    shas = [c["sha"] for c in commits]
    if previous not in shas:
        return "History rewritten (rebase/force-push) or previous HEAD unavailable. Review the full diff again."
    return f"Updated from {previous[:12]}: {len(commits) - shas.index(previous) - 1} new commits."


def model_input(pr: dict, commits: list[dict], files: list[dict],
                commit_cap: bool, file_cap: bool) -> str:
    """Bound one request, sharing patch space across files rather than taking a diff prefix."""
    selected = files[:100]
    recent_commits = commits[-40:]
    data = {
        "title": (pr.get("title") or "")[:500],
        "description": (pr.get("body") or "")[:4000],
        "base_sha": pr["base"]["sha"], "head_sha": pr["head"]["sha"],
        "commits": [(c.get("commit", {}).get("message") or "")[:600] for c in recent_commits],
        "commit_context_incomplete": commit_cap or len(commits) > 40 or any(
            len(c.get("commit", {}).get("message") or "") > 600 for c in recent_commits),
        "description_shortened": len(pr.get("body") or "") > 4000,
        "files_omitted": len(files) - len(selected), "file_api_cap_reached": file_cap,
        "files": [{
            "filename": f["filename"][:400], "previous_filename": (f.get("previous_filename") or "")[:400],
            "status": f.get("status"), "patch_unavailable": f.get("patch") is None,
            "patch_shortened": bool(f.get("patch")), "patch": "",
        } for f in selected],
    }
    # Budget serialized characters, including JSON escaping, not just source lengths.
    remaining = MAX_INPUT_CHARS - len(json.dumps(data, ensure_ascii=False)) - 1000
    for index, (source, target) in enumerate(zip(selected, data["files"])):
        patch = source.get("patch") or ""
        allowance = min(24000, max(0, remaining // (len(selected) - index)))
        low, high = 0, min(len(patch), allowance)
        while low < high:
            midpoint = (low + high + 1) // 2
            if len(json.dumps(patch[:midpoint], ensure_ascii=False)) - 2 <= allowance:
                low = midpoint
            else:
                high = midpoint - 1
        excerpt = patch[:low]
        target["patch"] = excerpt
        target["patch_shortened"] = len(excerpt) < len(patch)
        remaining -= len(json.dumps(excerpt, ensure_ascii=False)) - 2
    result = SECRET.sub("[REDACTED TOKEN]", json.dumps(data, ensure_ascii=False))
    if len(result) > MAX_INPUT_CHARS:
        raise ValueError("Model input exceeds the configured limit")
    return result


def generate_note(pr: dict, commits: list[dict], files: list[dict], model: str,
                  commit_cap: bool = False, file_cap: bool = False) -> str:
    key = os.getenv("OPENROUTER_API_KEY")
    if not key:
        raise RuntimeError("OPENROUTER_API_KEY is not configured")
    if not (model.endswith(":free") or model == "openrouter/free"):
        raise ValueError("PR_REPORT_MODEL must select a free model")
    payload = {
        "model": model, "max_tokens": 4096,
        "provider": {"max_price": {"prompt": 0, "completion": 0, "request": 0}},
        "messages": [
            {"role": "system", "content": PROMPT_PATH.read_text(encoding="utf-8")},
            {"role": "user", "content": model_input(pr, commits, files, commit_cap, file_cap)},
        ],
    }
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        # Do not log upstream bodies, prompts, or credentials.
        raise RuntimeError(f"OpenRouter HTTP {exc.code}") from None
    except (OSError, ValueError):
        raise RuntimeError("OpenRouter connection or response error") from None
    try:
        choice = result["choices"][0]
        note = choice["message"]["content"]
        if choice.get("finish_reason") != "stop" or not isinstance(note, str) or not note.strip():
            raise ValueError
    except (KeyError, IndexError, TypeError, ValueError):
        raise RuntimeError("OpenRouter returned no complete note") from None
    note = note.replace(key, "[REDACTED TOKEN]")
    note = SECRET.sub("[REDACTED TOKEN]", note.strip())
    # Keep generated text inert: no HTML markers or GitHub notification mentions.
    note = html.escape(note, quote=False).replace("@", "@\u200b")
    if len(note) > 12000:
        raise RuntimeError("OpenRouter note exceeds the output limit")
    return note


def render(repo: str, number: int, head: str, commits: list[dict],
           files: list[dict], previous: str | None, host: str = "https://github.com",
           commit_cap: bool = False, file_cap: bool = False,
           note: str | None = None, model: str = DEFAULT_MODEL) -> str:
    if not SHA_RE.fullmatch(head):
        raise ValueError("Invalid PR head SHA")
    lines = [f"{MARKER}head={head} -->", "## PR change report", "",
             f"HEAD: {inline_code(head[:12])} · [PR checks]({host}/{repo}/pull/{number}/checks)",
             "Snapshot of the HEAD above; pushes do not refresh this note.",
             f"Add {inline_code(REFRESH_LABEL)} to update this same comment.", "",
             "### Пояснительная записка", "",
             note or "AI-записка недоступна: проверьте настройку ключа и журнал workflow, затем добавьте refresh-pr-report."]
    if note:
        lines += ["", f"_Generated by {inline_code(model)} from PR patches and author-reported context; verify against the diff._"]
    lines += ["", f"[Commits]({host}/{repo}/pull/{number}/commits) · [Files changed]({host}/{repo}/pull/{number}/files)"]
    if commit_cap:
        lines.append("- **Warning:** Commit API cap reached; author-reported context may be incomplete.")

    context = []
    seen = set()
    for c in commits:
        msg = (c.get("commit") or {}).get("message") or ""
        for line in msg.splitlines()[1:]:
            if match := CONTEXT.match(line.strip()):
                item = match.groups()
                if item not in seen:
                    seen.add(item)
                    context.append(item)
    lines += ["", "<details>", "<summary>Commit context (author-reported)</summary>", ""]
    for kind, scope, value in context[:40]:
        lines.append(f"- **{kind}** {inline_code(scope)}: {plain(value)}")
    if not context:
        lines.append("- No contextual action lines found in commit bodies.")
    if len(context) > 40:
        lines.append(f"- … {len(context)-40} more context lines omitted.")
    lines += ["", "</details>"]

    tests = [f for f in files if TEST_FILE.search(f.get("filename", ""))
             or new_test_cases(f["filename"], f.get("patch"))]
    lines += ["", "<details>", "<summary>Test changes (heuristic)</summary>", "",
              "### Changed test files (not necessarily all affected regression suites)"]
    for f in tests[:80]:
        lines.append(f"- {inline_code(f['filename'])} — {plain(f.get('status', 'unknown'))}")
    if not tests:
        lines.append("- No changed test files detected. This **does not** mean regressions are covered.")
    if len(tests) > 80:
        lines.append(f"- … {len(tests)-80} more changed test files omitted.")
    if file_cap:
        lines.append("- **Warning:** GitHub file cap reached; this list may be incomplete.")

    cases = [(f['filename'], case) for f in tests for case in new_test_cases(f['filename'], f.get('patch'))]
    lines += ["", "### New test-case candidates (heuristic; verify assertions)"]
    for filename, case in cases[:80]:
        lines.append(f"- {inline_code(filename)} → {plain(case)}")
    if len(cases) > 80:
        lines.append(f"- … {len(cases)-80} more candidates omitted.")
    if not cases:
        lines.append("- No new cases recognized; this is **not** proof that none were added.")
    missing = sum(1 for f in tests if f.get('patch') is None)
    if missing:
        lines.append(f"- Patch unavailable for {missing} test files; detection can be incomplete.")

    lines += ["", "</details>", "", "### Since previous report", changes_since(commits, previous, head)]
    lines += ["", "---", "_Review the full diff, CI on the current HEAD, and deployment implications separately._"]
    body = "\n".join(lines)
    if len(body) > 60000:
        body = body[:59400] + "\n\n_Report truncated; see GitHub's Commits and Files changed tabs._"
    return body


class API:
    def __init__(self, token: str, base: str):
        self.token = token
        self.base = base.rstrip("/")

    def request(self, method: str, path: str, data: dict | None = None):
        payload = json.dumps(data).encode("utf-8") if data is not None else None
        req = urllib.request.Request(
            self.base + path,
            data=payload,
            headers={"Authorization": f"Bearer {self.token}",
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28",
                     "User-Agent": "pr-report-action/1.0", **({"Content-Type": "application/json"} if data is not None else {})},
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=25) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"GitHub API {method} {path}: HTTP {exc.code}") from exc

    def paged(self, path: str, cap: int) -> tuple[list[dict], bool]:
        output = []
        for page in range(1, cap // 100 + 1):
            separator = "&" if "?" in path else "?"
            part = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            if not isinstance(part, list):
                raise ValueError("Unexpected GitHub API response")
            output.extend(part)
            if len(part) < 100:
                return output, False
        return output, True


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("Invalid repository")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as file:
        event = json.load(file)
    action = event.get("action")
    refresh = action == "labeled" and event.get("label", {}).get("name") == REFRESH_LABEL
    if event["pull_request"].get("draft") or not (action in ("opened", "ready_for_review") or refresh):
        print("PR report: event does not request generation")
        return
    number = int(event["pull_request"]["number"])
    api = API(os.environ["GITHUB_TOKEN"], os.getenv("GITHUB_API_URL", "https://api.github.com"))
    prefix = f"/repos/{repo}"
    # Fetch latest PR HEAD: a queued older event must not publish a stale report.
    pr = api.request("GET", f"{prefix}/pulls/{number}")
    if pr.get("state") != "open" or pr.get("draft"):
        print(f"PR #{number}: closed or draft; skipping report")
        return
    head = pr["head"]["sha"]
    if not SHA_RE.fullmatch(head):
        raise ValueError("Invalid HEAD SHA")
    comments, comments_capped = api.paged(f"{prefix}/issues/{number}/comments", 5000)
    if comments_capped:
        raise RuntimeError("Too many comments to identify sticky report safely")
    matches = [c for c in comments if MARKER_RE.match(c.get("body") or "")
               and c.get("user", {}).get("login") == "github-actions[bot]"]
    current = matches[0] if matches else None
    previous = MARKER_RE.match(current["body"]).group(1) if current else None
    if current and not refresh:
        print(f"PR #{number}: initial report already exists; use {REFRESH_LABEL} to update")
        return
    commits, commits_capped = api.paged(f"{prefix}/pulls/{number}/commits", 1000)
    files, files_capped = api.paged(f"{prefix}/pulls/{number}/files", 3000)
    # A PR may change while its paginated input is being collected.
    latest = api.request("GET", f"{prefix}/pulls/{number}")
    if (latest["head"]["sha"], latest["base"]["sha"]) != (head, pr["base"]["sha"]):
        raise RuntimeError("PR changed while collecting input; request a fresh report")
    model = os.getenv("PR_REPORT_MODEL") or DEFAULT_MODEL
    note = None
    try:
        note = generate_note(pr, commits, files, model, commits_capped, files_capped)
    except (OSError, ValueError, RuntimeError) as exc:
        # A failed refresh must leave the last useful note intact, and keep the
        # label for a workflow rerun. First reports can still show factual context.
        print(f"AI note unavailable: {exc}", file=sys.stderr)
        if current:
            raise RuntimeError("AI refresh failed; previous comment retained") from None
    body = render(repo, number, head, commits, files, previous,
                  os.getenv("GITHUB_SERVER_URL", "https://github.com").rstrip("/"),
                  commits_capped, files_capped, note, model)
    latest = api.request("GET", f"{prefix}/pulls/{number}")
    if latest.get("state") != "open" or latest.get("draft") or (
        latest["head"]["sha"], latest["base"]["sha"]
    ) != (head, pr["base"]["sha"]):
        raise RuntimeError("PR changed during generation; request a fresh report")
    if current:
        api.request("PATCH", f"{prefix}/issues/comments/{int(current['id'])}", {"body": body})
        print(f"PR #{number}: updated report ({head[:12]})")
    else:
        api.request("POST", f"{prefix}/issues/{number}/comments", {"body": body})
        print(f"PR #{number}: created report ({head[:12]})")
    if not note:
        raise RuntimeError("AI note unavailable; factual report published, generation can be retried with the label")
    if refresh:
        api.request("DELETE", f"{prefix}/issues/{number}/labels/{REFRESH_LABEL}")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, RuntimeError) as err:
        print(f"pr-report failed: {err}", file=sys.stderr)
        sys.exit(1)
