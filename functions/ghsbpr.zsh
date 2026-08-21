# ghsbpr — Herdr-based review of an existing GitHub PR (Architecture A sibling of ghwtpr)
# Usage: ghsbpr [-i] <pr-number>
#        ghsb review <pr-number>   # same entry via ghsb
#
# Checks out the PR into a worktree (same as ghwtpr), ranks files for manual review,
# launches the review agent in Herdr with --permission-mode auto, and prints links.

ghsbpr() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: ghsbpr [-i] <pr-number>"
    echo "       ghsb review <pr-number>"
    echo "  Check out a PR into a worktree and run pr-review in Herdr"
    echo "  -i, --issue  Optional flag before PR number (e.g. ghsbpr -i 42)"
    echo ""
    echo "Like ghwtpr, but uses Herdr instead of tmux/Cursor, ranks files for"
    echo "manual review, and prints github.dev / preview links."
    echo "Inside Herdr: review stays in this space/agent (no new workspace)."
    echo "Agent permission mode: auto (not always-approve)."
    return 0
  fi

  local pr_number
  if [[ "$1" == "-i" || "$1" == "--issue" ]]; then
    pr_number="$2"
    if [[ -z "$pr_number" ]]; then
      echo "Error: -i requires a PR number"
      return 1
    fi
  else
    pr_number="$1"
  fi

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric"
    return 1
  fi

  local detect fork_repo upstream_repo
  detect=$(_ghsb_detect_repo)
  fork_repo=${detect#*$'\t'}; fork_repo=${fork_repo%%$'\t'*}
  upstream_repo=${detect##*$'\t'}

  # Open links first (vscode.dev PR URL; local worktree if present).
  local _early_repo="${upstream_repo:-$fork_repo}"
  local _early_root _early_name _early_wt=""
  _early_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null) || true
  _early_name=$(basename "${_early_root:-}")
  [[ -n "$_early_name" ]] && _early_wt="$HOME/.claude/worktrees/${_early_name}-${pr_number}"
  _ghsb_print_open_first "$_early_repo" "" "$pr_number" "$_early_wt"
  echo ""

  _ghsb_checkout_pr "$pr_number" || return 1
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local session_id="${GHSB_CHECKOUT[session_id]}"
  local issue_repo="${GHSB_CHECKOUT[repo]}"
  local origin_repo="${GHSB_CHECKOUT[origin]}"
  local head_ref="${GHSB_CHECKOUT[branch]}"
  local base_ref="${GHSB_CHECKOUT[base]}"

  _ghsb_pr_write_artifacts || return 1
  local art="${GHSB_CHECKOUT[artifacts]}"
  local preview_url="${GHSB_CHECKOUT[preview_url]}"

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "$pr_number")

  # Session record
  local session_json
  session_json=$(jq -n \
    --arg id "$session_id" \
    --argjson pr "$pr_number" \
    --arg branch "$head_ref" \
    --arg repo "$issue_repo" \
    --arg origin "$origin_repo" \
    --arg worktree "$worktree_path" \
    --arg ai "$ai_tool" \
    --arg base "$base_ref" \
    --arg preview "${preview_url}" \
    --arg art "$art" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      issue: null,
      pr: $pr,
      branch: $branch,
      repo: $repo,
      origin: $origin,
      worktree: $worktree,
      backend: "local",
      ai_tool: $ai,
      base_branch: $base,
      sandbox_id: "",
      preview_url: $preview,
      dev_url: "",
      terminal_url: "",
      herdr_pane: "",
      herdr_agent: "",
      herdr_workspace: "",
      review_pane: "",
      review_agent: "",
      artifacts: $art,
      kind: "pr-review",
      created_at: $created,
      finished_at: null
    }')
  _ghsb_write_session "$session_id" "$session_json"

  local review_prompt
  review_prompt=$(_ghsb_pr_review_prompt "$ai_tool")

  if [[ -n "${HERDR_PANE_ID:-}" && -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    echo "Review in this Herdr space (same agent if one is already running)."
    _ghsb_launch_in_current_space "ghsb-review-${pr_number}" "$worktree_path" "$ai_tool" "$review_prompt" "$session_id" --review
  elif command -v herdr >/dev/null 2>&1; then
    echo "Not inside a Herdr pane; creating a review space..."
    local launch_line="" pane_id="" agent_name="" workspace_id=""
    launch_line=$(_ghsb_herdr_launch "ghsb-review-${pr_number}" "$worktree_path" "$ai_tool" "$review_prompt") || launch_line=""
    if [[ -n "$launch_line" ]]; then
      pane_id=${launch_line%%|*}
      agent_name=${launch_line#*|}; agent_name=${agent_name%%|*}
      workspace_id=${launch_line##*|}
      _ghsb_session_set "$session_id" "herdr_pane" "$pane_id"
      _ghsb_session_set "$session_id" "herdr_agent" "$agent_name"
      _ghsb_session_set "$session_id" "herdr_workspace" "$workspace_id"
      _ghsb_session_set "$session_id" "review_pane" "$pane_id"
      _ghsb_session_set "$session_id" "review_agent" "$agent_name"
      echo "Herdr workspace: $workspace_id"
      echo "Herdr agent:     $agent_name"
      echo "Attach: ghsb attach $session_id"
    fi
  else
    echo "Review in the current terminal (no new agent launcher):"
    echo "  cd $worktree_path"
    echo "  $ai_tool $(_ghsb_ai_flags "$ai_tool")"
    echo "  then: $review_prompt"
  fi

  _ghsb_print_links "$issue_repo" "$head_ref" "$pr_number" "$preview_url" "" "$worktree_path"
  echo ""
  echo "Session:   $session_id"
  echo "Artifacts: $art"
  echo "Summary:   $art/SUMMARY.md"
}
