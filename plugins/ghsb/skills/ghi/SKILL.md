---
name: ghi
description: Start GitHub issue work in Herdr (create or reuse issue, branch, worktree, agent). Use when the user wants to start an issue, run /ghi, or says "ghi this", "work on issue N", "create an issue and start an agent".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghi

Run `ghi` from this Herdr pane. Do not invent a parallel git/gh flow.

## Invoke

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghi [flags] [title or -i N]
```

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root space).

`ghi --help` for flags. Do not pass `--help` unless the user asked.

## Flags you actually use

| User intent | Command |
| --- | --- |
| New issue from a title | `ghi "Title"` |
| Existing issue | `ghi -i 42` |
| Branch from current | `ghi -c "Title"` |
| Named branch | `ghi -b branch-name -i 42` |
| Worktree only | `ghi --no-agent -i 42` |
| Review a PR instead | `ghi review 99` (same as `ghipr`) |

Default wrap-up is push + PR. Add `--video` / `--review-fix` only if the user asked.

## After it runs

Print the command's stdout (worktree + session). Do not `cd` the current pane; `ghi` focuses the worktree space itself.
