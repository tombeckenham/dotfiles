# Create a branch and worktree without a GitHub issue (Cursor / tmux path)
# Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]
# Inside Herdr, use ghb / ghi branch instead.
ghwtb() {
  local base_branch="" branch_name=""

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
        echo "Creates a new branch and Herdr worktree without opening a GitHub issue."
        echo "Worktrees live at ~/.herdr/worktrees/{repo}/{branch-slug}."
        echo "Inside Herdr, use ghb (or ghi branch) instead of ghwtb."
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        echo "Usage: ghwtb [-c] [-b <branch>] [<branch-name-or-description>]"
        return 1
        ;;
    esac
  done

  _ghsb_parse_branch_args ghwtb "$branch_name" "$@" || return 1
  _ghsb_checkout_branch ghwtb "$base_branch" || return 1

  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local sanitized_branch_name
  sanitized_branch_name=$(_ghsb_herdr_branch_slug "${GHSB_CHECKOUT[branch]}")
  local ai_tool
  ai_tool=$(_ghsb_pick_ai "${#GHSB_CHECKOUT[branch]}")
  local ai_prompt
  ai_prompt=$(_ghsb_branch_prompt "${GHSB_CHECKOUT[branch]}" "${GHSB_CHECKOUT[description]:-}")
  local ai_cmd="${ai_tool} --permission-mode auto $(printf %q "$ai_prompt")"

  splt "$worktree_path"

  if [[ -n "${TMUX:-}" ]]; then
    tmux new-window -n "${ai_tool}-${sanitized_branch_name}" -c "$worktree_path" "$ai_cmd"
  else
    cd "$worktree_path" && eval "$ai_cmd"
  fi
}
