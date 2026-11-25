# Recall decisions from commit history

Search commit bodies for relevant `decision(scope)`, `rejected(scope)`,
`constraint(scope)`, and `learned(scope)` entries before revisiting a choice.

```bash
git log --all --format='%h %s%n%b' --extended-regexp --grep='rejected\(auth\)|constraint\(auth\)|decision\(auth\)'
```

Replace `auth` with the appropriate project scope; inspect matching commits and
diffs with `git show <sha>`. Treat recorded rationale as the author's account,
not independent proof. No running PR handoff document is required.
