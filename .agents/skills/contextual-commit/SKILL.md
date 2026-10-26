---
name: contextual-commit
description: >-
  Write Conventional Commits with contextual action lines that preserve why
  a change was made — intent, decisions, rejected alternatives, constraints,
  and learnings. Use when the user asks to commit, create a commit message,
  finish a task with a git commit, or when recalling prior decisions from
  commit history before proposing an approach.
---

# Contextual Commits

Subject line is a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/). Body carries reasoning the diff cannot show.

Do not commit unless the user explicitly asked to commit. This skill only defines the message format and how to recover prior decisions.

## Format

```
<type>(<scope>): <imperative summary>

<action-type>(<scope>): <signal the diff cannot show>
<action-type>(<scope>): <another entry>
```

Subject: imperative, no trailing period, keep it short. Scope is optional but preferred when the area is clear.

Body: only action lines that add signal. A typo fix, dependency bump, or formatting change needs zero action lines.

## Types

Use one primary type per commit. Split the work if several types apply.

| Type | When |
|------|------|
| `feat` | User-facing or library capability that did not exist |
| `fix` | Bug fix |
| `refactor` | Same behavior, different structure |
| `perf` | Performance improvement |
| `docs` | Documentation only |
| `test` | Tests only |
| `chore` | Tooling, deps, housekeeping |
| `style` | Formatting, no behavior change |

Breaking change: `feat(api)!: rename process endpoint` and/or a footer line `BREAKING CHANGE: <what changed for callers>`.

Do not use Lore trailers or QAC `Agent`/`Mode`/`What`/`Why` footers. Keep the body as action lines.

## Action types

Use only the lines that apply. Most commits need 1–3.

| Line | Captures | Skip if |
|------|----------|---------|
| `intent(scope):` | What the user wanted and why, in their words | Motivation is obvious from the subject |
| `decision(scope):` | Chosen approach when alternatives existed | The choice was obvious |
| `rejected(scope):` | Discarded option **and the reason** | Nothing meaningful was considered |
| `constraint(scope):` | Hard limit that shaped the implementation | The limit is already obvious in code |
| `learned(scope):` | Gotcha that would waste the next session | Nothing surprising was discovered |

`rejected` is the highest-value line. A rejection without a reason is useless — the next agent will re-propose it.

Reuse the same scope vocabulary inside a repo (`auth`, not `authentication` next time). Scope on an action line can be finer than the subject scope (`feat(payments)` + `rejected(money-library)`).

## Commit workflow

1. If the user did not ask to commit — stop after drafting the message only if they asked for a message. Otherwise do nothing.
2. Prefer staged files. If nothing is staged, decide the commit scope from this session's changes. Do not `git add .`.
3. Write action lines only from **this conversation**. If staged files include foreign work, do not invent `intent` / `rejected` / `constraint` / `learned`. A clean subject is better than fabricated context.
4. Never restate the diff. If the line is already visible in the code change, drop it.
5. Create the commit with a HEREDOC so newlines survive:

```bash
git commit -m "$(cat <<'EOF'
feat(scope): imperative summary

intent(scope): what the user asked for
decision(scope): chosen approach over alternative
rejected(scope): discarded option — reason
constraint(scope): hard limit that shaped the work
learned(scope): gotcha for the next session
EOF
)"
```

Omit unused action lines, including the blank body on trivial commits.

6. Do not skip hooks. Do not amend unless the user's commit rules allow it.

## Before proposing an approach

When about to choose a design in a known scope, query history first:

```bash
git log --all --grep="rejected\\(${SCOPE}\\)" --format="%s%n%b" --extended-regexp
git log --all --grep="constraint\\(${SCOPE}\\)" --format="%s%n%b" --extended-regexp
```

If a past commit already rejected the idea, tell the user the recorded reason **before** re-proposing it. Circumstances may have changed — that is their call.

For a full briefing from history, read [recall.md](recall.md).

## Examples

Trivial — subject only:

```
fix(button): correct alignment on mobile viewport
```

Feature with real tradeoffs:

```
feat(auth): add Google OAuth provider

intent(auth): social login starting with Google, then GitHub and Apple
decision(oauth-library): passport.js over auth0-sdk for multi-provider flexibility
rejected(oauth-library): auth0-sdk — locks into their session model, incompatible with redis store
constraint(callback-routes): must follow /api/auth/callback/:provider
learned(passport-google): needs explicit offline_access scope for refresh tokens
```

One-line body — the only signal worth keeping:

```
fix(checkout): prevent duplicate orders on double-click submit

rejected(checkout): debounce — 300ms delay feels broken on slow connections
```

Pivot mid-work:

```
refactor(auth): switch from sessions to JWT

intent(auth): original session approach incompatible with redis cluster
rejected(auth-sessions): cluster has no session stickiness for passport
decision(auth-tokens): JWT with short expiry plus refresh token
```
