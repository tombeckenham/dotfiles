# Shared worktree setup helper — used by ghwt and wt
_worktree_setup() {
  local worktree_path="$1" repo_root="$2"
  if [[ -f "$repo_root/.cursor/worktrees.json" ]]; then
    echo "Running worktree setup from .cursor/worktrees.json..."
    local cmd exit_code failed=0
    while IFS= read -r cmd; do
      cmd="${cmd//\$ROOT_WORKTREE_PATH/$repo_root}"
      echo "  → $cmd"
      (cd "$worktree_path" && eval "$cmd")
      exit_code=$?
      if [[ $exit_code -ne 0 ]]; then
        echo "  ✗ Command failed (exit $exit_code)"
        failed=1
      fi
    done < <(jq -r '."setup-worktree"[]?' "$repo_root/.cursor/worktrees.json")
    if [[ $failed -eq 1 ]]; then
      echo "⚠ Worktree setup completed with errors"
      return 1
    else
      echo "Worktree setup complete."
    fi
  else
    [[ -f "$repo_root/.env.local" ]] && cp "$repo_root/.env.local" "$worktree_path/.env.local"
    [[ -f "$repo_root/local.db" ]] && cp "$repo_root/local.db" "$worktree_path/local.db"
  fi
}
