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

  # Detect fork (same heuristic as ghwtpr / ghwt)
  local is_fork=false upstream_repo="" fork_repo=""
  fork_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')
  upstream_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  if [[ -n "$fork_repo" && -n "$upstream_repo" && "$fork_repo" != "$upstream_repo" ]]; then
    is_fork=true
    echo "Detected fork of $upstream_repo"
  fi

  # Open links first (vscode.dev PR URL; local worktree if present).
  local _early_repo="${upstream_repo:-$fork_repo}"
  local _early_root _early_name _early_wt=""
  _early_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null) || true
  _early_name=$(basename "${_early_root:-}")
  [[ -n "$_early_name" ]] && _early_wt="$HOME/.claude/worktrees/${_early_name}-${pr_number}"
  _ghsb_print_open_first "$_early_repo" "" "$pr_number" "$_early_wt"
  echo ""

  local -a repo_args=()
  $is_fork && repo_args=(-R "$upstream_repo")

  local pr_data
  pr_data=$(gh pr view "${repo_args[@]}" "$pr_number" \
    --json headRefName,baseRefName,isCrossRepository,maintainerCanModify,mergeable,mergeStateStatus,createdAt,updatedAt,headRepositoryOwner,url,title 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch PR info: $pr_data"
    return 1
  fi
  local head_ref base_ref is_cross can_modify mergeable merge_state created_at updated_at fork_owner pr_url pr_title
  head_ref=$(echo "$pr_data" | jq -r '.headRefName')
  base_ref=$(echo "$pr_data" | jq -r '.baseRefName')
  is_cross=$(echo "$pr_data" | jq -r '.isCrossRepository')
  can_modify=$(echo "$pr_data" | jq -r '.maintainerCanModify')
  mergeable=$(echo "$pr_data" | jq -r '.mergeable')
  merge_state=$(echo "$pr_data" | jq -r '.mergeStateStatus')
  created_at=$(echo "$pr_data" | jq -r '.createdAt')
  updated_at=$(echo "$pr_data" | jq -r '.updatedAt')
  fork_owner=$(echo "$pr_data" | jq -r '.headRepositoryOwner.login')
  pr_url=$(echo "$pr_data" | jq -r '.url')
  pr_title=$(echo "$pr_data" | jq -r '.title')

  local local_branch="$head_ref"
  if [[ "$is_cross" == "true" ]]; then
    echo "PR #${pr_number} is from fork ${fork_owner} (cross-repo)"
  fi

  local repo_root repo_name worktree_path session_id issue_repo origin_repo
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  repo_name=$(basename "$repo_root")
  mkdir -p ~/.claude/worktrees
  worktree_path="$HOME/.claude/worktrees/${repo_name}-${pr_number}"
  session_id="${repo_name}-pr-${pr_number}"
  issue_repo="$upstream_repo"
  origin_repo="$fork_repo"
  [[ -z "$issue_repo" ]] && issue_repo="$origin_repo"

  if [[ -d "$worktree_path" ]]; then
    echo "Worktree already exists at: $worktree_path"
  else
    if git show-ref --verify --quiet "refs/heads/${local_branch}"; then
      echo "Error: local branch '${local_branch}' already exists but has no worktree."
      echo "Delete it first (git branch -D ${local_branch}) or resolve manually."
      return 1
    fi

    echo "Checking out PR #${pr_number} (branch '${local_branch}')..."
    if ! git worktree add --detach "$worktree_path" >/dev/null; then
      echo "Failed to create worktree"
      return 1
    fi

    local -a checkout_args=("$pr_number")
    $is_fork && checkout_args+=(-R "$upstream_repo")
    if ! (cd "$worktree_path" && gh pr checkout "${checkout_args[@]}"); then
      echo "Failed to check out PR #${pr_number}"
      git worktree remove --force "$worktree_path" 2>/dev/null
      git branch -D "$local_branch" 2>/dev/null
      return 1
    fi

    if [[ "$is_cross" == "true" ]]; then
      if [[ "$can_modify" == "true" ]]; then
        echo "Maintainer edits allowed — pushes go back to ${fork_owner}'s fork."
      else
        echo "Note: maintainer edits are NOT allowed on this PR (read-only review)."
      fi
    fi

    echo "Worktree created at: $worktree_path"
    _worktree_setup "$worktree_path"
  fi

  # Freshness relative to base
  local base_fetch_source="origin" behind="?" ahead="?"
  $is_fork && base_fetch_source="https://github.com/${upstream_repo}.git"
  if git -C "$worktree_path" fetch "$base_fetch_source" "$base_ref" 2>/dev/null; then
    behind=$(git -C "$worktree_path" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)
    ahead=$(git -C "$worktree_path" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)
  fi
  echo "PR is ${behind} commit(s) behind ${base_ref}, ${ahead} ahead (mergeable: ${mergeable})"

  local relevance_note="PR #${pr_number} freshness context for this review:
- Title: ${pr_title}
- Base branch: ${base_ref}
- Behind ${base_ref} by: ${behind} commit(s)
- Ahead of ${base_ref} by: ${ahead} commit(s)
- Mergeable: ${mergeable} / merge state: ${merge_state}
- From fork: ${is_cross} (owner: ${fork_owner}, maintainer edits: ${can_modify})
- Opened: ${created_at}; last updated: ${updated_at}

As part of the review, assess how relevant and current this PR still is. If it is
significantly behind ${base_ref}, conflicting, or stale, flag it, explain whether
the changes are still applicable to the current codebase, and recommend whether it
needs a rebase or update before it can be merged."

  # Artifacts: ranked files
  local art
  art="$GHSB_ARTIFACTS_DIR/${session_id}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$art"
  local base_ref_for_diff="FETCH_HEAD"
  # Prefer origin/base if available in the worktree
  if git -C "$worktree_path" rev-parse --verify "origin/${base_ref}" >/dev/null 2>&1; then
    base_ref_for_diff="origin/${base_ref}"
  elif git -C "$worktree_path" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    base_ref_for_diff="$base_ref"
  fi
  (
    cd "$worktree_path" || exit 0
    _ghsb_rank_files "$base_ref_for_diff" "$art/files-to-review.txt"
  )
  if [[ -s "$art/files-to-review.txt" ]]; then
    echo ""
    echo "Most relevant files to review manually (in order):"
    head -20 "$art/files-to-review.txt" | sed 's/^/  /'
    echo "  (full list: $art/files-to-review.txt)"
    echo ""
  fi

  # Preview URL if any
  local preview_url=""
  preview_url=$(_ghsb_resolve_preview_url "$issue_repo" "$pr_number" 2>/dev/null) || preview_url=""

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

  {
    echo "# ghsbpr — PR #${pr_number}"
    echo ""
    echo "- Title: $pr_title"
    echo "- PR: $pr_url"
    echo "- Branch: $head_ref"
    echo "- Base: $base_ref (${behind} behind, ${ahead} ahead)"
    echo "- Worktree: $worktree_path"
    [[ -n "$preview_url" ]] && echo "- Preview: $preview_url"
    echo ""
    echo "## Files to review (ranked)"
    echo ""
    cat "$art/files-to-review.txt" 2>/dev/null || echo "(none)"
  } > "$art/SUMMARY.md"

  local review_prompt
  if [[ "$ai_tool" == "grok" ]]; then
    review_prompt="/review-pr ${pr_number}

${relevance_note}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files for findings."
  else
    review_prompt="/pr-review-toolkit:review-pr ${pr_number}

${relevance_note}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files for findings."
  fi

  local launch_line="" pane_id="" agent_name="" workspace_id=""
  if command -v herdr >/dev/null 2>&1; then
    echo "Launching ${ai_tool} review in Herdr (permission-mode auto)..."
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
      echo "   or:  herdr agent attach $agent_name"
    fi
  fi

  if [[ -z "$pane_id" ]]; then
    echo "Herdr launch unavailable; falling back to tmux/foreground."
    local flags
    flags=$(_ghsb_ai_flags "$ai_tool")
    if [[ -n "${TMUX:-}" ]]; then
      tmux new-window -n "${ai_tool}-review-${pr_number}" -c "$worktree_path" \
        "${ai_tool} ${flags} $(printf '%q' "$review_prompt")"
    else
      (cd "$worktree_path" && eval "${ai_tool} ${flags} $(printf '%q' "$review_prompt")")
    fi
  fi

  _ghsb_print_links "$issue_repo" "$head_ref" "$pr_number" "$preview_url" "" "$worktree_path"
  echo ""
  echo "Session:   $session_id"
  echo "Artifacts: $art"
  echo "Summary:   $art/SUMMARY.md"
}
