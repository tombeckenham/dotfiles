# Shared helpers for ghsb (Architecture A: Herdr cockpit + optional CF sandbox)

GHSB_HOME="${GHSB_HOME:-$HOME/.ghsb}"
GHSB_SESSIONS_DIR="$GHSB_HOME/sessions"
GHSB_ARTIFACTS_DIR="$GHSB_HOME/artifacts"

_ghsb_init_dirs() {
  mkdir -p "$GHSB_SESSIONS_DIR" "$GHSB_ARTIFACTS_DIR"
}

# Pick implement/review agent: grok / kimi / claude (issue mod 3)
_ghsb_pick_ai() {
  local selector="${1:-}"
  [[ -z "$selector" || "$selector" == "0" ]] && selector=$(date +%s)
  case $(( selector % 3 )) in
    0) echo "grok" ;;
    1) echo "kimi" ;;
    *) echo "claude" ;;
  esac
}

# Map AI CLI → herdr --kind
_ghsb_herdr_kind() {
  case "$1" in
    grok) echo "grok" ;;
    kimi) echo "kimi" ;;
    claude) echo "claude" ;;
    *) echo "claude" ;;
  esac
}

# CLI flags for agent runs (permission auto, not always-approve/yolo).
# Grok/Claude: --permission-mode auto. Kimi: --auto.
# Note: a CLI --permission-mode overrides [ui] permission_mode in config.toml.
_ghsb_ai_flags() {
  case "$1" in
    kimi) echo "--auto" ;;
    grok|claude) echo "--permission-mode auto" ;;
    *) echo "--permission-mode auto" ;;
  esac
}

_ghsb_session_path() {
  echo "$GHSB_SESSIONS_DIR/${1}.json"
}

_ghsb_write_session() {
  local id="$1"
  local json="$2"
  _ghsb_init_dirs
  printf '%s\n' "$json" > "$(_ghsb_session_path "$id")"
}

_ghsb_read_session() {
  local id="$1"
  local spath
  spath="$(_ghsb_session_path "$id")"
  if [[ ! -f "$spath" ]]; then
    return 1
  fi
  cat "$spath"
}

_ghsb_session_get() {
  local id="$1" key="$2"
  local spath
  spath="$(_ghsb_session_path "$id")"
  [[ -f "$spath" ]] || return 1
  jq -r --arg k "$key" '.[$k] // empty' "$spath"
}

_ghsb_session_set() {
  local id="$1" key="$2" value="$3"
  # NOTE: never name a local `path` — in zsh that shadows $PATH and breaks mktemp/etc.
  local spath tmp
  spath="$(_ghsb_session_path "$id")"
  [[ -f "$spath" ]] || return 1
  tmp=$(/usr/bin/mktemp)
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$spath" > "$tmp" && mv "$tmp" "$spath"
}

# Resolve session id from arg, cwd worktree name, or newest session
_ghsb_resolve_session_id() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    if [[ -f "$(_ghsb_session_path "$arg")" ]]; then
      echo "$arg"
      return 0
    fi
    # Allow bare issue number: match *-N.json
    local match
    match=$(find "$GHSB_SESSIONS_DIR" -maxdepth 1 -name "*-${arg}.json" 2>/dev/null | head -1)
    if [[ -n "$match" ]]; then
      basename "$match" .json
      return 0
    fi
  fi

  # Infer from worktree path ~/.claude/worktrees/{repo}-{issue}
  local cwd="$PWD"
  if [[ "$cwd" == *'/.claude/worktrees/'* ]]; then
    local leaf
    leaf=$(basename "$cwd")
    if [[ -f "$(_ghsb_session_path "$leaf")" ]]; then
      echo "$leaf"
      return 0
    fi
  fi

  # Newest session
  local newest
  newest=$(ls -t "$GHSB_SESSIONS_DIR"/*.json 2>/dev/null | head -1)
  if [[ -n "$newest" ]]; then
    basename "$newest" .json
    return 0
  fi
  return 1
}

_ghsb_ensure_herdr() {
  if ! command -v herdr >/dev/null 2>&1; then
    echo "Error: herdr not found. Install: curl -fsSL https://herdr.dev/install.sh | sh"
    return 1
  fi
  # Server may already be up; status is non-fatal if client-only
  herdr status >/dev/null 2>&1 || true
  return 0
}

# Wait until a pane's foreground process is an interactive shell.
# Official rule: agent start requires "available shell" (shell owns foreground).
# See https://herdr.dev/docs/agent-automation/
_ghsb_herdr_wait_shell() {
  local pane_id="$1"
  local timeout_ms="${2:-20000}"
  local elapsed=0 info fg_name fg_argv0
  while (( elapsed < timeout_ms )); do
    info=$(herdr pane process-info --pane "$pane_id" 2>/dev/null) || true
    fg_name=$(printf '%s\n' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null)
    fg_argv0=$(printf '%s\n' "$info" | jq -r '.result.process_info.foreground_processes[0].argv0 // empty' 2>/dev/null)
    # Idle shell: zsh/bash/fish (login shells often report name=zsh, argv0=-zsh)
    if [[ "$fg_name" == zsh || "$fg_name" == bash || "$fg_name" == fish || "$fg_name" == sh || \
          "$fg_argv0" == zsh || "$fg_argv0" == bash || "$fg_argv0" == -zsh || "$fg_argv0" == -bash ]]; then
      return 0
    fi
    # Also accept empty foreground while shell is still coming up — keep waiting
    sleep 0.25
    elapsed=$((elapsed + 250))
  done
  echo "Timed out waiting for idle shell on $pane_id (last fg: name=$fg_name argv0=$fg_argv0)" >&2
  return 1
}

# Pre-accept Claude workspace trust for a worktree (new git worktrees always
# trip "Is this a project you trust?"). Without this, herdr agent start returns
# idle/ready while the trust dialog still owns the UI, and agent prompt is
# swallowed (exit 0, no turn starts).
_ghsb_claude_trust_worktree() {
  local worktree="$1"
  local conf="$HOME/.claude.json"
  [[ -n "$worktree" && -d "$worktree" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$conf" ]] || printf '%s\n' '{"projects":{}}' > "$conf"

  local abs
  abs=$(cd "$worktree" 2>/dev/null && pwd -P) || abs="$worktree"

  local tmp
  tmp=$(/usr/bin/mktemp)
  if jq --arg p "$abs" '
      .projects = (.projects // {})
      | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
    ' "$conf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$conf"
    echo "Claude: pre-trusted worktree $abs" >&2
  else
    rm -f "$tmp"
  fi
}

# True if pane/agent UI is still on Claude's workspace-trust dialog.
_ghsb_herdr_is_trust_dialog() {
  local target="$1"
  local text
  text=$(herdr agent read "$target" --source visible --lines 40 2>/dev/null) \
    || text=$(herdr pane read "$target" --source visible --lines 40 2>/dev/null) \
    || return 1
  printf '%s\n' "$text" | grep -qiE 'I trust this folder|Accessing workspace|Yes, I trust'
}

# Dismiss Claude trust dialog if present (option 1 is pre-selected → Enter).
_ghsb_herdr_accept_trust_dialog() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    if ! _ghsb_herdr_is_trust_dialog "$target"; then
      return 0
    fi
    echo "Claude: trust dialog detected — accepting (attempt $attempt)…" >&2
    herdr agent send-keys "$target" enter 2>/dev/null \
      || herdr pane send-keys "$target" enter 2>/dev/null \
      || true
    sleep 0.6
  done
  if _ghsb_herdr_is_trust_dialog "$target"; then
    echo "Warning: Claude trust dialog still open; prompt may not land." >&2
    return 1
  fi
  return 0
}

# Wait until agent is interactive and not mid-startup (idle/done/blocked).
_ghsb_herdr_wait_agent_ready() {
  local target="$1"
  local timeout_ms="${2:-20000}"
  local elapsed=0 st ready
  while (( elapsed < timeout_ms )); do
    st=$(herdr agent get "$target" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    ready=$(herdr agent get "$target" 2>/dev/null | jq -r '.result.agent.interactive_ready // false')
    if [[ "$ready" == "true" && "$st" != "working" && -n "$st" ]]; then
      return 0
    fi
    if [[ -n "$st" ]]; then
      # Agent exists; keep waiting for interactive_ready
      :
    fi
    sleep 0.25
    elapsed=$((elapsed + 250))
  done
  return 1
}

# Submit prompt and confirm the agent leaves idle (Herdr returns ok even when
# a startup dialog ate the keystrokes). Retries a few times.
_ghsb_herdr_send_prompt() {
  local target="$1"
  local prompt="$2"
  local attempt=1 prompt_out st
  while (( attempt <= 3 )); do
    _ghsb_herdr_accept_trust_dialog "$target" || true
    _ghsb_herdr_wait_agent_ready "$target" 10000 || true

    prompt_out=$(herdr agent prompt "$target" "$prompt" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "herdr agent prompt failed (attempt $attempt/3): $prompt_out" >&2
      attempt=$((attempt + 1))
      sleep 0.5
      continue
    fi

    # Confirm a turn started (status → working) within ~5s.
    local elapsed=0
    while (( elapsed < 5000 )); do
      st=$(herdr agent get "$target" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      if [[ "$st" == "working" || "$st" == "blocked" ]]; then
        echo "Herdr: prompt accepted (agent=$st)" >&2
        return 0
      fi
      # Trust dialog can reappear / still be up after a swallowed prompt
      if _ghsb_herdr_is_trust_dialog "$target"; then
        break
      fi
      sleep 0.25
      elapsed=$((elapsed + 250))
    done

    echo "Herdr: prompt did not start a turn (status=${st:-?}); retrying…" >&2
    attempt=$((attempt + 1))
    sleep 0.4
  done
  echo "Warning: agent prompt may not have started; attach and paste manually." >&2
  return 1
}

# Canonical Herdr recipe (docs + live-verified on herdr 0.8.0):
#   1. workspace create --cwd … --label … --no-focus
#   2. pane_id = .result.root_pane.pane_id
#   3. wait until process-info shows shell in foreground
#   4. agent start <name> --kind <kind> --pane <pane_id> -- <agent-flags…>
#   5. dismiss Claude trust dialog if needed
#   6. agent prompt <name> "<task>"   # long prompt here, NOT on argv
# Fallback if agent start keeps failing:
#   pane run <pane> "<binary> <flags>" → agent rename → agent prompt
#
# Prints on stdout (one line): pane_id|agent_name|workspace_id
# Diagnostics → stderr.
# Usage: _ghsb_herdr_launch <label> <worktree> <ai_tool> <prompt>
_ghsb_herdr_launch() {
  local label="$1" worktree="$2" ai_tool="$3" prompt="$4"
  _ghsb_ensure_herdr || return 1

  # New Claude worktrees always hit the trust dialog otherwise.
  if [[ "$ai_tool" == "claude" ]]; then
    _ghsb_claude_trust_worktree "$worktree"
  fi

  local created pane_id workspace_id kind
  # Do not invent IDs — capture JSON from create (herdr docs).
  created=$(herdr workspace create --cwd "$worktree" --label "$label" --no-focus 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "herdr workspace create failed: $created" >&2
    return 1
  fi

  pane_id=$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  workspace_id=$(printf '%s\n' "$created" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  if [[ -z "$pane_id" ]]; then
    echo "Could not parse .result.root_pane.pane_id from herdr workspace create:" >&2
    echo "$created" >&2
    return 1
  fi

  kind="$(_ghsb_herdr_kind "$ai_tool")"
  # Names: [a-z][a-z0-9_-]{0,31}, unique among live agents
  local agent_name
  agent_name=$(echo "$label" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-28)
  [[ -z "$agent_name" || "$agent_name" != [a-z]* ]] && agent_name="ghsbagent"
  # Avoid collisions with a still-live prior agent of the same name
  if herdr agent get "$agent_name" >/dev/null 2>&1; then
    agent_name="${agent_name}-$(date +%s | tail -c 5)"
    agent_name=$(echo "$agent_name" | cut -c1-32)
  fi

  echo "Herdr: workspace=$workspace_id pane=$pane_id → wait for shell…" >&2
  _ghsb_herdr_wait_shell "$pane_id" 20000 || {
    echo "Shell never became available; check: herdr pane process-info --pane $pane_id" >&2
    # Continue to try agent start anyway
  }

  # Flags only after -- ; long task text goes through agent prompt (official recipe).
  local -a agent_args=()
  case "$ai_tool" in
    kimi) agent_args=(--auto) ;;
    grok|claude) agent_args=(--permission-mode auto) ;;
  esac

  local start_out attempt=1 started=0 start_ec
  while (( attempt <= 4 )); do
    if (( ${#agent_args[@]} > 0 )); then
      start_out=$(herdr agent start "$agent_name" --kind "$kind" --pane "$pane_id" --timeout 90000 -- "${agent_args[@]}" 2>&1)
    else
      start_out=$(herdr agent start "$agent_name" --kind "$kind" --pane "$pane_id" --timeout 90000 2>&1)
    fi
    start_ec=$?
    if (( start_ec == 0 )); then
      started=1
      break
    fi
    if echo "$start_out" | grep -q 'agent_pane_busy\|not an available shell'; then
      echo "herdr agent_pane_busy (attempt $attempt/4); waiting for shell…" >&2
      herdr pane process-info --pane "$pane_id" 2>/dev/null \
        | jq -c '.result.process_info.foreground_processes // empty' >&2 || true
      _ghsb_herdr_wait_shell "$pane_id" 5000 || true
      sleep 0.5
      attempt=$((attempt + 1))
      continue
    fi
    echo "herdr agent start failed: $start_out" >&2
    break
  done

  if (( started )); then
    echo "Herdr: agent start ok ($agent_name / $kind); clearing startup dialogs…" >&2
    _ghsb_herdr_accept_trust_dialog "$agent_name" || _ghsb_herdr_accept_trust_dialog "$pane_id" || true
    _ghsb_herdr_wait_agent_ready "$agent_name" 15000 || true
    echo "Herdr: sending prompt…" >&2
    _ghsb_herdr_send_prompt "$agent_name" "$prompt" \
      || _ghsb_herdr_send_prompt "$pane_id" "$prompt" \
      || true
  else
    echo "Falling back: pane run $ai_tool, then agent prompt (still Herdr-detected)…" >&2
    local flags q_bin
    flags="$(_ghsb_ai_flags "$ai_tool")"
    q_bin=$(command -v "$ai_tool" 2>/dev/null || echo "$ai_tool")
    # Start agent only (no task on argv) so agent prompt can drive it properly.
    # workspace create already set cwd; still cd for safety.
    herdr pane run "$pane_id" "cd $(printf %q "$worktree") && $(printf %q "$q_bin") $flags" >/dev/null 2>&1 || return 1
    # Wait until Herdr recognizes the agent in this pane
    local wait_elapsed=0
    while (( wait_elapsed < 60000 )); do
      if herdr agent get "$pane_id" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
      wait_elapsed=$((wait_elapsed + 500))
    done
    herdr agent rename "$pane_id" "$agent_name" >/dev/null 2>&1 || true
    if [[ "$ai_tool" == "claude" ]]; then
      _ghsb_herdr_accept_trust_dialog "$agent_name" || _ghsb_herdr_accept_trust_dialog "$pane_id" || true
    fi
    _ghsb_herdr_send_prompt "$agent_name" "$prompt" \
      || _ghsb_herdr_send_prompt "$pane_id" "$prompt" \
      || true
  fi

  # pane|name|workspace — parse with cut/IFS in callers
  printf '%s|%s|%s\n' "$pane_id" "$agent_name" "$workspace_id"
}

# Resolve path to dotfiles scripts/ (works when functions/ is symlinked)
_ghsb_scripts_dir() {
  local real_fn script_dir
  if [[ -L "$HOME/.zsh_functions" ]]; then
    real_fn=$(readlink "$HOME/.zsh_functions")
    # readlink may be relative
    [[ "$real_fn" != /* ]] && real_fn="$HOME/$real_fn"
    script_dir="$(cd "$(dirname "$real_fn")/scripts" 2>/dev/null && pwd)"
    if [[ -n "$script_dir" && -d "$script_dir" ]]; then
      echo "$script_dir"
      return 0
    fi
  fi
  for candidate in \
    "$HOME/code/dotfiles/scripts" \
    "$HOME/dotfiles/scripts" \
    "$(pwd)/scripts"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Detect fork + issue repo (same heuristic as ghwt)
_ghsb_detect_repo() {
  local fork_repo upstream_repo
  fork_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')
  upstream_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
  local is_fork=false
  if [[ -n "$fork_repo" && -n "$upstream_repo" && "$fork_repo" != "$upstream_repo" ]]; then
    is_fork=true
  fi
  # Prints: is_fork\tfork_repo\tupstream_repo
  printf '%s\t%s\t%s\n' "$is_fork" "$fork_repo" "$upstream_repo"
}

# OSC-8 hyperlink when stdout is a TTY (Ghostty/iTerm/etc). Herdr Ctrl-click also
# opens plain https:// and some custom schemes; local cursor:// works via `open`.
_ghsb_hyperlink() {
  local url="$1" text="${2:-$1}"
  if [[ -t 1 && -n "$url" ]]; then
    printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$text"
  else
    printf '%s\n' "$text"
  fi
}

# vscode.dev URL for a repo branch or PR (web editor — no local install needed).
_ghsb_vscode_web_url() {
  local repo="$1" branch="${2:-}" pr="${3:-}"
  [[ -z "$repo" ]] && return 1
  if [[ -n "$pr" && "$pr" != "null" ]]; then
    echo "https://vscode.dev/github/${repo}/pull/${pr}"
  elif [[ -n "$branch" ]]; then
    echo "https://vscode.dev/github/${repo}/tree/${branch}"
  else
    echo "https://vscode.dev/github/${repo}"
  fi
}

# Local editor URI schemes (registered by Cursor / VS Code on macOS).
# Format: cursor://file/ABS_PATH  (single slash after "file" + absolute path)
_ghsb_local_editor_uri() {
  local scheme="$1" path="$2"
  [[ -n "$path" ]] || return 1
  local abs
  abs=$(cd "$path" 2>/dev/null && pwd -P) || abs="$path"
  [[ "$abs" == /* ]] || return 1
  echo "${scheme}://file${abs}"
}

# Print open links FIRST (vscode.dev, then local Cursor/VS Code).
# Usage: _ghsb_print_open_first <repo> [branch] [pr] [worktree]
_ghsb_print_open_first() {
  local repo="$1" branch="${2:-}" pr="${3:-}" worktree="${4:-}"
  local web cursor_uri vscode_uri

  web=$(_ghsb_vscode_web_url "$repo" "$branch" "$pr" 2>/dev/null) || web=""
  if [[ -n "$web" ]]; then
    printf 'vscode.dev:  '
    _ghsb_hyperlink "$web" "$web"
  fi

  if [[ -n "$worktree" && -e "$worktree" ]]; then
    cursor_uri=$(_ghsb_local_editor_uri "cursor" "$worktree")
    vscode_uri=$(_ghsb_local_editor_uri "vscode" "$worktree")
    if [[ -n "$cursor_uri" ]]; then
      printf 'Cursor:      '
      _ghsb_hyperlink "$cursor_uri" "$cursor_uri"
      echo "  open:      open $(printf %q "$cursor_uri")"
      if command -v cursor >/dev/null 2>&1; then
        echo "  or:        cursor $(printf %q "$worktree")"
      fi
    fi
    if [[ -n "$vscode_uri" ]]; then
      printf 'VS Code:     '
      _ghsb_hyperlink "$vscode_uri" "$vscode_uri"
    fi
  fi
}

# Build github.dev + PR + optional deployment preview links.
# vscode.dev / local editor always lead (same as _ghsb_print_open_first).
_ghsb_print_links() {
  local repo="$1" branch="$2" pr="${3:-}" preview_url="${4:-}" dev_url="${5:-}" worktree="${6:-}"

  echo ""
  echo "═══════════════════════════════════════"
  echo "  Open"
  echo "═══════════════════════════════════════"
  _ghsb_print_open_first "$repo" "$branch" "$pr" "$worktree"
  echo "═══════════════════════════════════════"
  echo "  Review links"
  echo "═══════════════════════════════════════"
  if [[ -n "$pr" && "$pr" != "null" ]]; then
    echo "  PR:           https://github.com/${repo}/pull/${pr}"
    echo "  github.dev:   https://github.dev/${repo}/pull/${pr}"
  elif [[ -n "$branch" ]]; then
    echo "  github.dev:   https://github.dev/${repo}/tree/${branch}"
  fi
  if [[ -n "$dev_url" ]]; then
    echo "  Dev env:      $dev_url"
  fi
  if [[ -n "$preview_url" ]]; then
    echo "  PR preview:   $preview_url"
  fi
  echo "═══════════════════════════════════════"
}

# Resolve Vercel/GitHub deployment preview URL for a PR if present
_ghsb_resolve_preview_url() {
  local repo="$1" pr="$2"
  [[ -z "$pr" ]] && return 1

  # Try status checks for a vercel/preview URL
  local url
  url=$(gh pr view "$pr" -R "$repo" --json statusCheckRollup,url \
    -q '[.statusCheckRollup[]? | select(.targetUrl != null) | .targetUrl] | map(select(test("vercel|preview|pages\\.dev|workers\\.dev|netlify|cloudflare"; "i"))) | .[0] // empty' 2>/dev/null)
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi

  # Comments sometimes contain preview URLs (Vercel bot)
  url=$(gh api "repos/${repo}/issues/${pr}/comments" --jq \
    '[.[].body | capture("https://[a-zA-Z0-9._/-]+\\.(vercel\\.app|netlify\\.app|pages\\.dev)[^\\s\\)]*").string // empty] | map(select(length>0)) | .[0] // empty' 2>/dev/null)
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi
  return 1
}

# Paths that usually mean user-facing UI changes
_ghsb_facing_globs() {
  cat <<'EOF'
\.(tsx|jsx|vue|svelte|css|scss|sass|less|html)$
(^|/)(app|pages|src|web|frontend|ui|components|views|screens)/
(^|/)(public|static|assets)/
EOF
}

_ghsb_diff_has_facing_changes() {
  local base_ref="$1"
  local files
  files=$(git diff --name-only "${base_ref}...HEAD" 2>/dev/null)
  [[ -z "$files" ]] && return 1
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if echo "$f" | grep -qE '\.(tsx|jsx|vue|svelte|css|scss|sass|less|html)$'; then
      return 0
    fi
    if echo "$f" | grep -qE '(^|/)(app|pages|components|views|screens|ui)/'; then
      return 0
    fi
  done <<< "$files"
  return 1
}

# Rank changed files for manual review (churn + facing weight)
_ghsb_rank_files() {
  local base_ref="$1"
  local out="${2:-/dev/stdout}"
  # numstat: added deleted path
  git diff --numstat "${base_ref}...HEAD" 2>/dev/null | awk '
    {
      add=$1; del=$2; path=$3
      if (add == "-") add=0
      if (del == "-") del=0
      churn = add + del
      weight = 1.0
      if (path ~ /\.(tsx|jsx|vue|svelte)$/) weight = 3.0
      else if (path ~ /\.(ts|js|mjs|cjs)$/) weight = 1.5
      else if (path ~ /\.(css|scss|sass|less|html)$/) weight = 2.5
      else if (path ~ /(^|\/)(test|tests|__tests__|spec|e2e)\//) weight = 0.5
      else if (path ~ /\.(md|json|yml|yaml|lock)$/) weight = 0.3
      if (path ~ /(^|\/)(app|pages|components|views|screens|ui)\//) weight *= 1.5
      score = churn * weight
      printf "%010.1f\t%s\t+%s/-%s\n", score, path, add, del
    }
  ' | sort -rn | awk -F'\t' '{ printf "%2d. %s  (%s)\n", NR, $2, $3 }' > "$out"
}
