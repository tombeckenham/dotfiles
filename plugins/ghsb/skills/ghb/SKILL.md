---
name: ghb
description: Start branch work in Herdr without filing a GitHub issue. Use when the user wants a branch-only worktree, run /ghb or /ghib or /ghi branch, or says "just a branch", "no issue", "ghb", "ghib", "start a branch for X".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghb

In-Herdr branch work. No GitHub issue. Same as `ghib` and `ghi branch`.

Do not use `ghwtb` from a Herdr pane (`ghwtb` is the Cursor path). Do not invent a parallel git/gh flow.

## Invoke

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghb [flags] <branch-name-or-description>
```

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root space).

`ghb --help` for flags. Do not pass `--help` unless the user asked.

| User intent | Command |
| --- | --- |
| Slug from a description | `ghb "Add dark mode"` → branch `add-dark-mode` |
| Exact branch name | `ghb -b my-branch` |
| Branch from current | `ghb -c "description"` |
| Worktree only | `ghb --no-agent "description"` |

There is no issue-body wait (there is no issue). After it runs, print stdout. Do not `cd` this pane; `ghb` focuses the worktree space itself.
