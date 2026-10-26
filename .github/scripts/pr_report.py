#!/usr/bin/env python3
"""Maintain one PR changelog comment from commit messages and PR diff.

Runs in pull_request_target from the trusted base branch, never evaluates PR code.
Standard library only; no external Python packages required.
"""
from __future__ import annotations

import html
import json
import os
import re
import sys
import urllib.error
import urllib.request

MARKER = "<!-- pr-report:v1 "
MARKER_RE = re.compile(r"^<!-- pr-report:v1 head=([0-9a-f]{40}) -->")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
CONVENTIONAL = re.compile(r"^([a-z][a-z0-9-]*)(?:\(([^)\r\n]+)\))?(!)?:\s*(.+)$")
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


def commit_line(c: dict, repo: str, host: str) -> str:
    sha = c["sha"]
    msg = (c.get("commit") or {}).get("message") or ""
    subject = msg.splitlines()[0] if msg else "(empty subject)"
    match = CONVENTIONAL.match(subject)
    if match:
        typ, scope, bang, title = match.groups()
        label = f"**{plain(typ)}**" + (f"({plain(scope)})" if scope else "") + ("!" if bang else "")
        label += f": {plain(title)}"
    else:
        label = plain(subject)
    return f"- [{inline_code(sha[:8])}]({host}/{repo}/commit/{sha}) {label}"


def new_test_cases(filename: str, patch: str | None) -> list[str]:
    """Candidate names from added lines only; intentionally not a full test inventory."""
    if not patch or not TEST_FILE.search(filename):
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


def changes_since(commits: list[dict], previous: str | None, head: str) -> tuple[str, list[dict]]:
    if not previous:
        return "First report: all PR commits are listed above.", []
    if previous == head:
        return "No new commits since previous report.", []
    shas = [c["sha"] for c in commits]
    if previous not in shas:
        return "History rewritten (rebase/force-push) or previous HEAD unavailable. Review the full diff again.", []
    return "New commits since previous report:", commits[shas.index(previous) + 1:]


def render(repo: str, number: int, head: str, commits: list[dict],
           files: list[dict], previous: str | None, host: str = "https://github.com",
           commit_cap: bool = False, file_cap: bool = False) -> str:
    if not SHA_RE.fullmatch(head):
        raise ValueError("Invalid PR head SHA")
    lines = [f"{MARKER}head={head} -->", "## PR change report", "",
             f"HEAD: {inline_code(head[:12])} · [PR checks]({host}/{repo}/pull/{number}/checks)",
             "Generated from GitHub commit messages and changed-file patches; not a CI or review approval.",
             "", f"### Commits ({len(commits)}{'+' if commit_cap else ''})"]
    lines += [commit_line(c, repo, host) for c in commits[:100]]
    if len(commits) > 100:
        lines.append(f"- … {len(commits)-100} more commits omitted for readability.")
    if commit_cap:
        lines.append("- **Warning:** Commit API cap reached; list may be incomplete.")
    if not commits:
        lines.append("- No commits returned by GitHub.")

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
    lines += ["", "### Commit context (author-reported)"]
    for kind, scope, value in context[:40]:
        lines.append(f"- **{kind}** {inline_code(scope)}: {plain(value)}")
    if not context:
        lines.append("- No contextual action lines found in commit bodies.")
    if len(context) > 40:
        lines.append(f"- … {len(context)-40} more context lines omitted.")

    tests = [f for f in files if TEST_FILE.search(f.get("filename", ""))]
    lines += ["", "### Changed test files (not necessarily all affected regression suites)"]
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

    status, delta = changes_since(commits, previous, head)
    lines += ["", "### Since previous report", status]
    lines += [commit_line(c, repo, host) for c in delta[:40]]
    if len(delta) > 40:
        lines.append(f"- … {len(delta)-40} further commits omitted.")
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
    number = int(event["pull_request"]["number"])
    api = API(os.environ["GITHUB_TOKEN"], os.getenv("GITHUB_API_URL", "https://api.github.com"))
    prefix = f"/repos/{repo}"
    # Fetch latest PR HEAD: a queued older event must not publish a stale report.
    pr = api.request("GET", f"{prefix}/pulls/{number}")
    head = pr["head"]["sha"]
    if not SHA_RE.fullmatch(head):
        raise ValueError("Invalid HEAD SHA")
    commits, commits_capped = api.paged(f"{prefix}/pulls/{number}/commits", 1000)
    files, files_capped = api.paged(f"{prefix}/pulls/{number}/files", 3000)
    comments, comments_capped = api.paged(f"{prefix}/issues/{number}/comments", 5000)
    if comments_capped:
        raise RuntimeError("Too many comments to identify sticky report safely")
    matches = [c for c in comments if MARKER_RE.match(c.get("body") or "")
               and c.get("user", {}).get("type") == "Bot"]
    current = matches[0] if matches else None
    previous = MARKER_RE.match(current["body"]).group(1) if current else None
    if previous == head:
        print(f"PR #{number}: report already up to date ({head[:12]})")
        return
    body = render(repo, number, head, commits, files, previous,
                  os.getenv("GITHUB_SERVER_URL", "https://github.com").rstrip("/"),
                  commits_capped, files_capped)
    if current:
        api.request("PATCH", f"{prefix}/issues/comments/{int(current['id'])}", {"body": body})
        print(f"PR #{number}: updated report ({head[:12]})")
    else:
        api.request("POST", f"{prefix}/issues/{number}/comments", {"body": body})
        print(f"PR #{number}: created report ({head[:12]})")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, RuntimeError) as err:
        print(f"pr-report failed: {err}", file=sys.stderr)
        sys.exit(1)
