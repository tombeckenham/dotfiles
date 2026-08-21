# ghipr — review a GitHub PR in the current Herdr space
# Usage: ghipr [-i] [--no-agent] <pr-number>
#        ghi review <pr-number>
#
# Same checkout as ghsbpr (PR worktree + ranked files), but stays in the space
# you already opened. Does not open an editor and does not create a Herdr workspace.
ghipr() {
  local pr_number="" no_agent=false

  while [[ "$1" == -* ]]; do
    case "$1" in
      -i|--issue)
        pr_number="$2"
        shift 2
        ;;
      --no-agent)
        no_agent=true
        shift
        ;;
      -h|--help)
        _ghipr_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghipr_help
        return 1
        ;;
    esac
  done

  [[ -z "$pr_number" ]] && pr_number="$1"
  if [[ -z "$pr_number" ]]; then
    _ghipr_help
    return 1
  fi
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric"
    return 1
  fi

  _ghsb_require_herdr_pane ghipr || return 1
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
    --arg pane "${HERDR_PANE_ID}" \
    --arg workspace "${HERDR_WORKSPACE_ID}" \
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
      herdr_pane: $pane,
      herdr_agent: "",
      herdr_workspace: $workspace,
      review_pane: "",
      review_agent: "",
      artifacts: $art,
      kind: "pr-review",
      created_at: $created,
      finished_at: null
    }')
  _ghsb_write_session "$session_id" "$session_json"

  echo "Worktree:  $worktree_path"
  echo "Session:   $session_id"
  echo "Artifacts: $art"

  if $no_agent; then
    cd "$worktree_path" || return 1
    echo "No agent (--no-agent)."
    return 0
  fi

  local review_prompt
  review_prompt=$(_ghsb_pr_review_prompt "$ai_tool")
  _ghsb_launch_in_current_space "ghi-review-${pr_number}" "$worktree_path" "$ai_tool" "$review_prompt" "$session_id" --review
}

_ghipr_help() {
  cat <<'EOF'
ghipr — review a GitHub PR in the current Herdr space

Run from a pane inside Herdr (create a new space first). Does not open an
editor. The checkout is a Herdr worktree (grouped under the repo); the review
agent stays in this pane.

  ghipr [-i] [--no-agent] <pr-number>
  ghi review <pr-number>     # same

Flags:
  -i, --issue N     Optional flag before PR number
  --no-agent        Checkout + rank files only (no agent)

Same checkout as ghsbpr (PR worktree, ranked files, review prompt).
The review agent starts in this space.
EOF
}
