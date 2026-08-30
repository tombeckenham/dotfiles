# ghi — start issue work from a Herdr pane (typically the repo root space)
# Usage: ghi [-c] [-f] [-b <branch>] [-i <number>] [--no-agent] [--video] [--review-fix] "Issue title"
#        ghi review <pr-number>   # same as ghipr
#
# Creates a Herdr worktree grouped under the repo, focuses that space, and
# starts the agent there. Does not rename or cd the space you ran it from.
ghi() {
  case "${1:-}" in
    review)
      shift
      ghipr "$@"
      return $?
      ;;
  esac

  local base_branch="" issue_number="" branch_name="" target_fork=false
  local no_agent=false want_video=false want_review=false

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
      -i|--issue)
        issue_number="$2"
        shift 2
        ;;
      -f|--fork)
        target_fork=true
        shift
        ;;
      --no-agent)
        no_agent=true
        shift
        ;;
      --video)
        want_video=true
        shift
        ;;
      --review-fix|--review)
        want_review=true
        shift
        ;;
      -h|--help)
        _ghi_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghi_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane ghi || return 1

  _ghsb_checkout_issue ghi "$base_branch" "$issue_number" "$branch_name" "$target_fork" "$@" || return 1
  issue_number="${GHSB_CHECKOUT[issue]}"
  branch_name="${GHSB_CHECKOUT[branch]}"
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local session_id="${GHSB_CHECKOUT[session_id]}"
  local issue_repo="${GHSB_CHECKOUT[repo]}"
  local origin_repo="${GHSB_CHECKOUT[origin]}"
  local default_branch="${GHSB_CHECKOUT[default_branch]}"

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "$issue_number")

  local session_json
  session_json=$(jq -n \
    --arg id "$session_id" \
    --argjson issue "$issue_number" \
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
      issue: $issue,
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
  ai_prompt=$(_ghsb_implement_prompt "$issue_number" "$issue_repo" "$branch_name" "$session_id" "$ai_tool" "$want_video" "$want_review")
  _ghsb_launch_in_current_space "ghi-${issue_number}" "$worktree_path" "$ai_tool" "$ai_prompt" "$session_id"
  echo "When done: push + PR. Optional: ghsb finish [--video] [--review-fix] $session_id"
}

_ghi_help() {
  cat <<'EOF'
ghi — start issue work from a Herdr pane

Run from the repo root space (e.g. openstory). Creates a worktree grouped
under the repo, switches you to it, and starts the agent there. Does not
rename or cd this space.

  ghi [-c] [-f] [-b <branch>] [-i <N>] [--no-agent] [--video] [--review-fix] "Issue title"
  ghi review <pr-number>     # same as ghipr

Flags:
  -c, --current     Branch from current branch
  -b, --branch B    Use existing branch
  -i, --issue N     Develop existing issue
  -f, --fork        Issues on the fork (not upstream)
  --no-agent        Only create issue/branch/worktree (no agent)
  --video           After PR, record a Playwright walkthrough (ghsb finish --video)
  --review-fix      After PR, self-review and fix in this same agent

Default wrap-up is push + PR only (no video, no auto-review).
EOF
}
