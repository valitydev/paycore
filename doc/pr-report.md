# PR explanatory notes

The PR report uses OpenRouter to write a short Russian note explaining the
final change, component boundaries, behavior changes, compatibility and test
scenarios. Author-reported commit context and test-name candidates are kept
in collapsible sections. Commit lists are linked rather than duplicated.

## Setup

1. Create an OpenRouter API key and add it as the repository Actions secret
   `OPENROUTER_API_KEY` (Settings → Secrets and variables → Actions).
2. Optionally set the Actions variable `PR_REPORT_MODEL`. The default is
   `nvidia/nemotron-3.5-super-vl:free`. Other free endpoints can be selected
   without changing code. Paid model IDs are rejected and the request sets
   zero maximum prices for input, output and per-request charges. There is
   no automatic fallback to a paid model.
3. Create the repository label `refresh-pr-report`. Add it to an existing PR
   to generate or refresh the note.

The workflow and prompt must first be merged into the base branch: the
`pull_request_target` workflow checks out the trusted base SHA. Changing the
script or prompt only in the PR does not change the running reporter.

## When it runs

| Event | Result |
| --- | --- |
| Open a non-draft PR | Create the initial comment |
| Open a draft PR | Wait until it is ready for review |
| Mark ready for review | Create a comment only if none exists |
| Push, edit description, reopen PR | No generation |
| Add `refresh-pr-report` | Regenerate for the current HEAD and edit the original comment |

After a successful labeled run, the workflow removes the label, allowing it
to be added again. A refresh runs even if the HEAD has not changed (for
example after editing the PR description or changing the model).

The comment identifies the HEAD it describes. It is intentionally a snapshot
and can become stale after pushes. The reporter only edits its own
`github-actions[bot]` comment identified by the hidden report marker; old v1
bot reports are updated in place too. User-posted copies are not overwritten.

There is at most one OpenRouter request per generation attempt, with no
automatic retries. Missing keys, exhausted free quota, network errors, and
empty or incomplete responses fail the job. If a comment already exists,
its content is preserved. On the first attempt a factual report is posted
with an explicit AI-unavailable message; add the label to retry generation.
The refresh label stays on failed labeled runs; rerun that failed workflow,
or remove and add the label again.

## Input and limits

Only PR title/description, commit messages and GitHub changed-file patches
are sent to OpenRouter. PR source code is never executed, and the model has
no tools. The prompt is `.github/prompts/pr-report.md` from the trusted base.
Free-model providers receive this content under their own data policies.

One request includes at most 100 files and 40 commit messages within 120,000
serialized input characters, sharing patch space across files. Missing and
shortened patches and omitted data are identified to the model. GitHub's
patches are excerpts, and cannot establish whole-program equivalence. The
generated note is a reading aid, not proof of unchanged behavior or passing
tests. New EUnit candidates are also detected inside `src/*.erl`.

The reporter checks base and head again before publishing. If either changed
while collecting or generating the note, it fails without publishing a stale
report; request another generation for the current PR state.

Run local checks without credentials or API usage:

```sh
python3 -B -m unittest discover -s .github/scripts/tests -v
```
