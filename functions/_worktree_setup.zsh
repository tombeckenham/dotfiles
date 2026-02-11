# Shared worktree setup helper — used by ghwt and wt
_worktree_setup() {
  local worktree_path="$1" repo_root="$2"
  if [[ -f "$repo_root/.cursor/worktrees.json" ]]; then
    local cmd
    while IFS= read -r cmd; do
      cmd="${cmd//\$ROOT_WORKTREE_PATH/$repo_root}"
      (cd "$worktree_path" && eval "$cmd")
    done < <(jq -r '.setup-worktree[]?' "$repo_root/.cursor/worktrees.json")
  else
    [[ -f "$repo_root/.env.local" ]] && cp "$repo_root/.env.local" "$worktree_path/.env.local"
    [[ -f "$repo_root/local.db" ]] && cp "$repo_root/local.db" "$worktree_path/local.db"
  fi
}
