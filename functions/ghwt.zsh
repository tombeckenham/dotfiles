# Create a GitHub issue (or develop an existing one) and set up a worktree
# Usage: ghwt [-c] [-b <branch>] [-i <number>] "Issue title"
# Automatically detects forks and routes issues to the upstream repo.
ghwt() {
  local base_branch="" issue_number="" branch_name=""

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
      -h|--help)
        echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
        echo "  -b, --branch B  Use existing branch instead of creating one"
        echo "  -c, --current   Branch from current branch instead of main"
        echo "  -i, --issue N   Develop an existing issue instead of creating one"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Automatically detects forks and creates issues on the upstream repo."
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
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
    echo "Detected fork of $upstream_repo"
  fi

  # Fetch latest remote refs before branching
  git fetch origin 2>/dev/null

  # If no existing issue, create one from title
  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ghwt [-c] [-b <branch>] [-i <number>] \"Issue title\""
      return 1
    fi

    local issue_url
    if $is_fork; then
      issue_url=$(gh issue create -R "$upstream_repo" --title "$title" --body "" 2>&1)
    else
      issue_url=$(gh issue create --title "$title" --body "" 2>&1)
    fi
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
      issue_title=$(gh issue view "$issue_number" -R "$upstream_repo" --json title -q '.title' 2>&1)
      if [[ $? -ne 0 ]]; then
        echo "Failed to fetch issue title: $issue_title"
        return 1
      fi
      local slug
      slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
      branch_name="${issue_number}-${slug}"

      local default_branch
      default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)
      local base="${base_branch:-${default_branch:-main}}"
      git branch "$branch_name" "origin/$base"
      git push -u origin "$branch_name"
      echo "Created branch: $branch_name"
    else
      # Use gh issue develop to create a branch
      local develop_output base_arg=""
      [[ -n "$base_branch" ]] && base_arg="--base $base_branch"
      develop_output=$(gh issue develop "$issue_number" $base_arg 2>&1)
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
  local issue_view_cmd="gh issue view ${issue_number}"
  $is_fork && issue_view_cmd="gh issue view ${issue_number} -R ${upstream_repo}"
  local claude_cmd="claude --permission-mode plan \"Implement GitHub issue #${issue_number}. Run ${issue_view_cmd} for details.\""

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

