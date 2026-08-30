---
name: ghipr
description: Review one GitHub PR in Herdr (worktree, herdr-reviewr, review agent). Use when the user wants to review a PR, run /ghipr, or says "ghipr 123", "review PR N", "ghi review".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghipr

Run `ghipr` from this Herdr pane. Same as `ghi review <n>`.

## Invoke

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghipr [flags] <pr-number>
```

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root space).

Need the PR number. If missing, `gh pr list` and ask, or use `ghiprs` when they want every assigned PR.

`ghipr --help` for flags.

| User intent | Command |
| --- | --- |
| Review PR 99 | `ghipr 99` |
| Checkout only | `ghipr --no-agent 99` |
| Start without switching this pane | `ghipr --no-focus 99` |

## After it runs

Print stdout. Do not start a second review agent in this pane. Several PRs → `ghiprs`, not a loop of `ghipr` (that would steal focus).
