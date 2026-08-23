# ghwtv — same issue + worktree as ghwt, agent in Herdr (no editor by default)
# Usage: ghwtv [-c] [-f] [-b <branch>] [-i <number>] [--tode] "Issue title"
#        ghwtv -e <number>   # open existing worktree/branch for review
#
# Does not start terminal-code/tode unless --tode.

_ghwtv_inside_herdr() {
  [[ "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" && -n "${HERDR_WORKSPACE_ID:-}" ]]
}

_ghwtv_help() {
  cat <<'EOF'
ghwtv — issue + Herdr worktree + agent (no editor)

  ghwtv [-c] [-f] [-b <branch>] [-i <N>] [--tode] "Issue title"
  ghwtv -e <N>

Flags:
  -c, --current     Branch from current branch
  -b, --branch B    Use existing branch
  -i, --issue N     Develop existing issue
  -e, --existing N  Open existing worktree/branch for issue N
  -f, --fork        Issues on the fork (not upstream)
  --tode            Also split and open terminal-code (tode)
  -h, --help        Show this help

Does not run terminal-code unless --tode.
Inside Herdr: starts grok/claude in this pane once the shell is idle.
Outside Herdr: uses the worktree workspace and prints `herdr` so you can attach.
EOF
}

# Split <pane_id>, put tode on the left (or top), run `tode` in the new pane.
# Prints the tode pane id on stdout.
_ghwtv_split_tode() {
  local pane_id="$1" worktree="$2"
  [[ -n "$pane_id" && -n "$worktree" ]] || return 1

  local layout width=0 height=0 direction="right"
  layout=$(herdr pane layout --pane "$pane_id" 2>/dev/null) || true
  width=$(printf '%s\n' "$layout" | jq -r '.result.layout.area.width // 0' 2>/dev/null)
  height=$(printf '%s\n' "$layout" | jq -r '.result.layout.area.height // 0' 2>/dev/null)
  if [[ "$width" == <-> && "$height" == <-> ]] && (( width > 0 && height > 0 && width < height * 2 )); then
    direction="down"
  fi

  local split_out new_pane
  split_out=$(herdr pane split --pane "$pane_id" --direction "$direction" \
    --cwd "$worktree" --ratio 0.55 --no-focus 2>&1) || {
    echo "herdr pane split failed: $split_out" >&2
    return 1
  }
  new_pane=$(printf '%s\n' "$split_out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if [[ -z "$new_pane" ]]; then
    echo "Could not parse .result.pane.pane_id from herdr pane split:" >&2
    echo "$split_out" >&2
    return 1
  fi

  # herdr only splits right/down; swap so tode sits where Cursor used to (left/top).
  if [[ "$direction" == "right" ]]; then
    herdr pane swap --pane "$new_pane" --direction left >/dev/null 2>&1 || true
  else
    herdr pane swap --pane "$new_pane" --direction up >/dev/null 2>&1 || true
  fi

  herdr pane rename "$new_pane" "tode" >/dev/null 2>&1 || true
  _ghsb_herdr_wait_shell "$new_pane" 20000 || true

  local tode_bin
  tode_bin=$(command -v tode)
  herdr pane run "$new_pane" "$(printf '%q' "$tode_bin") -n $(printf '%q' "$worktree")" >/dev/null 2>&1 || {
    echo "Failed to start tode in pane $new_pane" >&2
    return 1
  }
  printf '%s\n' "$new_pane"
}

_ghwtv_implement_prompt() {
  local issue_number="$1" issue_repo="$2"
  local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
  printf '%s\n' "Implement GitHub issue #${issue_number}. First run ${issue_view_cmd} for details. If the issue body is empty or doesn't have enough context to plan confidently, ask me what I want to accomplish and any constraints, then update the issue body via 'gh issue edit ${issue_number} -R ${issue_repo}' so the context is captured on GitHub before you start."
}

_ghwtv_review_prompt() {
  local issue_number="$1" issue_repo="$2"
  local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
  printf '%s\n' "Review progress on GitHub issue #${issue_number}. Run ${issue_view_cmd} for details, then inspect the working tree and recent commits to summarise progress and what remains."
}

# Start the agent; optionally split terminal-code (tode) beside it.
_ghwtv_launch() {
  local worktree="$1" label="$2" ai_tool="$3" prompt="$4"
  local with_tode="${5:-false}"
  local tode_pane="" agent_pane="" workspace_id=""

  if _ghwtv_inside_herdr; then
    local space_label
    space_label=$(_ghsb_issue_space_label "$label")
    if _ghsb_focus_worktree_if_other "$space_label"; then
      agent_pane="${GHSB_CHECKOUT[herdr_pane]:-${HERDR_PANE_ID}}"
      workspace_id="${GHSB_CHECKOUT[herdr_workspace]:-${HERDR_WORKSPACE_ID}}"
    else
      agent_pane="${HERDR_PANE_ID}"
      workspace_id="${HERDR_WORKSPACE_ID}"
      cd "$worktree" || return 1
    fi
    if [[ "$with_tode" == true ]]; then
      echo "Inside Herdr; splitting worktree pane for tode."
      tode_pane=$(_ghwtv_split_tode "$agent_pane" "$worktree") || return 1
      echo "tode pane:  $tode_pane"
    fi

    local current_agent=""
    current_agent=$(_ghsb_pane_agent "$agent_pane") || current_agent=""
    if [[ -n "$current_agent" ]]; then
      echo "This pane already has agent '$current_agent'; sending the prompt there."
      _ghsb_herdr_send_prompt "$current_agent" "$prompt" \
        || _ghsb_herdr_send_prompt "$agent_pane" "$prompt" \
        || true
      return 0
    fi

    local log_dir log
    log_dir="${GHSB_HOME:-$HOME/.ghsb}/logs"
    mkdir -p "$log_dir"
    log="$log_dir/${label}.log"
    echo "Starting ${ai_tool} in this pane once the shell is idle."
    echo "Log: $log"
    (
      sleep 0.5
      _ghsb_herdr_launch_in_pane "$agent_pane" "$workspace_id" "$label" "$worktree" "$ai_tool" "$prompt"
    ) >>"$log" 2>&1 &!
    return 0
  fi

  echo "Not inside Herdr; using Herdr worktree workspace ${label}."
  agent_pane="${GHSB_CHECKOUT[herdr_pane]:-}"
  workspace_id="${GHSB_CHECKOUT[herdr_workspace]:-}"
  if [[ -z "$agent_pane" || -z "$workspace_id" ]]; then
    local created
    created=$(herdr workspace create --cwd "$worktree" --label "$label" --focus 2>&1) || {
      echo "herdr workspace create failed: $created" >&2
      return 1
    }
    agent_pane=$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    workspace_id=$(printf '%s\n' "$created" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  fi
  if [[ -z "$agent_pane" ]]; then
    echo "Could not resolve Herdr pane for worktree ${worktree}" >&2
    return 1
  fi

  if [[ "$with_tode" == true ]]; then
    tode_pane=$(_ghwtv_split_tode "$agent_pane" "$worktree") || return 1
    echo "tode pane:       $tode_pane"
  fi
  echo "Herdr workspace: $workspace_id"
  echo "agent pane:      $agent_pane"

  local launch_line
  launch_line=$(_ghsb_herdr_launch_in_pane "$agent_pane" "$workspace_id" "$label" "$worktree" "$ai_tool" "$prompt") || launch_line=""
  if [[ -n "$launch_line" ]]; then
    echo "Herdr agent:     ${launch_line#*|}"
  fi
  echo "Not attached here. Run: herdr"
  echo "  or: herdr workspace focus ${workspace_id}"
}

_ghwtv_existing() {
  local issue_number="$1" issue_repo="$2" with_tode="${3:-false}"
  local repo_root repo_name worktree_path found_branch=""
  repo_root=$(_ghsb_repo_root)
  repo_name=$(basename "$repo_root")
  local hit rest
  hit=$(_ghsb_herdr_wt_find_issue "$repo_root" "$issue_number") || hit=""
  if [[ -n "$hit" ]]; then
    found_branch=${hit##*$'\t'}
  fi
  if [[ -z "$found_branch" ]]; then
    found_branch=$(git for-each-ref --format='%(refname:short)' "refs/heads/${issue_number}-*" 2>/dev/null | head -1)
    if [[ -z "$found_branch" ]]; then
      git fetch origin 2>/dev/null
      found_branch=$(git ls-remote --heads origin 2>/dev/null \
        | grep -E "refs/heads/${issue_number}-[a-z0-9-]+$" \
        | head -1 | sed 's#.*refs/heads/##')
    fi
  fi
  if [[ -z "$found_branch" ]]; then
    echo "No existing branch found for issue #${issue_number}"
    return 1
  fi
  echo "Found branch: $found_branch"
  git fetch origin "$found_branch" 2>/dev/null
  _ghsb_herdr_wt_ensure_branch "$repo_root" "$found_branch" "$(_ghsb_herdr_issue_label "$issue_number" "$found_branch")" || return 1
  GHSB_CHECKOUT=()
  _ghsb_herdr_wt_apply_checkout
  worktree_path="${GHSB_HERDR_WT[path]}"

  local ai_tool prompt
  ai_tool=$(_ghsb_pick_ai "$issue_number")
  prompt=$(_ghwtv_review_prompt "$issue_number" "$issue_repo")
  _ghwtv_launch "$worktree_path" "ghwtv-${issue_number}" "$ai_tool" "$prompt" "$with_tode"
}

ghwtv() {
  local base_branch="" issue_number="" branch_name="" target_fork=false existing_mode=false
  local with_tode=false

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
      -e|--existing)
        existing_mode=true
        issue_number="$2"
        shift 2
        ;;
      -f|--fork)
        target_fork=true
        shift
        ;;
      --tode)
        with_tode=true
        shift
        ;;
      -h|--help)
        _ghwtv_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghwtv_help
        return 1
        ;;
    esac
  done

  if $with_tode && ! command -v tode >/dev/null 2>&1; then
    echo "Error: tode not found (expected on PATH). Install terminal-code or drop --tode."
    return 1
  fi
  _ghsb_ensure_herdr || return 1

  local detect is_fork=false upstream_repo="" fork_repo="" issue_repo=""
  detect=$(_ghsb_detect_repo)
  is_fork=${detect%%$'\t'*}
  fork_repo=${detect#*$'\t'}; fork_repo=${fork_repo%%$'\t'*}
  upstream_repo=${detect##*$'\t'}
  issue_repo="$upstream_repo"
  if $target_fork && [[ "$is_fork" == "true" ]]; then
    issue_repo="$fork_repo"
  fi

  if $existing_mode; then
    if [[ -z "$issue_number" ]]; then
      echo "Error: -e/--existing requires an issue number"
      return 1
    fi
    _ghwtv_existing "$issue_number" "$issue_repo" "$with_tode"
    return $?
  fi

  _ghsb_checkout_issue ghwtv "$base_branch" "$issue_number" "$branch_name" "$target_fork" "$@" || return 1
  issue_number="${GHSB_CHECKOUT[issue]}"
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  issue_repo="${GHSB_CHECKOUT[repo]}"

  local ai_tool prompt
  ai_tool=$(_ghsb_pick_ai "$issue_number")
  prompt=$(_ghwtv_implement_prompt "$issue_number" "$issue_repo")
  echo "Worktree: $worktree_path"
  _ghwtv_launch "$worktree_path" "ghwtv-${issue_number}" "$ai_tool" "$prompt" "$with_tode"
}
