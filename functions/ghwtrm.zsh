# Remove a worktree created by ghwt / ghsb / wt
# Usage: ghwtrm [-i] [<issue-number>]
#   If no issue number is given and cwd is inside a worktree, removes it.
ghwtrm() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: ghwtrm [-i] [<issue-number>]"
    echo "  Remove a Herdr worktree created for the given issue"
    echo "  If no issue number is given, targets the current worktree"
    echo "  -i, --issue  Optional flag before issue number (e.g. ghwtrm -i 42)"
    return 0
  fi

  local issue_number
  if [[ "$1" == "-i" || "$1" == "--issue" ]]; then
    issue_number="$2"
    if [[ -z "$issue_number" ]]; then
      echo "Error: -i requires an issue number"
      return 1
    fi
  elif [[ -n "$1" ]]; then
    issue_number="$1"
  fi

  local repo_root
  repo_root=$(_ghsb_repo_root) || {
    echo "Error: Not in a git repository"
    return 1
  }

  local wt_path="" ws=""
  if [[ -n "$issue_number" ]]; then
    if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
      echo "Error: Issue number must be numeric"
      return 1
    fi
    local hit rest
    hit=$(_ghsb_herdr_wt_find_issue "$repo_root" "$issue_number") || hit=""
    if [[ -z "$hit" ]]; then
      echo "Error: No worktree found for issue #${issue_number}"
      return 1
    fi
    wt_path=${hit%%$'\t'*}
    rest=${hit#*$'\t'}
    ws=${rest%%$'\t'*}
  else
    local listing
    listing=$(_ghsb_herdr_wt_list "$repo_root") || listing=""
    local hit
    hit=$(printf '%s\n' "$listing" | jq -r --arg p "$PWD" '
      .result.worktrees[]
      | select(.is_linked_worktree == true and ($p | startswith(.path)))
      | "\(.path)\t\(.open_workspace_id // "")"
    ' | head -1)
    if [[ -z "$hit" && "$PWD" == "$HOME/.claude/worktrees/"* ]]; then
      local worktree_dir
      worktree_dir="${PWD#$HOME/.claude/worktrees/}"
      worktree_dir="${worktree_dir%%/*}"
      wt_path="$HOME/.claude/worktrees/${worktree_dir}"
    fi
    if [[ -n "$hit" ]]; then
      wt_path=${hit%%$'\t'*}
      ws=${hit#*$'\t'}
    fi
    if [[ -z "$wt_path" ]]; then
      echo "Error: No issue number given and not inside a linked worktree"
      return 1
    fi
  fi

  if [[ "$PWD" == "$wt_path"* ]]; then
    cd "$repo_root"
  fi

  if [[ -n "$ws" && "$ws" != "null" ]]; then
    herdr worktree remove --workspace "$ws" --force 2>&1 || {
      echo "Failed to remove Herdr worktree $ws"
      return 1
    }
  else
    if ! git worktree remove "$wt_path" --force 2>/dev/null && ! git worktree remove "$wt_path"; then
      echo "Failed to remove worktree. Close any open files and try again."
      return 1
    fi
    [[ -d "$wt_path" ]] && rm -rf "$wt_path"
  fi

  echo "Removed worktree: $wt_path"
}
