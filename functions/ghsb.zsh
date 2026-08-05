# ghsb — GitHub issue → Herdr session → optional Cloudflare sandbox (Architecture A)
# Usage:
#   ghsb [-c] [-f] [-b <branch>] [-i <number>] [--local|--cf] "Issue title"
#   ghsb finish [session-id|issue]
#   ghsb review <pr-number>   # same as ghsbpr
#   ghsb status|attach|links|rm|list
#
# Default backend: local worktree + Herdr agent (Ghostty-friendly).
# With GHSB_API_URL (or --cf): also provision a Cloudflare Sandbox for preview/dev.
# Agents use permission-mode auto (not always-approve).

ghsb() {
  local sub="${1:-}"
  case "$sub" in
    finish|status|attach|links|rm|list|review|help|-h|--help)
      shift
      case "$sub" in
        finish) _ghsb_finish "$@" ;;
        review) ghsbpr "$@" ;;
        status) _ghsb_status "$@" ;;
        attach) _ghsb_attach "$@" ;;
        links) _ghsb_links_cmd "$@" ;;
        rm) _ghsb_rm "$@" ;;
        list) _ghsb_list ;;
        help|-h|--help) _ghsb_help ;;
      esac
      return $?
      ;;
  esac
  _ghsb_start "$@"
}

_ghsb_help() {
  cat <<'EOF'
ghsb — sandbox-oriented replacement for the ghwt session layer (Architecture A)

Start a session (issue + branch + worktree + Herdr agent):
  ghsb [-c] [-f] [-b <branch>] [-i <N>] [--local|--cf] "Issue title"

Subcommands:
  ghsb finish [id]   After implementation: PR, Playwright video (if UI),
                     pr-review agent, ranked files, preview/dev links
  ghsb review <pr>   Review an existing PR in Herdr (alias: ghsbpr)
  ghsb status [id]   Show session metadata
  ghsb attach [id]   Attach Herdr agent pane (or print CF terminal URL)
  ghsb links [id]    Print review / preview / github.dev links
  ghsb list          List sessions
  ghsb rm [id]       Remove session metadata (+ optional CF destroy)

Permission mode: auto for grok/claude (not always-approve).

Flags (start):
  -c, --current     Branch from current branch
  -b, --branch B    Use existing branch
  -i, --issue N     Develop existing issue
  -f, --fork        Issues on the fork (not upstream)
  --local           Force local worktree + Herdr only (default)
  --cf              Provision Cloudflare sandbox preview (needs GHSB_API_URL)
  --no-agent        Only create issue/branch/worktree/session (no agent)

Env:
  GHSB_API_URL      Cloudflare Worker base URL (e.g. https://ghsb.you.workers.dev)
  GHSB_API_TOKEN    Optional bearer token for the Worker
  GHSB_HOME         State dir (default: ~/.ghsb)

Finish pipeline:
  1. Ensure branch is pushed and a PR exists
  2. If user-facing files changed → Playwright video of preview/dev URL
  3. Launch pr-review agent (Herdr)
  4. Rank files for manual review
  5. Print PR, github.dev, dev env, and preview links
EOF
}

_ghsb_start() {
  local base_branch="" issue_number="" branch_name="" target_fork=false
  local backend="local" no_agent=false

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
      -f|--fork)
        target_fork=true
        shift
        ;;
      --local)
        backend="local"
        shift
        ;;
      --cf|--cloudflare)
        backend="cloudflare"
        shift
        ;;
      --no-agent)
        no_agent=true
        shift
        ;;
      -h|--help)
        _ghsb_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghsb_help
        return 1
        ;;
    esac
  done

  if [[ "$backend" == "cloudflare" && -z "${GHSB_API_URL:-}" ]]; then
    echo "Warning: --cf set but GHSB_API_URL is empty; falling back to local."
    echo "  Deploy sandbox/ and export GHSB_API_URL=https://…workers.dev"
    backend="local"
  fi

  # ── Repo / fork detection (same as ghwt) ──
  local is_fork=false upstream_repo="" fork_repo=""
  local detect
  detect=$(_ghsb_detect_repo)
  is_fork=${detect%%$'\t'*}
  fork_repo=${detect#*$'\t'}; fork_repo=${fork_repo%%$'\t'*}
  upstream_repo=${detect##*$'\t'}

  local issue_repo="$upstream_repo"
  if $target_fork; then
    if [[ "$is_fork" == "true" ]]; then
      issue_repo="$fork_repo"
    else
      echo "Note: -f/--fork passed but this repo is not a fork; ignoring."
    fi
  fi
  [[ "$is_fork" == "true" ]] && echo "Detected fork of $upstream_repo; issues → $issue_repo"

  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)
  default_branch="${default_branch:-main}"

  # Earliest open links (repo known; branch/worktree refined later).
  local repo_root_early repo_name_early worktree_guess=""
  repo_root_early=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" 2>/dev/null) || true
  repo_name_early=$(basename "${repo_root_early:-}")
  if [[ -n "$issue_number" && -n "$repo_name_early" ]]; then
    worktree_guess="$HOME/.claude/worktrees/${repo_name_early}-${issue_number}"
  fi
  _ghsb_print_open_first "$issue_repo" "${branch_name:-$default_branch}" "" "$worktree_guess"
  echo ""

  local sync_source="origin"
  if [[ "$is_fork" == "true" ]]; then
    if git remote get-url upstream >/dev/null 2>&1; then
      sync_source="upstream"
    else
      sync_source="https://github.com/${upstream_repo}.git"
    fi
  fi

  echo "Syncing $default_branch from $sync_source..."
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null)
  if [[ "$current_branch" == "$default_branch" ]]; then
    git pull --ff-only "$sync_source" "$default_branch" 2>/dev/null \
      || echo "  (local $default_branch not fast-forwardable; continuing)"
  else
    git fetch "$sync_source" "${default_branch}:${default_branch}" 2>/dev/null \
      || git fetch "$sync_source" "$default_branch" 2>/dev/null
  fi
  git fetch origin 2>/dev/null

  # ── Issue ──
  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ghsb [-i N] \"Issue title\""
      return 1
    fi
    local body=""
    if [[ -t 0 ]]; then
      printf "Add issue body? [y/N] "
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

  # ── Branch ──
  if [[ -z "$branch_name" ]]; then
    local -a existing_branches
    existing_branches=("${(@f)$(git ls-remote --heads origin 2>/dev/null \
      | grep -E "refs/heads/${issue_number}-[a-z0-9-]+$" \
      | sed 's#.*refs/heads/##')}")
    [[ ${#existing_branches[@]} -eq 1 && -z "${existing_branches[1]}" ]] && existing_branches=()

    if [[ ${#existing_branches[@]} -eq 1 ]]; then
      printf "Found existing branch: %s\nUse it? [Y/n] " "${existing_branches[1]}"
      local reply
      read -r reply
      if [[ -z "$reply" || "$reply" == [Yy]* ]]; then
        branch_name="${existing_branches[1]}"
        git fetch origin "$branch_name" 2>/dev/null
      fi
    elif [[ ${#existing_branches[@]} -gt 1 ]]; then
      echo "Found multiple branches for issue #${issue_number}:"
      local i=1
      for b in "${existing_branches[@]}"; do
        echo "  [$i] $b"
        i=$((i+1))
      done
      printf "Select [1-%d, or n for new]: " "${#existing_branches[@]}"
      local reply
      read -r reply
      if [[ "$reply" == <-> ]] && (( reply >= 1 && reply <= ${#existing_branches[@]} )); then
        branch_name="${existing_branches[$reply]}"
        git fetch origin "$branch_name" 2>/dev/null
      fi
    fi
  fi

  if [[ -z "$branch_name" ]]; then
    if [[ "$is_fork" == "true" ]]; then
      local issue_title slug base_ref
      issue_title=$(gh issue view "$issue_number" -R "$issue_repo" --json title -q '.title' 2>&1) || {
        echo "Failed to fetch issue title: $issue_title"
        return 1
      }
      slug=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
      branch_name="${issue_number}-${slug}"
      if [[ -n "$base_branch" ]]; then
        base_ref="origin/$base_branch"
      elif [[ "$sync_source" == "upstream" ]]; then
        base_ref="upstream/$default_branch"
      elif [[ "$sync_source" == "origin" ]]; then
        base_ref="origin/$default_branch"
      else
        base_ref="FETCH_HEAD"
      fi
      git branch "$branch_name" "$base_ref"
      git push -u origin "$branch_name"
      echo "Created branch: $branch_name (from $base_ref)"
    else
      local develop_output
      local -a base_arg=()
      [[ -n "$base_branch" ]] && base_arg=(--base "$base_branch")
      develop_output=$(gh issue develop "$issue_number" "${base_arg[@]}" 2>&1) || {
        echo "Failed to create branch: $develop_output"
        return 1
      }
      branch_name=$(echo "$develop_output" | grep '/tree/' | head -1 | grep -oE '[^/]+$')
      echo "Created branch: $branch_name"
    fi
  else
    echo "Using existing branch: $branch_name"
  fi

  # ── Worktree ──
  mkdir -p ~/.claude/worktrees
  local repo_root repo_name worktree_path session_id
  repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  repo_name=$(basename "$repo_root")
  worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue_number}"
  session_id="${repo_name}-${issue_number}"

  if [[ -d "$worktree_path" ]]; then
    echo "Worktree already exists at: $worktree_path"
  else
    git worktree add "$worktree_path" "$branch_name" || return 1
    echo "Worktree created at: $worktree_path"
    _worktree_setup "$worktree_path"
  fi

  # Open links with final branch + worktree (vscode.dev first).
  _ghsb_print_open_first "$issue_repo" "$branch_name" "" "$worktree_path"
  echo ""

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "$issue_number")

  local origin_repo
  origin_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')

  # ── Cloudflare sandbox (preview / remote env) ──
  local cf_sandbox_id="" cf_preview_url="" cf_dev_url="" cf_terminal_url=""
  if [[ "$backend" == "cloudflare" ]]; then
    echo "Provisioning Cloudflare sandbox..."
    local cf_resp
    cf_resp=$(_ghsb_cf_create_session "$session_id" "$origin_repo" "$branch_name" "$issue_number") || true
    if [[ -n "$cf_resp" ]]; then
      cf_sandbox_id=$(echo "$cf_resp" | jq -r '.sandboxId // .id // empty')
      cf_preview_url=$(echo "$cf_resp" | jq -r '.previewUrl // empty')
      cf_dev_url=$(echo "$cf_resp" | jq -r '.devUrl // empty')
      cf_terminal_url=$(echo "$cf_resp" | jq -r '.terminalUrl // empty')
      echo "  sandbox: $cf_sandbox_id"
      [[ -n "$cf_dev_url" ]] && echo "  dev:     $cf_dev_url"
      [[ -n "$cf_preview_url" ]] && echo "  preview: $cf_preview_url"
    else
      echo "  CF provision failed; continuing with local-only session."
      backend="local"
    fi
  fi

  # ── Session record ──
  local session_json
  session_json=$(jq -n \
    --arg id "$session_id" \
    --argjson issue "$issue_number" \
    --arg branch "$branch_name" \
    --arg repo "$issue_repo" \
    --arg origin "$origin_repo" \
    --arg worktree "$worktree_path" \
    --arg backend "$backend" \
    --arg ai "$ai_tool" \
    --arg base "$default_branch" \
    --arg sandbox "${cf_sandbox_id}" \
    --arg preview "${cf_preview_url}" \
    --arg dev "${cf_dev_url}" \
    --arg terminal "${cf_terminal_url}" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      issue: $issue,
      pr: null,
      branch: $branch,
      repo: $repo,
      origin: $origin,
      worktree: $worktree,
      backend: $backend,
      ai_tool: $ai,
      base_branch: $base,
      sandbox_id: $sandbox,
      preview_url: $preview,
      dev_url: $dev,
      terminal_url: $terminal,
      herdr_pane: "",
      herdr_agent: "",
      herdr_workspace: "",
      review_pane: "",
      review_agent: "",
      created_at: $created,
      finished_at: null
    }')
  _ghsb_write_session "$session_id" "$session_json"

  # ── Agent prompt ──
  local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
  local finish_cmd="ghsb finish ${session_id}"
  local ai_prompt="Implement GitHub issue #${issue_number}. First run ${issue_view_cmd} for details. If the issue body is empty or lacks context, ask me what to accomplish and any constraints, then update the issue via 'gh issue edit ${issue_number} -R ${issue_repo}' before coding.

Work in this worktree. Commit on branch ${branch_name} and push to origin regularly.

When implementation is complete:
1. Push the branch
2. Open a PR if one does not exist (gh pr create), linking issue #${issue_number}
3. Run: ${finish_cmd}
That finish step records a Playwright video for user-facing changes, runs pr-review, ranks files for manual review, and prints preview/dev links."

  if $no_agent; then
    echo "Session ready (no agent): $session_id"
    echo "  worktree: $worktree_path"
    echo "  next: cd $worktree_path && ghsb attach $session_id"
    return 0
  fi

  # Prefer Herdr; fall back to tmux / foreground like ghwt
  local launch_line="" pane_id="" agent_name="" workspace_id=""
  if command -v herdr >/dev/null 2>&1; then
    echo "Launching ${ai_tool} in Herdr..."
    launch_line=$(_ghsb_herdr_launch "ghsb-${issue_number}" "$worktree_path" "$ai_tool" "$ai_prompt") || launch_line=""
    if [[ -n "$launch_line" ]]; then
      pane_id=${launch_line%%|*}
      agent_name=${launch_line#*|}; agent_name=${agent_name%%|*}
      workspace_id=${launch_line##*|}
      _ghsb_session_set "$session_id" "herdr_pane" "$pane_id"
      _ghsb_session_set "$session_id" "herdr_agent" "$agent_name"
      _ghsb_session_set "$session_id" "herdr_workspace" "$workspace_id"
      echo "Herdr workspace: $workspace_id"
      echo "Herdr pane:      $pane_id"
      echo "Herdr agent:     $agent_name"
      echo "Attach: ghsb attach $session_id"
      echo "   or:  herdr agent attach $agent_name"
    fi
  fi

  if [[ -z "$pane_id" ]]; then
    echo "Herdr launch unavailable; falling back to tmux/foreground."
    local flags ai_cmd
    flags=$(_ghsb_ai_flags "$ai_tool")
    ai_cmd="${ai_tool} ${flags} $(printf '%q' "$ai_prompt")"
    if [[ -n "${TMUX:-}" ]]; then
      tmux new-window -n "${ai_tool}-${issue_number}" -c "$worktree_path" "$ai_cmd"
    else
      (cd "$worktree_path" && eval "$ai_cmd")
    fi
  fi

  echo ""
  echo "Session: $session_id"
  echo "When done: ghsb finish $session_id"
}

# ── Cloudflare API client ──
_ghsb_cf_headers() {
  local -a h=(-H "Content-Type: application/json")
  if [[ -n "${GHSB_API_TOKEN:-}" ]]; then
    h+=(-H "Authorization: Bearer ${GHSB_API_TOKEN}")
  fi
  printf '%s\0' "${h[@]}"
}

_ghsb_cf_create_session() {
  local id="$1" repo="$2" branch="$3" issue="$4"
  local body
  body=$(jq -n \
    --arg id "$id" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --argjson issue "$issue" \
    '{id: $id, repo: $repo, branch: $branch, issue: $issue}')
  curl -sS -X POST "${GHSB_API_URL%/}/sessions" \
    -H "Content-Type: application/json" \
    ${GHSB_API_TOKEN:+-H "Authorization: Bearer ${GHSB_API_TOKEN}"} \
    -d "$body"
}

_ghsb_cf_destroy_session() {
  local id="$1"
  curl -sS -X DELETE "${GHSB_API_URL%/}/sessions/${id}" \
    ${GHSB_API_TOKEN:+-H "Authorization: Bearer ${GHSB_API_TOKEN}"}
}

_ghsb_cf_get_session() {
  local id="$1"
  curl -sS "${GHSB_API_URL%/}/sessions/${id}" \
    ${GHSB_API_TOKEN:+-H "Authorization: Bearer ${GHSB_API_TOKEN}"}
}

# ── Subcommands ──
_ghsb_list() {
  _ghsb_init_dirs
  local f id issue branch backend
  printf "%-28s %6s %-24s %s\n" "SESSION" "ISSUE" "BRANCH" "BACKEND"
  local found=0
  for f in "$GHSB_SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    found=1
    id=$(jq -r '.id' "$f")
    issue=$(jq -r '.issue' "$f")
    branch=$(jq -r '.branch' "$f")
    backend=$(jq -r '.backend' "$f")
    printf "%-28s %6s %-24s %s\n" "$id" "$issue" "$branch" "$backend"
  done
  [[ $found -eq 0 ]] && echo "(no sessions yet)"
}

_ghsb_status() {
  local sid
  sid=$(_ghsb_resolve_session_id "${1:-}") || {
    echo "No session found. Run: ghsb list"
    return 1
  }
  local repo branch pr worktree
  repo=$(_ghsb_session_get "$sid" "repo")
  branch=$(_ghsb_session_get "$sid" "branch")
  pr=$(_ghsb_session_get "$sid" "pr")
  worktree=$(_ghsb_session_get "$sid" "worktree")
  [[ "$pr" == "null" ]] && pr=""
  _ghsb_print_open_first "$repo" "$branch" "$pr" "$worktree"
  echo ""
  jq . "$(_ghsb_session_path "$sid")"
}

_ghsb_attach() {
  local sid
  sid=$(_ghsb_resolve_session_id "${1:-}") || {
    echo "No session found."
    return 1
  }
  local pane agent worktree terminal repo branch pr
  pane=$(_ghsb_session_get "$sid" "herdr_pane")
  agent=$(_ghsb_session_get "$sid" "herdr_agent")
  worktree=$(_ghsb_session_get "$sid" "worktree")
  terminal=$(_ghsb_session_get "$sid" "terminal_url")
  repo=$(_ghsb_session_get "$sid" "repo")
  branch=$(_ghsb_session_get "$sid" "branch")
  pr=$(_ghsb_session_get "$sid" "pr")
  [[ "$pr" == "null" ]] && pr=""
  _ghsb_print_open_first "$repo" "$branch" "$pr" "$worktree"
  echo ""

  if [[ -n "$terminal" ]]; then
    echo "CF terminal: $terminal"
  fi

  if command -v herdr >/dev/null 2>&1; then
    # Prefer named agent (official attach target), then pane id
    if [[ -n "$agent" ]]; then
      echo "Attaching Herdr agent $agent..."
      if herdr agent attach "$agent" 2>/dev/null; then
        return 0
      fi
      herdr agent attach "$agent" --takeover 2>/dev/null && return 0
    fi
    if [[ -n "$pane" ]]; then
      echo "Attaching Herdr pane $pane..."
      if herdr agent attach "$pane" 2>/dev/null; then
        return 0
      fi
      herdr agent attach "$pane" --takeover 2>/dev/null && return 0
      herdr agent focus "$pane" 2>/dev/null && {
        echo "Focused pane $pane in Herdr UI (could not direct-attach)."
        return 0
      }
    fi
    echo "Could not attach. Try: herdr   then click the ghsb workspace."
    echo "  session: $sid  agent=${agent:-?}  pane=${pane:-?}"
    return 1
  fi

  if [[ -n "$worktree" && -d "$worktree" ]]; then
    echo "cd $worktree"
    cd "$worktree" || return 1
    return 0
  fi
  echo "Nothing to attach for $sid"
  return 1
}

_ghsb_links_cmd() {
  local sid
  sid=$(_ghsb_resolve_session_id "${1:-}") || {
    echo "No session found."
    return 1
  }
  local repo branch pr preview dev
  repo=$(_ghsb_session_get "$sid" "repo")
  branch=$(_ghsb_session_get "$sid" "branch")
  pr=$(_ghsb_session_get "$sid" "pr")
  preview=$(_ghsb_session_get "$sid" "preview_url")
  dev=$(_ghsb_session_get "$sid" "dev_url")
  [[ "$pr" == "null" ]] && pr=""
  if [[ -z "$preview" && -n "$pr" ]]; then
    preview=$(_ghsb_resolve_preview_url "$repo" "$pr" 2>/dev/null) || true
  fi
  local worktree
  worktree=$(_ghsb_session_get "$sid" "worktree")
  _ghsb_print_links "$repo" "$branch" "$pr" "$preview" "$dev" "$worktree"
}

_ghsb_rm() {
  local sid
  sid=$(_ghsb_resolve_session_id "${1:-}") || {
    echo "No session found."
    return 1
  }
  local backend sandbox
  backend=$(_ghsb_session_get "$sid" "backend")
  sandbox=$(_ghsb_session_get "$sid" "sandbox_id")
  if [[ "$backend" == "cloudflare" && -n "$sandbox" && -n "${GHSB_API_URL:-}" ]]; then
    echo "Destroying CF sandbox $sandbox..."
    _ghsb_cf_destroy_session "$sid" >/dev/null || true
  fi
  rm -f "$(_ghsb_session_path "$sid")"
  echo "Removed session metadata: $sid"
  echo "(Worktree left intact; use ghwtrm to remove it.)"
}

# ── Finish pipeline ──
_ghsb_finish() {
  local sid
  sid=$(_ghsb_resolve_session_id "${1:-}") || {
    echo "No session found. Pass session id or run from worktree."
    return 1
  }

  local worktree repo branch base_branch origin issue ai_tool
  worktree=$(_ghsb_session_get "$sid" "worktree")
  repo=$(_ghsb_session_get "$sid" "repo")
  origin=$(_ghsb_session_get "$sid" "origin")
  branch=$(_ghsb_session_get "$sid" "branch")
  base_branch=$(_ghsb_session_get "$sid" "base_branch")
  issue=$(_ghsb_session_get "$sid" "issue")
  ai_tool=$(_ghsb_session_get "$sid" "ai_tool")
  [[ -z "$ai_tool" ]] && ai_tool=$(_ghsb_pick_ai "$issue")
  base_branch="${base_branch:-main}"

  if [[ -z "$worktree" || ! -d "$worktree" ]]; then
    echo "Worktree missing for $sid: $worktree"
    return 1
  fi

  echo "==> Finish session $sid"
  _ghsb_print_open_first "$repo" "$branch" "" "$worktree"
  echo ""
  cd "$worktree" || return 1

  # Push
  echo "→ Pushing $branch..."
  git push -u origin "$branch" 2>&1 || {
    echo "Push failed; fix and re-run ghsb finish $sid"
    return 1
  }

  # Ensure PR
  local pr pr_url
  pr=$(gh pr view --json number -q .number 2>/dev/null) || pr=""
  if [[ -z "$pr" ]]; then
    echo "→ Creating PR..."
    local title
    title=$(gh issue view "$issue" -R "$repo" --json title -q .title 2>/dev/null || echo "$branch")
    pr_url=$(gh pr create -R "$repo" \
      --title "$title" \
      --body "Closes #${issue}

Implemented via ghsb session \`${sid}\`." \
      --base "$base_branch" \
      --head "$branch" 2>&1) || {
      # Maybe PR already exists on origin under different detection
      pr=$(gh pr list -R "$repo" --head "$branch" --json number -q '.[0].number' 2>/dev/null)
      if [[ -z "$pr" ]]; then
        echo "Failed to create PR: $pr_url"
        return 1
      fi
      pr_url="https://github.com/${repo}/pull/${pr}"
    }
    if [[ -z "$pr" ]]; then
      pr=$(echo "$pr_url" | grep -oE '[0-9]+$')
    fi
  else
    pr_url=$(gh pr view "$pr" -R "$repo" --json url -q .url)
  fi
  echo "  PR #$pr — $pr_url"
  # store pr as number in session (jq number)
  # NOTE: never name a local `path` — in zsh that shadows $PATH
  local spath tmp
  spath="$(_ghsb_session_path "$sid")"
  tmp=$(/usr/bin/mktemp)
  jq --argjson pr "$pr" '.pr = $pr' "$spath" > "$tmp" && mv "$tmp" "$spath"

  # Refresh CF session URLs if any
  local preview_url dev_url
  preview_url=$(_ghsb_session_get "$sid" "preview_url")
  dev_url=$(_ghsb_session_get "$sid" "dev_url")
  if [[ -n "${GHSB_API_URL:-}" ]]; then
    local cf_state
    cf_state=$(_ghsb_cf_get_session "$sid" 2>/dev/null) || true
    if [[ -n "$cf_state" ]]; then
      local p d
      p=$(echo "$cf_state" | jq -r '.previewUrl // empty')
      d=$(echo "$cf_state" | jq -r '.devUrl // empty')
      [[ -n "$p" ]] && preview_url="$p" && _ghsb_session_set "$sid" "preview_url" "$p"
      [[ -n "$d" ]] && dev_url="$d" && _ghsb_session_set "$sid" "dev_url" "$d"
    fi
  fi
  if [[ -z "$preview_url" ]]; then
    preview_url=$(_ghsb_resolve_preview_url "$repo" "$pr" 2>/dev/null) || preview_url=""
    [[ -n "$preview_url" ]] && _ghsb_session_set "$sid" "preview_url" "$preview_url"
  fi

  # Artifacts dir
  local art
  art="$GHSB_ARTIFACTS_DIR/${sid}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$art"

  # Rank files
  echo "→ Ranking files for manual review..."
  local base_ref="origin/${base_branch}"
  git fetch origin "$base_branch" 2>/dev/null || true
  _ghsb_rank_files "$base_ref" "$art/files-to-review.txt"
  echo "  Wrote $art/files-to-review.txt"
  echo ""
  echo "  Most relevant files to review manually (in order):"
  head -20 "$art/files-to-review.txt" | sed 's/^/    /'
  echo ""

  # Playwright video for user-facing changes
  local facing=false
  if _ghsb_diff_has_facing_changes "$base_ref"; then
    facing=true
  fi

  local video_path=""
  if $facing; then
    local record_url="${preview_url:-$dev_url}"
    if [[ -z "$record_url" ]]; then
      echo "→ User-facing changes detected, but no preview/dev URL yet."
      echo "  Start a preview (or set session preview_url), then re-run:"
      echo "    ghsb finish $sid"
      local scripts_hint
      scripts_hint=$(_ghsb_scripts_dir 2>/dev/null || echo "~/code/dotfiles/scripts")
      echo "  Or record manually:"
      echo "    node ${scripts_hint}/ghsb-record-preview.mjs --url <url> --out $art"
    else
      echo "→ User-facing changes: recording Playwright video of $record_url ..."
      local script scripts_dir
      scripts_dir=$(_ghsb_scripts_dir 2>/dev/null) || scripts_dir=""
      script="${scripts_dir}/ghsb-record-preview.mjs"
      if [[ -f "$script" ]]; then
        if video_path=$(node "$script" --url "$record_url" --out "$art" --name "pr-${pr}-walkthrough" 2>"$art/playwright.log"); then
          video_path=$(echo "$video_path" | tail -1)
          echo "  Video: $video_path"
        else
          echo "  Playwright recording failed (see $art/playwright.log). Continuing."
          tail -20 "$art/playwright.log"
        fi
      else
        echo "  Script missing: ghsb-record-preview.mjs (looked in ${scripts_dir:-?})"
      fi
    fi
  else
    echo "→ No user-facing file changes detected; skipping Playwright video."
  fi

  # Write finish summary
  {
    echo "# ghsb finish — $sid"
    echo ""
    echo "- Issue: #$issue"
    echo "- PR: #$pr — $pr_url"
    echo "- Branch: $branch"
    echo "- Facing UI changes: $facing"
    [[ -n "$video_path" ]] && echo "- Video: $video_path"
    [[ -n "$preview_url" ]] && echo "- Preview: $preview_url"
    [[ -n "$dev_url" ]] && echo "- Dev env: $dev_url"
    echo ""
    echo "## Files to review (ranked)"
    echo ""
    cat "$art/files-to-review.txt"
  } > "$art/SUMMARY.md"

  _ghsb_session_set "$sid" "finished_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _ghsb_session_set "$sid" "artifacts" "$art"

  # Launch pr-review in Herdr
  echo "→ Launching pr-review for #$pr ..."
  local review_prompt
  if [[ "$ai_tool" == "grok" ]]; then
    review_prompt="/review-pr ${pr}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files. If a Playwright video was recorded, note it in the review summary."
  else
    review_prompt="/pr-review-toolkit:review-pr ${pr}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files. If a Playwright video was recorded, note it in the review summary."
  fi

  local review_line="" review_pane="" review_agent=""
  if command -v herdr >/dev/null 2>&1; then
    review_line=$(_ghsb_herdr_launch "ghsb-review-${pr}" "$worktree" "$ai_tool" "$review_prompt") || true
    if [[ -n "$review_line" ]]; then
      review_pane=${review_line%%|*}
      review_agent=${review_line#*|}; review_agent=${review_agent%%|*}
      _ghsb_session_set "$sid" "review_pane" "$review_pane"
      _ghsb_session_set "$sid" "review_agent" "$review_agent"
      echo "  Review agent: $review_agent (pane $review_pane)"
    fi
  fi
  if [[ -z "$review_pane" ]]; then
    local flags
    flags=$(_ghsb_ai_flags "$ai_tool")
    if [[ -n "${TMUX:-}" ]]; then
      tmux new-window -n "review-${pr}" -c "$worktree" \
        "${ai_tool} ${flags} $(printf '%q' "$review_prompt")"
    else
      echo "Run review manually:"
      echo "  cd $worktree && $ai_tool $flags $(printf '%q' "$review_prompt")"
    fi
  fi

  _ghsb_print_links "$repo" "$branch" "$pr" "$preview_url" "$dev_url" "$worktree"
  echo ""
  echo "Artifacts: $art"
  echo "Summary:   $art/SUMMARY.md"
  if [[ -n "$video_path" ]]; then
    echo "Video:     $video_path"
  fi
  echo ""
  echo "Done. Review agent is running; attach with: ghsb attach $sid"
}
