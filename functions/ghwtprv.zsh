# ghwtprv — same PR checkout as ghwtpr, but herdr-reviewr in a Herdr split
#            instead of Cursor
# Usage: ghwtprv [-i] <pr-number>
#
# Inside Herdr (HERDR_ENV=1): open reviewr beside this pane, start the agent here.
# Outside Herdr: create a workspace, open reviewr, start the agent, print `herdr`.

_ghwtprv_inside_herdr() {
  [[ "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" && -n "${HERDR_WORKSPACE_ID:-}" ]]
}

_ghwtprv_help() {
  cat <<'EOF'
ghwtprv — ghwtpr, with herdr-reviewr in a Herdr split instead of Cursor

  ghwtprv [-i] <pr-number>

Flags:
  -i, --issue N     Optional flag before PR number
  -h, --help        Show this help

Inside Herdr: opens reviewr in a right split on this pane (PR worktree cwd)
and starts grok/claude in this pane once the shell is idle.

Outside Herdr: creates a workspace, does the same split + agent, prints
`herdr` so you can attach.

Needs: herdr, and `herdr plugin install persiyanov/herdr-reviewr`.
EOF
}

_ghwtprv_ensure_reviewr() {
  local listing
  listing=$(herdr plugin list --plugin persiyanov.reviewr 2>/dev/null) || listing=""
  if ! printf '%s\n' "$listing" | grep -q 'persiyanov.reviewr'; then
    echo "Error: herdr plugin persiyanov.reviewr is not installed."
    echo "  herdr plugin install persiyanov/herdr-reviewr"
    return 1
  fi
}

# Open reviewr beside the agent pane and start the review agent.
_ghwtprv_launch() {
  local worktree="$1" label="$2" ai_tool="$3" prompt="$4"
  local reviewr_pane="" agent_pane="" workspace_id=""

  if _ghwtprv_inside_herdr; then
    echo "Inside Herdr; opening reviewr beside this pane."
    agent_pane="${HERDR_PANE_ID}"
    workspace_id="${HERDR_WORKSPACE_ID}"
    _ghsb_open_reviewr "$agent_pane" "$worktree" "$workspace_id"
    cd "$worktree" || return 1

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

  _ghsb_open_reviewr "$agent_pane" "$worktree" "$workspace_id"
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

ghwtprv() {
  local pr_number=""

  while [[ "$1" == -* ]]; do
    case "$1" in
      -i|--issue)
        pr_number="$2"
        shift 2
        ;;
      -h|--help)
        _ghwtprv_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghwtprv_help
        return 1
        ;;
    esac
  done

  [[ -z "$pr_number" ]] && pr_number="$1"
  if [[ -z "$pr_number" ]]; then
    _ghwtprv_help
    return 1
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric"
    return 1
  fi

  _ghsb_ensure_herdr || return 1
  _ghwtprv_ensure_reviewr || return 1

  _ghsb_checkout_pr "$pr_number" || return 1
  _ghsb_pr_write_artifacts || return 1

  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local ai_tool prompt
  ai_tool=$(_ghsb_pick_ai "$pr_number")
  prompt=$(_ghsb_pr_review_prompt "$ai_tool")

  echo "Worktree: $worktree_path"
  _ghwtprv_launch "$worktree_path" "ghwtprv-${pr_number}" "$ai_tool" "$prompt"
}
