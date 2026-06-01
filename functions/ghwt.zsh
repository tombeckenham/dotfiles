# Create a GitHub issue (or develop an existing one) and set up a worktree
# Usage: ghwt [-c] [-f] [-b <branch>] [-i <number>] "Issue title"
#        ghwt -e <number>   # open existing worktree/branch for review
# Automatically detects forks and routes issues to the upstream repo by default;
# pass -f/--fork to target the fork's own issue tracker instead.
ghwt() {
  local base_branch="" issue_number="" branch_name="" target_fork=false existing_mode=false

  # Parse flags
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
      -h|--help)
        echo "Usage: ghwt [-c] [-f] [-b <branch>] [-i <number>] \"Issue title\""
        echo "       ghwt -e <number>"
        echo "  -b, --branch B  Use existing branch instead of creating one"
        echo "  -c, --current   Branch from current branch instead of main"
        echo "  -e, --existing N  Open existing worktree/branch for issue N to review progress"
        echo "  -f, --fork      Target the fork's own issues instead of upstream"
        echo "  -i, --issue N   Develop an existing issue instead of creating one"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Automatically detects forks and creates issues on the upstream repo,"
        echo "unless -f/--fork is passed (then issues live on the fork itself)."
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwt [-c] [-f] [-b <branch>] [-i <number>] \"Issue title\""
        return 1
        ;;
    esac
  done

  # Detect if this repo is a fork by comparing origin URL to what gh resolves
  # (gh resolves forks to the parent repo, so a mismatch means it's a fork)
  local is_fork=false upstream_repo="" fork_repo=""
  fork_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')
  upstream_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  if [[ -n "$fork_repo" && -n "$upstream_repo" && "$fork_repo" != "$upstream_repo" ]]; then
    is_fork=true
  fi

  # Pick the repo where issues live. Default: upstream when fork detected,
  # otherwise the current repo. With -f/--fork, force the fork itself.
  local issue_repo="$upstream_repo"
  if $target_fork; then
    if $is_fork; then
      issue_repo="$fork_repo"
    else
      echo "Note: -f/--fork passed but this repo is not a fork; ignoring."
    fi
  fi

  if $is_fork; then
    echo "Detected fork of $upstream_repo; issues → $issue_repo"
  fi

  # -e/--existing: open an existing worktree/branch for this issue to review progress
  if $existing_mode; then
    if [[ -z "$issue_number" ]]; then
      echo "Error: -e/--existing requires an issue number"
      return 1
    fi

    local repo_root repo_name worktree_path
    repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
    repo_name=$(basename "$repo_root")
    worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue_number}"

    if [[ ! -d "$worktree_path" ]]; then
      # No worktree yet — find a branch matching "<issue>-<slug>" locally first, then on origin
      local found_branch=""
      found_branch=$(git for-each-ref --format='%(refname:short)' "refs/heads/${issue_number}-*" 2>/dev/null | head -1)
      if [[ -z "$found_branch" ]]; then
        git fetch origin 2>/dev/null
        found_branch=$(git ls-remote --heads origin 2>/dev/null \
          | grep -E "refs/heads/${issue_number}-[a-z0-9-]+$" \
          | head -1 | sed 's#.*refs/heads/##')
      fi

      if [[ -z "$found_branch" ]]; then
        echo "No existing branch found for issue #${issue_number}"
        return 1
      fi

      echo "Found branch: $found_branch"
      git fetch origin "$found_branch" 2>/dev/null

      mkdir -p ~/.claude/worktrees
      git worktree add "$worktree_path" "$found_branch" || return 1
      echo "Worktree created at: $worktree_path"
      _worktree_setup "$worktree_path"
    else
      echo "Found existing worktree at: $worktree_path"
    fi

    local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
    local claude_cmd="claude --permission-mode plan \"Review progress on GitHub issue #${issue_number}. Run ${issue_view_cmd} for details, then inspect the working tree and recent commits to summarise progress and what remains.\""

    cursor --new-window "$worktree_path"
    splt

    if [[ -n "${TMUX:-}" ]]; then
      tmux new-window -n "review-${issue_number}" -c "$worktree_path" "$claude_cmd"
    else
      cd "$worktree_path" && eval "$claude_cmd"
    fi
    return 0
  fi

  # Resolve the upstream default branch (gh resolves forks to parent, so this
  # returns the upstream default even when we're in a fork checkout).
  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)
  default_branch="${default_branch:-main}"

  # Pick the authoritative source for the default branch.
  local sync_source="origin"
  if $is_fork; then
    if git remote get-url upstream >/dev/null 2>&1; then
      sync_source="upstream"
    else
      sync_source="https://github.com/${upstream_repo}.git"
    fi
  fi

  # Sync the local default branch before branching off it.
  echo "Syncing $default_branch from $sync_source..."
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null)
  if [[ "$current_branch" == "$default_branch" ]]; then
    git pull --ff-only "$sync_source" "$default_branch" 2>/dev/null \
      || echo "  (local $default_branch not fast-forwardable; continuing)"
  else
    # Refspec form updates the local branch without checkout. Fails if the branch
    # is checked out in another worktree — fall back to a plain fetch in that case
    # since the remote-tracking ref is all we need to branch from.
    git fetch "$sync_source" "${default_branch}:${default_branch}" 2>/dev/null \
      || git fetch "$sync_source" "$default_branch" 2>/dev/null
  fi

  # Always refresh origin's tracking refs too (for branch listings etc.)
  git fetch origin 2>/dev/null

  # If no existing issue, create one from title
  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
      return 1
    fi

    # Optionally capture a one-line body. Default is no body (just the title).
    local body=""
    if [[ -t 0 ]]; then
      printf "Do you want to add more to the issue? [y/N] "
      local add_body_reply
      read -r add_body_reply
      if [[ "$add_body_reply" == [Yy]* ]]; then
        printf "Body: "
        read -r body
      fi
    fi

    local issue_url
    issue_url=$(gh issue create -R "$issue_repo" --title "$title" --body "$body" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "Failed to create issue: $issue_url"
      return 1
    fi

    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
    echo "Created issue #$issue_number: $issue_url"
  else
    echo "Developing existing issue #$issue_number"
  fi

  if [[ -z "$branch_name" ]]; then
    # Check for any branches already associated with this issue (e.g. from another machine).
    # Both our fork flow and `gh issue develop` name branches "<issue_number>-<slug>".
    local -a existing_branches
    existing_branches=("${(@f)$(git ls-remote --heads origin 2>/dev/null \
      | grep -E "refs/heads/${issue_number}-[a-z0-9-]+$" \
      | sed 's#.*refs/heads/##')}")
    # (@f) on empty input yields a single empty element — strip it
    [[ ${#existing_branches[@]} -eq 1 && -z "${existing_branches[1]}" ]] && existing_branches=()

    local chosen=""
    if [[ ${#existing_branches[@]} -eq 1 ]]; then
      printf "Found existing branch for issue: %s\nUse it? [Y/n] " "${existing_branches[1]}"
      local reply
      read -r reply
      if [[ -z "$reply" || "$reply" == [Yy]* ]]; then
        chosen="${existing_branches[1]}"
      else
        echo "Ignoring existing branch."
      fi
    elif [[ ${#existing_branches[@]} -gt 1 ]]; then
      echo "Found multiple branches for issue #${issue_number}:"
      local i=1
      for b in "${existing_branches[@]}"; do
        echo "  [$i] $b"
        i=$((i+1))
      done
      printf "Select branch [1-%d, or n to create new]: " "${#existing_branches[@]}"
      local reply
      read -r reply
      if [[ "$reply" == <-> ]] && (( reply >= 1 && reply <= ${#existing_branches[@]} )); then
        chosen="${existing_branches[$reply]}"
      else
        echo "Ignoring existing branches."
      fi
    fi

    if [[ -n "$chosen" ]]; then
      branch_name="$chosen"
      # Ensure the branch is available locally for the worktree
      git fetch origin "$branch_name" 2>/dev/null
    fi
  fi

  if [[ -z "$branch_name" ]]; then
    if $is_fork; then
      # For forks, create branch manually (gh issue develop requires write access to upstream)
      local issue_title
      issue_title=$(gh issue view "$issue_number" -R "$issue_repo" --json title -q '.title' 2>&1)
      if [[ $? -ne 0 ]]; then
        echo "Failed to fetch issue title: $issue_title"
        return 1
      fi
      local slug
      slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
      branch_name="${issue_number}-${slug}"

      # Determine the commit to branch from.
      # -c (base_branch set): user wants to branch off their own fork's branch → origin.
      # Default: branch from the just-synced local default branch (which tracks upstream).
      local base_ref
      if [[ -n "$base_branch" ]]; then
        base_ref="origin/$base_branch"
      elif [[ "$sync_source" == "upstream" ]]; then
        base_ref="upstream/$default_branch"
      elif [[ "$sync_source" == "origin" ]]; then
        base_ref="origin/$default_branch"
      else
        # Ad-hoc upstream URL — the sync fetch left FETCH_HEAD pointing at the tip
        base_ref="FETCH_HEAD"
      fi

      git branch "$branch_name" "$base_ref"
      git push -u origin "$branch_name"
      echo "Created branch: $branch_name (from $base_ref)"
    else
      # Use gh issue develop to create a branch
      local develop_output
      local -a base_arg=()
      [[ -n "$base_branch" ]] && base_arg=(--base "$base_branch")
      develop_output=$(gh issue develop "$issue_number" "${base_arg[@]}" 2>&1)
      if [[ $? -ne 0 ]]; then
        echo "Failed to create branch: $develop_output"
        return 1
      fi

      # Extract branch name from the URL line (format: "github.com/owner/repo/tree/branch-name")
      branch_name=$(echo "$develop_output" | grep '/tree/' | head -1 | grep -oE '[^/]+$')
      echo "Created branch: $branch_name"
    fi
  else
    echo "Using existing branch: $branch_name"
  fi

  # Ensure worktrees directory exists
  mkdir -p ~/.claude/worktrees

  # Resolve main repo root (works from both main checkout and linked worktrees)
  local repo_root
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  local repo_name
  repo_name=$(basename "$repo_root")
  local worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue_number}"

  # Create the worktree
  git worktree add "$worktree_path" "$branch_name"

  echo "Worktree created at: $worktree_path"

  # Run worktree setup
  _worktree_setup "$worktree_path"

  # Build the claude command
  local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
  local claude_cmd="claude --permission-mode acceptEdits \"Implement GitHub issue #${issue_number}. First run ${issue_view_cmd} for details. If the issue body is empty or doesn't have enough context to plan confidently, ask me what I want to accomplish and any constraints, then update the issue body via 'gh issue edit ${issue_number} -R ${issue_repo}' so the context is captured on GitHub before you start.\""

  # Open Cursor and tile left
  cursor --new-window "$worktree_path"

  # Show PICK ME banner and tile Cursor left
  splt

  if [[ -n "${TMUX:-}" ]]; then
    # Tmux: launch Claude in a new tmux window (persistent/reattachable)
    tmux new-window -n "claude-${issue_number}" -c "$worktree_path" "$claude_cmd"
  else
    # No tmux: run Claude in current terminal
    cd "$worktree_path" && eval "$claude_cmd"
  fi
}

