---
name: ghwtb
description: Create a branch and Herdr worktree without opening a GitHub issue. Use when the user wants a branch-only worktree, run /ghwtb, or says "just a branch", "no issue", "ghwtb", "start a branch for X".
compatibility: Requires git, gh, and ~/.zsh_functions from tombeckenham/dotfiles. Inside Herdr is preferred.
---

# ghwtb

`ghi` without an issue: branch + worktree + agent.

## Invoke

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghwtb [flags] <branch-or-description>
```

`ghwtb --help` for flags.

| User intent | Command |
| --- | --- |
| Slug from a description | `ghwtb "Add dark mode"` → branch `add-dark-mode` |
| Exact branch name | `ghwtb -b my-branch` |
| Branch from current | `ghwtb -c "description"` |

If they named an existing branch, `wt <branch>` is the reuse path; `ghwtb` still works and will reuse it.

## After it runs

Print stdout. This command follows the `ghwt` Cursor path, not the in-Herdr `ghi` path.
