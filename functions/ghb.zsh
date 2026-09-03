# ghb — start branch work from a Herdr pane (no GitHub issue)
# Usage: ghb [-c] [-b <branch>] [--no-agent] [<branch-name-or-description>]
#        ghib …            # same
#        ghi branch …      # same
#
# Creates a Herdr worktree grouped under the repo, focuses that space, and
# starts the agent there. Does not rename or cd the space you ran it from.
ghb() {
  local base_branch="" branch_name="" no_agent=false

  while [[ "$1" == -* ]]; do
    case "$1" in
      -c|--current)
        base_branch=$(git branch --show-current)
        shift
        ;;
      -b|--branch)
        branch_name="$2"
        shift 2
        ;;
      --no-agent)
        no_agent=true
        shift
        ;;
      -h|--help)
        _ghb_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghb_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane ghb || return 1
  _ghsb_parse_branch_args ghb "$branch_name" "$@" || return 1
  _ghsb_checkout_branch ghb "$base_branch" || return 1

  branch_name="${GHSB_CHECKOUT[branch]}"
  local description="${GHSB_CHECKOUT[description]:-}"
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local session_id="${GHSB_CHECKOUT[session_id]}"
  local issue_repo="${GHSB_CHECKOUT[repo]}"
  local origin_repo="${GHSB_CHECKOUT[origin]}"
  local default_branch="${GHSB_CHECKOUT[default_branch]}"

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "${#branch_name}")

  local session_json
  session_json=$(jq -n \
    --arg id "$session_id" \
    --arg branch "$branch_name" \
    --arg repo "$issue_repo" \
    --arg origin "$origin_repo" \
    --arg worktree "$worktree_path" \
    --arg backend "local" \
    --arg ai "$ai_tool" \
    --arg base "$default_branch" \
    --arg pane "${GHSB_CHECKOUT[herdr_pane]:-${HERDR_PANE_ID}}" \
    --arg workspace "${GHSB_CHECKOUT[herdr_workspace]:-${HERDR_WORKSPACE_ID}}" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      issue: null,
      pr: null,
      branch: $branch,
      repo: $repo,
      origin: $origin,
      worktree: $worktree,
      backend: $backend,
      ai_tool: $ai,
      base_branch: $base,
      sandbox_id: "",
      preview_url: "",
      dev_url: "",
      terminal_url: "",
      herdr_pane: $pane,
      herdr_agent: "",
      herdr_workspace: $workspace,
      review_pane: "",
      review_agent: "",
      created_at: $created,
      finished_at: null
    }')
  _ghsb_write_session "$session_id" "$session_json"

  echo "Worktree: $worktree_path"
  echo "Session:  $session_id"

  if $no_agent; then
    _ghsb_focus_worktree_if_other "$(_ghsb_issue_space_label "$session_id")" \
      || cd "$worktree_path" || return 1
    _ghsb_open_reviewr "${GHSB_CHECKOUT[herdr_pane]:-}" "$worktree_path" \
      "${GHSB_CHECKOUT[herdr_workspace]:-}"
    echo "No agent (--no-agent)."
    return 0
  fi

  local ai_prompt
  ai_prompt=$(_ghsb_branch_prompt "$branch_name" "$description")
  _ghsb_launch_in_current_space "ghb-$(_ghsb_herdr_branch_slug "$branch_name")" "$worktree_path" "$ai_tool" "$ai_prompt" "$session_id"
  echo "When done: push + PR."
}

ghib() {
  ghb "$@"
}

_ghb_help() {
  cat <<'EOF'
ghb — start branch work from a Herdr pane (no GitHub issue)

Run from the repo root space. Creates a worktree grouped under the repo,
switches you to it, and starts the agent there. Does not rename or cd
this space. Same as: ghib, ghi branch

  ghb [-c] [-b <branch>] [--no-agent] [<branch-name-or-description>]

Flags:
  -c, --current     Branch from current branch
  -b, --branch B    Use this branch name (remaining text is agent context)
  --no-agent        Only create branch/worktree (no agent)

A description with spaces is slugified (e.g. "Add dark mode" → add-dark-mode).
For an existing branch, ghb still reuses it (or use wt outside Herdr).
EOF
}
