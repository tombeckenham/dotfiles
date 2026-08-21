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
                     ranked files, preview/dev links; review stays in
                     this same grok/claude session
  ghsb review <pr>   Review an existing PR (same space/agent if inside Herdr)
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
  3. Rank files for manual review
  4. Prompt the existing grok/claude session to review (no new agent)
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

  _ghsb_checkout_issue ghsb "$base_branch" "$issue_number" "$branch_name" "$target_fork" "$@" || return 1
  issue_number="${GHSB_CHECKOUT[issue]}"
  branch_name="${GHSB_CHECKOUT[branch]}"
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local session_id="${GHSB_CHECKOUT[session_id]}"
  local issue_repo="${GHSB_CHECKOUT[repo]}"
  local origin_repo="${GHSB_CHECKOUT[origin]}"
  local default_branch="${GHSB_CHECKOUT[default_branch]}"

  # Open links with final branch + worktree (vscode.dev first).
  _ghsb_print_open_first "$issue_repo" "$branch_name" "" "$worktree_path"
  echo ""

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "$issue_number")

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
  local ai_prompt
  ai_prompt=$(_ghsb_implement_prompt "$issue_number" "$issue_repo" "$branch_name" "$session_id" "$ai_tool")

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

  # Review stays in the same grok/claude session — do not launch another agent.
  local review_skill="/pr-review-toolkit:review-pr"
  [[ "$ai_tool" == "grok" ]] && review_skill="/review-pr"
  local review_prompt
  review_prompt="${review_skill} ${pr}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files. If a Playwright video was recorded, note it in the review summary."

  local review_target="" session_agent session_pane
  session_agent=$(_ghsb_session_get "$sid" "herdr_agent")
  session_pane=$(_ghsb_session_get "$sid" "herdr_pane")
  if [[ -n "$session_agent" ]] && herdr agent get "$session_agent" >/dev/null 2>&1; then
    review_target="$session_agent"
  elif [[ -n "$session_pane" ]]; then
    review_target="$session_pane"
  else
    local here_agent=""
    here_agent=$(_ghsb_pane_agent "${HERDR_PANE_ID:-}") || here_agent=""
    [[ -n "$here_agent" ]] && review_target="$here_agent"
  fi

  if [[ -n "$review_target" ]]; then
    echo "→ Sending review to existing agent ($review_target) — no new space."
    _ghsb_herdr_send_prompt "$review_target" "$review_prompt" || true
    _ghsb_session_set "$sid" "review_pane" "${session_pane:-${HERDR_PANE_ID:-}}"
    _ghsb_session_set "$sid" "review_agent" "${session_agent:-$review_target}"
  else
    echo "→ Review in this same agent (not launching a new one):"
    echo "    ${review_skill} ${pr}"
    echo "    read ${art}/SUMMARY.md and ${art}/files-to-review.txt"
  fi

  _ghsb_print_links "$repo" "$branch" "$pr" "$preview_url" "$dev_url" "$worktree"
  echo ""
  echo "Artifacts: $art"
  echo "Summary:   $art/SUMMARY.md"
  if [[ -n "$video_path" ]]; then
    echo "Video:     $video_path"
  fi
  echo ""
  echo "Done. Review stays in this session. Attach: ghsb attach $sid"
}
