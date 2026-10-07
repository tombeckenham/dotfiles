---
name: ghiprs
description: Review every open GitHub PR assigned to the user whose Herdr workspace is not already open. Reopens the worktree if it is on disk, otherwise creates one, and starts a separate review agent per PR without leaving this pane. Use when the user runs /ghiprs, or says "review all my PRs", "ghipr everything assigned to me", "start reviews for assigned PRs", "parallel PR review".
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

Do not write your own `gh pr list` + loop of `ghipr`. `ghiprs` skips a PR only when its Herdr workspace is still open.

## What it does

- `gh pr list --assignee @me --state open` in the current repo
- Skip: session `herdr_workspace` is in `herdr workspace list`, or the PR branch's worktree is already open in a live workspace
- Start: `ghipr --no-focus <n>`. That reopens the worktree directory when it exists, and creates one when it does not
- This pane stays on the repo root

## After it runs

Print stdout. Name how many started vs skipped vs failed. Do not focus each review space.
