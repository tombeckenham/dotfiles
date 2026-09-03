---
name: ghi
description: Start GitHub issue work in Herdr (create or reuse issue, branch, worktree, agent). Use when the user wants to start an issue, run /ghi, or says "ghi this", "work on issue N", "create an issue and start an agent".
compatibility: Requires Herdr pane (HERDR_PANE_ID), gh, git, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# ghi

Run `ghi` from this Herdr pane. Do not invent a parallel git/gh flow.

Never start the implement agent on an empty or stub issue. The worktree may exist first; the agent waits until the GitHub issue body is complete.

## Runner

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
```

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root space).

## New issue

Do not run `ghi "Title"` — that creates an empty-body issue and would start the agent too soon.

1. Write a complete GitHub issue: title, problem, context, and acceptance criteria.

   ```bash
   gh issue create --title "…" --body "…"
   ```

2. Optional — create the worktree while you still might edit the issue:

   ```bash
   zsh "$RUN" ghi --no-agent -i N
   ```

3. Confirm the body is real, not empty or placeholder:

   ```bash
   gh issue view N --json title,body
   ```

4. Start the agent only after that:

   ```bash
   zsh "$RUN" ghi -i N
   ```

`ghi` also refuses to start the agent if the body is still empty; it leaves the worktree and prints `ghi -i N` for when the issue is ready.

## Existing issue

1. `gh issue view N --json title,body`
2. If the body lacks enough context, `gh issue edit N --body "…"` before the agent.
3. Worktree first is fine: `zsh "$RUN" ghi --no-agent -i N`
4. Then `zsh "$RUN" ghi -i N`

## Flags

`ghi --help` if needed. Do not pass `--help` unless the user asked.

| User intent | Command |
| --- | --- |
| Existing complete issue | `ghi -i 42` |
| Worktree only | `ghi --no-agent -i 42` |
| Branch from current | `ghi -c -i 42` |
| Named branch | `ghi -b branch-name -i 42` |
| Review a PR instead | `ghi review 99` (same as `ghipr`) |
| Branch, no issue | `ghi branch "Add dark mode"` (same as `ghb`) |

Default wrap-up is push + PR. Add `--video` / `--review-fix` only if the user asked.

## After it runs

Print the command's stdout (worktree + session). Do not `cd` the current pane; `ghi` focuses the worktree space itself.
