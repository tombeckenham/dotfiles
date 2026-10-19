---
name: tris
description: Start an implement agent for open Trello cards assigned to the user on the configured inbox list, whose Herdr workspace is not already open. Starts the lowest card numbers first, five by default. Use when the user runs /tris or /tri cards, or says "start my Trello cards", "cards assigned to me".
compatibility: Requires Herdr pane (HERDR_PANE_ID), the Trello MCP, gh, git, jq, and ~/.zsh_functions from tombeckenham/dotfiles.
---

# tris

You list the cards with the Trello MCP. The shell decides which ones to start and checks out each worktree. Do not call `twg`.

## Invoke

If `HERDR_PANE_ID` is unset, stop and tell the user to run this from a Herdr pane (repo root of the repo to work in).

If the Trello MCP is not signed in, stop. In Grok the user runs `/mcps`, selects `trello`, and presses `i`.

The inbox lists are `~/.ghsb/trello.json` (`tri config --list`, plus any `--add-list` columns). Each id must be a list ARI. If none is set, stop and ask for the list.

```bash
RUN="${CLAUDE_PLUGIN_ROOT:-$HOME/code/dotfiles/plugins/ghsb}/scripts/run"
```

1. `trelloReadMember` action `get_me`. Keep the member `id` (an ARI).
2. For each configured list, `trelloReadCard` action `list_by_list`, `listId` that ARI, `filter` `open`. Follow `pageInfo.endCursor` while `hasNextPage` is true.
3. Write one card object per line to a file. A card number is the digits in `/c/SHORT/196-slug`, not a separate field you have to send.
4. Dry-run first when more than a handful of cards would start:

```bash
zsh "$RUN" tris --dry-run --cards "$file" --me "$member_ari"
```

5. Show the start and skip lists.
6. Run the same command without `--dry-run` to start. Do not wrap it in a background shell. `tri --no-focus` already starts each agent without stealing this pane.

`tris` keeps cards assigned to that member, skips archived cards, skips an empty description, and skips a card whose Herdr workspace is still open. It starts the lowest card number first and stops after 5 unless `--max` says otherwise. Run it again for the next batch.

## After it runs

Print stdout. Name how many started vs skipped vs failed. Do not focus each card space.
