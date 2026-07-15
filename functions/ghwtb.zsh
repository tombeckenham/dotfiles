# Create a branch and worktree without a GitHub issue
# Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]
ghwtb() {
  local base_branch="" branch_name="" description=""

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
      -h|--help)
        echo "Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]"
        echo "  -b, --branch B  Use this branch name (description arg becomes AI context only)"
        echo "  -c, --current   Branch from current branch instead of default"
        echo "  -h, --help      Show this help"
        echo ""
        echo "Creates a new branch and worktree without opening a GitHub issue."
        echo "Worktrees live at ~/.claude/worktrees/{repo}-{sanitised-branch}."
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]"
        return 1
        ;;
    esac
  done

  description="$*"
  if [[ -z "$branch_name" ]]; then
    branch_name="$1"
    if [[ -z "$branch_name" ]]; then
      echo "Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]"
      return 1
    fi
    shift
    description="$*"
    if [[ "$branch_name" == *" "* ]]; then
      description="$branch_name${description:+ $description}"
      branch_name=$(echo "$branch_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9\/]/-/g; s/--*/-/g; s/^-//; s/-$//')
    fi
  elif [[ -z "$description" ]]; then
    description="$branch_name"
  fi

  # Detect fork (same heuristic as ghwt)
  local is_fork=false upstream_repo="" fork_repo=""
  fork_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')
  upstream_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  if [[ -n "$fork_repo" && -n "$upstream_repo" && "$fork_repo" != "$upstream_repo" ]]; then
    is_fork=true
    echo "Detected fork of $upstream_repo"
  fi

  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)
  default_branch="${default_branch:-main}"

  local sync_source="origin"
  if $is_fork; then
    if git remote get-url upstream >/dev/null 2>&1; then
      sync_source="upstream"
    else
      sync_source="https://github.com/${upstream_repo}.git"
    fi
  fi

  local branch_exists=false
  if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
    branch_exists=true
  elif git show-ref --verify --quiet "refs/remotes/origin/${branch_name}"; then
    branch_exists=true
    echo "Fetching existing branch '$branch_name' from origin..."
    git fetch origin "$branch_name" || return 1
  fi

  if ! $branch_exists; then
    echo "Syncing $default_branch from $sync_source..."
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$base_branch" ]]; then
      :
    elif [[ "$current_branch" == "$default_branch" ]]; then
      git pull --ff-only "$sync_source" "$default_branch" 2>/dev/null \
        || echo "  (local $default_branch not fast-forwardable; continuing)"
    else
      git fetch "$sync_source" "${default_branch}:${default_branch}" 2>/dev/null \
        || git fetch "$sync_source" "$default_branch" 2>/dev/null
    fi
    git fetch origin 2>/dev/null

    local base_ref
    if [[ -n "$base_branch" ]]; then
      base_ref="origin/$base_branch"
    elif [[ "$sync_source" == "upstream" ]]; then
      base_ref="upstream/$default_branch"
    elif [[ "$sync_source" == "origin" ]]; then
      base_ref="origin/$default_branch"
    else
      base_ref="FETCH_HEAD"
    fi

    git branch "$branch_name" "$base_ref" || return 1
    git push -u origin "$branch_name" || return 1
    echo "Created branch: $branch_name (from $base_ref)"
  else
    echo "Using existing branch: $branch_name"
  fi

  mkdir -p ~/.claude/worktrees

  local repo_root repo_name sanitized_branch_name worktree_path
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  repo_name=$(basename "$repo_root")
  sanitized_branch_name=$(echo "$branch_name" | sed 's/[\/<>:"|?*]/-/g')
  worktree_path="$HOME/.claude/worktrees/${repo_name}-${sanitized_branch_name}"

  if [[ -d "$worktree_path" ]]; then
    echo "Worktree already exists at: $worktree_path"
  else
    git worktree add "$worktree_path" "$branch_name" || return 1
    echo "Worktree created at: $worktree_path"
    _worktree_setup "$worktree_path"
  fi

  local selector="${#branch_name}"
  local ai_tool="claude"
  if (( selector % 2 == 0 )); then
    ai_tool="grok"
  fi

  local ai_cmd="${ai_tool} --permission-mode auto \"Work on branch ${branch_name}."
  if [[ -n "$description" && "$description" != "$branch_name" ]]; then
    ai_cmd+=" Goal: ${description}."
  fi
  ai_cmd+=" Ask me for any missing context before you start.\""

  splt "$worktree_path"

  if [[ -n "${TMUX:-}" ]]; then
    tmux new-window -n "${ai_tool}-${sanitized_branch_name}" -c "$worktree_path" "$ai_cmd"
  else
    cd "$worktree_path" && eval "$ai_cmd"
  fi
}