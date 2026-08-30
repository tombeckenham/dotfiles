---
name: ghiprs
description: Review every open GitHub PR assigned to the user that does not already have a ghsb session. Creates a worktree and starts a separate review agent per PR without leaving this pane. Use when the user runs /ghiprs, or says "review all my PRs", "ghipr everything assigned to me", "start reviews for assigned PRs", "parallel PR review".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghiprs

Fan-out of `ghipr --no-focus` for this repo.

## Invoke

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root of the repo to review).

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghiprs [--dry-run]
```

1. Dry-run first when the user might want a preview, or when more than a handful of PRs would start: `ghiprs --dry-run`
2. Show them the start/skip lists
3. Run `ghiprs` (no flag) to start. Do not wrap it in a background shell — `ghipr --no-focus` already starts each agent without stealing this pane.

Do not write your own `gh pr list` + loop of `ghipr`. `ghiprs` skips PRs that already have a session (`~/.ghsb/sessions/{repo}-pr-{N}.json` or any `{repo}-*` session whose `pr` field matches).

## What it does

- `gh pr list --assignee @me --state open` in the current repo
- Skip: already have a ghsb session
- Start: `ghipr --no-focus <n>` (worktree + reviewr + review agent)
- This pane stays on the repo root

## After it runs

Print stdout. Name how many started vs skipped vs failed. Do not focus each review space.
