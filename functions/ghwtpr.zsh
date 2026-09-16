# Create a worktree to review a GitHub PR and launch Claude with review-pr
# Usage: ghwtpr [-i] <pr-number>
# Detects forks and checks out the PR head (including PRs raised from a
# contributor's fork) via `gh pr checkout`, which wires up the fork remote and
# push config so maintainers can push fixes back when edits are allowed.
# Also gathers staleness info (how far behind the base branch the PR is) and
# feeds it into the review so relevance/out-of-date concerns get assessed.
ghwtpr() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: ghwtpr [-i] <pr-number>"
    echo "  Check out a PR into a Herdr worktree and run /review-pr + /ponytail-review"
    echo "  -i, --issue  Optional flag before PR number (e.g. ghwtpr -i 42)"
    echo ""
    echo "Handles PRs from forks. Updates from the base branch if behind or conflicting"
    echo "(local merge/rebase, not pushed), then reviews."
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

  _ghsb_checkout_pr "$pr_number" || return 1
  local worktree_path="${GHSB_CHECKOUT[worktree]}"

  local ai_tool review_prompt
  ai_tool=$(_ghsb_pick_ai "$pr_number")
  review_prompt=$(_ghsb_pr_review_prompt "$ai_tool")

  splt "$worktree_path"

  if [[ -n "${TMUX:-}" ]]; then
    tmux new-window -n "${ai_tool}-review-${pr_number}" -c "$worktree_path" \
      "${ai_tool} $(printf %q "$review_prompt")"
  else
    cd "$worktree_path" && "$ai_tool" "$review_prompt"
  fi
}
