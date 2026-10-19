---
name: tri
description: Start Trello card work in Herdr (create or reuse a card, branch, worktree, agent). Use when the user wants to start a Trello card, run /tri, or says "tri this", "work on this card", "create a card and start an agent".
compatibility: Requires Herdr pane (HERDR_PANE_ID), the Trello MCP, gh, git, jq, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# tri

Run `tri` from this Herdr pane. The card URL is the branch name. Do not read the card before starting the worktree. Do not call `twg`. Do not invent a parallel git flow.

The agent that `tri` starts reads the card. If the description is empty, that agent asks before coding.

## Runner

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
```

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root space).

If the Trello MCP is not signed in, stop. In Grok the user runs `/mcps`, selects `trello`, and presses `i`.

## Start the worktree

`https://trello.com/c/ebbOKFhy/1-some-slug` becomes branch `ebbOKFhy-some-slug`. A bare number becomes a branch of that number. No Trello call.

```bash
zsh "$RUN" tri --card "https://trello.com/c/ebbOKFhy/1-some-slug"
```

A new title still creates a card first. The list id in `tri config --list` must be a list ARI. Create it with `trelloWriteCard` action `create`, write the result to a file, then `zsh "$RUN" tri --card-json "$file"`. Do not pass a URL to a write tool.

## Flags

`tri --help` if needed. Do not pass `--help` unless the user asked.

| User intent | Command |
| --- | --- |
| Existing card | `tri --card URL` |
| Worktree only | `tri --no-agent --card-json FILE` |
| Branch from current | `tri -c --card-json FILE` |
| Named branch | `tri -b branch-name --card-json FILE` |
| Cards assigned to me | `/tris` |
| Branch, no card | `tri branch "Add dark mode"` (same as `ghb`) |

There is no Trello equivalent of `ghipr`. Pull request review stays on `ghipr`.

Default wrap-up is push + PR, with the card URL in the PR body. Add `--video` / `--review-fix` only if the user asked.

## After it runs

Print the command's stdout (card, worktree, session). Do not `cd` the current pane. `tri` focuses the worktree space itself.
