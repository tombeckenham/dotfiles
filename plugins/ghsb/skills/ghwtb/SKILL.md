---
name: ghwtb
description: Create a branch and worktree without a GitHub issue using the Cursor/tmux path. Use when the user runs /ghwtb or is not inside Herdr and wants a branch-only worktree. Inside Herdr, use ghb / ghi branch instead.
compatibility: Requires git, gh, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghwtb

Cursor/tmux sibling of `ghb`. No GitHub issue.

If `HERDR_PANE_ID` is set, run `ghb` instead (see the ghb skill). Do not invent a parallel git/gh flow.

## Invoke

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
zsh "$RUN" ghwtb [flags] <branch-name-or-description>
```

`ghwtb --help` for flags.

| User intent | Command |
| --- | --- |
| Slug from a description | `ghwtb "Add dark mode"` → `add-dark-mode` |
| Exact branch name | `ghwtb -b my-branch` |
| Branch from current | `ghwtb -c "description"` |

Print stdout. This opens Cursor, not a Herdr agent pane.
