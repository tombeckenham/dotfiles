# Shared worktree setup helper — used by ghwt and wt
_worktree_setup() {
  local worktree_path="$1"
  local repo_root=$(dirname "$(git -C "$worktree_path" rev-parse --path-format=absolute --git-common-dir)")
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
    [[ -f "$repo_root/local.db" ]] && cp "$repo_root/local.db" "$worktree_path/local.db"

    # Copy every .env.local found in the source repo, preserving relative paths.
    # These files are gitignored so they don't come across with the worktree checkout.
    local env_file rel dest env_count=0
    while IFS= read -r env_file; do
      rel="${env_file#$repo_root/}"
      dest="$worktree_path/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "$env_file" "$dest"
      echo "  → Copied $rel"
      env_count=$((env_count+1))
    done < <(find "$repo_root" \
      \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build -o -name .turbo \) -prune \
      -o -type f -name '.env.local' -print)
    [[ $env_count -gt 0 ]] && echo "Copied $env_count .env.local file(s)"

    # Copy gitignored .vscode files (tracked ones come with the checkout).
    if [[ -d "$repo_root/.vscode" ]]; then
      local vs_file vs_rel vs_count=0
      while IFS= read -r vs_file; do
        vs_rel="${vs_file#$repo_root/}"
        if git -C "$repo_root" check-ignore -q "$vs_rel"; then
          mkdir -p "$(dirname "$worktree_path/$vs_rel")"
          cp "$vs_file" "$worktree_path/$vs_rel"
          echo "  → Copied $vs_rel"
          vs_count=$((vs_count+1))
        fi
      done < <(find "$repo_root/.vscode" -type f)
      [[ $vs_count -gt 0 ]] && echo "Copied $vs_count .vscode file(s)"
    fi

    # Detect package manager by lockfile and install at the worktree root.
    if [[ -f "$worktree_path/package.json" ]]; then
      local pm=""
      if [[ -f "$worktree_path/bun.lock" || -f "$worktree_path/bun.lockb" ]]; then
        pm="bun"
      elif [[ -f "$worktree_path/pnpm-lock.yaml" ]]; then
        pm="pnpm"
      elif [[ -f "$worktree_path/package-lock.json" ]]; then
        pm="npm"
      fi
      if [[ -n "$pm" ]]; then
        echo "Installing packages with $pm..."
        (cd "$worktree_path" && "$pm" install)
      else
        echo "No bun/pnpm/npm lockfile found; skipping install."
      fi
    fi
  fi
}
