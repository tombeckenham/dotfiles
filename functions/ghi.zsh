# ghi — start issue work in the current Herdr space
# Usage: ghi [-c] [-f] [-b <branch>] [-i <number>] [--no-agent] "Issue title"
#
# Same checkout as ghsb (issue → branch → worktree), but does not open an
# editor and does not create a Herdr workspace. Run it from inside a space
# you already opened; the agent starts in this pane after the command returns.
ghi() {
  local base_branch="" issue_number="" branch_name="" target_fork=false
  local no_agent=false

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

  local pane_id="${HERDR_PANE_ID:-}"
  local workspace_id="${HERDR_WORKSPACE_ID:-}"
  if [[ -z "$pane_id" || -z "$workspace_id" ]]; then
    echo "ghi must be run from inside a Herdr pane."
    echo "  1. herdr"
    echo "  2. create a new space"
    echo "  3. ghi -i N   or   ghi \"Issue title\""
    return 1
  fi
  _ghsb_ensure_herdr || return 1

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

  herdr workspace rename "$workspace_id" "$session_id" >/dev/null 2>&1 || true

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
    --arg pane "$pane_id" \
    --arg workspace "$workspace_id" \
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

  cd "$worktree_path" || return 1
  echo "Worktree: $worktree_path"
  echo "Session:  $session_id"

  if $no_agent; then
    echo "No agent (--no-agent). When done: ghsb finish $session_id"
    return 0
  fi

  local ai_prompt
  ai_prompt=$(_ghsb_implement_prompt "$issue_number" "$issue_repo" "$branch_name" "$session_id")

  local current_agent=""
  current_agent=$(herdr pane get "$pane_id" 2>/dev/null | jq -r '.result.pane.agent // empty')

  if [[ -n "$current_agent" && "$current_agent" != "null" ]]; then
    echo "This pane already has agent '$current_agent'; splitting in this space..."
    local split new_pane launch_line
    split=$(herdr pane split --pane "$pane_id" --direction right --cwd "$worktree_path" --no-focus 2>&1) || {
      echo "herdr pane split failed: $split"
      return 1
    }
    new_pane=$(printf '%s\n' "$split" | jq -r '.result.pane.pane_id // empty')
    if [[ -z "$new_pane" ]]; then
      echo "Could not parse pane id from herdr pane split:"
      echo "$split"
      return 1
    fi
    launch_line=$(_ghsb_herdr_launch_in_pane "$new_pane" "$workspace_id" "ghi-${issue_number}" "$worktree_path" "$ai_tool" "$ai_prompt") || launch_line=""
    if [[ -n "$launch_line" ]]; then
      local agent_name
      agent_name=${launch_line#*|}; agent_name=${agent_name%%|*}
      _ghsb_session_set "$session_id" "herdr_pane" "$new_pane"
      _ghsb_session_set "$session_id" "herdr_agent" "$agent_name"
      echo "Herdr pane:  $new_pane"
      echo "Herdr agent: $agent_name"
    fi
    echo "When done: ghsb finish $session_id"
    return 0
  fi

  # agent start requires an idle shell. This function is still running in the
  # current pane, so launch after we return to the prompt.
  local log_dir log
  log_dir="$GHSB_HOME/logs"
  mkdir -p "$log_dir"
  log="$log_dir/ghi-${session_id}.log"
  echo "Starting ${ai_tool} in this pane once the shell is idle."
  echo "Log: $log"
  echo "When done: ghsb finish $session_id"

  (
    sleep 0.5
    local launch_line agent_name
    launch_line=$(_ghsb_herdr_launch_in_pane "$pane_id" "$workspace_id" "ghi-${issue_number}" "$worktree_path" "$ai_tool" "$ai_prompt") || launch_line=""
    if [[ -n "$launch_line" ]]; then
      agent_name=${launch_line#*|}; agent_name=${agent_name%%|*}
      _ghsb_session_set "$session_id" "herdr_agent" "$agent_name"
    fi
  ) >>"$log" 2>&1 &!
}

_ghi_help() {
  cat <<'EOF'
ghi — start issue work in the current Herdr space

Run from a pane inside Herdr (create a new space first). Does not open an
editor and does not create a new Herdr workspace.

  ghi [-c] [-f] [-b <branch>] [-i <N>] [--no-agent] "Issue title"

Flags:
  -c, --current     Branch from current branch
  -b, --branch B    Use existing branch
  -i, --issue N     Develop existing issue
  -f, --fork        Issues on the fork (not upstream)
  --no-agent        Only create issue/branch/worktree (no agent)

After setup, the agent starts in this space. Finish later with:
  ghsb finish
EOF
}
