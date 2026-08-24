# Shared helpers for ghsb (Architecture A: Herdr cockpit + optional CF sandbox)

GHSB_HOME="${GHSB_HOME:-$HOME/.ghsb}"
GHSB_SESSIONS_DIR="$GHSB_HOME/sessions"
GHSB_ARTIFACTS_DIR="$GHSB_HOME/artifacts"

_ghsb_init_dirs() {
  mkdir -p "$GHSB_SESSIONS_DIR" "$GHSB_ARTIFACTS_DIR"
}

# Pick implement/review agent: grok / claude (issue mod 2 → 50:50)
_ghsb_pick_ai() {
  local selector="${1:-}"
  [[ -z "$selector" || "$selector" == "0" ]] && selector=$(date +%s)
  case $(( selector % 2 )) in
    0) echo "grok" ;;
    *) echo "claude" ;;
  esac
}

# Map AI CLI → herdr --kind
_ghsb_herdr_kind() {
  case "$1" in
    grok) echo "grok" ;;
    claude) echo "claude" ;;
    *) echo "claude" ;;
  esac
}

# CLI flags for agent runs (permission auto, not always-approve/yolo).
# Grok/Claude: --permission-mode auto.
# Note: a CLI --permission-mode overrides [ui] permission_mode in config.toml.
_ghsb_ai_flags() {
  case "$1" in
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

  # Infer from worktree path (legacy ~/.claude/worktrees/{repo}-{issue}
  # or Herdr ~/.herdr/worktrees/{repo}/{branch-slug}).
  local cwd="$PWD"
  if [[ "$cwd" == *'/.claude/worktrees/'* ]]; then
    local leaf
    leaf=$(basename "$cwd")
    if [[ -f "$(_ghsb_session_path "$leaf")" ]]; then
      echo "$leaf"
      return 0
    fi
  fi
  if [[ "$cwd" == "$HOME/.herdr/worktrees/"* ]]; then
    local repo leaf sid
    repo=$(basename "$(dirname "$cwd")")
    leaf=$(basename "$cwd")
    if [[ "$leaf" =~ ^([0-9]+) ]]; then
      sid="${repo}-${match[1]}"
      if [[ -f "$(_ghsb_session_path "$sid")" ]]; then
        echo "$sid"
        return 0
      fi
    fi
  fi
  if [[ -d "$GHSB_SESSIONS_DIR" ]]; then
    local sess
    for sess in "$GHSB_SESSIONS_DIR"/*.json(N); do
      local sess_wt
      sess_wt=$(jq -r '.worktree // empty' "$sess" 2>/dev/null) || continue
      if [[ -n "$sess_wt" && "$cwd" == "$sess_wt"* ]]; then
        basename "$sess" .json
        return 0
      fi
    done
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
  if ! herdr workspace list >/dev/null 2>&1; then
    echo "Error: Herdr server is not running. Start it with: herdr"
    return 1
  fi
  return 0
}

_ghsb_repo_root() {
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

_ghsb_herdr_branch_slug() {
  echo "$1" | sed 's/[\/<>:"|?*]/-/g'
}

# Herdr sidebar label for an issue worktree. Starts with the issue number so
# truncated names stay unique (1227-csrf-… vs openstory-12…).
_ghsb_herdr_issue_label() {
  local issue="$1" branch="$2"
  local slug
  slug=$(_ghsb_herdr_branch_slug "$branch")
  if [[ "$slug" == "${issue}-"* ]]; then
    printf '%s\n' "$slug"
  else
    printf '%s\n' "$issue"
  fi
}

_ghsb_herdr_worktrees_root() {
  echo "${HERDR_WORKTREES_DIR:-$HOME/.herdr/worktrees}"
}

typeset -gA GHSB_HERDR_WT

_ghsb_herdr_wt_parse() {
  local json="$1"
  GHSB_HERDR_WT[workspace_id]=$(printf '%s\n' "$json" | jq -r '.result.workspace.workspace_id // empty')
  GHSB_HERDR_WT[pane_id]=$(printf '%s\n' "$json" | jq -r '.result.root_pane.pane_id // empty')
  GHSB_HERDR_WT[path]=$(printf '%s\n' "$json" | jq -r \
    '.result.workspace.worktree.checkout_path // .result.worktree.path // empty')
  if [[ -z "${GHSB_HERDR_WT[pane_id]}" && -n "${GHSB_HERDR_WT[workspace_id]}" ]]; then
    GHSB_HERDR_WT[pane_id]=$(herdr pane list --workspace "${GHSB_HERDR_WT[workspace_id]}" 2>/dev/null \
      | jq -r '.result.panes[0].pane_id // empty')
  fi
}

_ghsb_herdr_wt_from_open_id() {
  local ws="$1" wt_path="$2"
  GHSB_HERDR_WT[workspace_id]="$ws"
  GHSB_HERDR_WT[path]="$wt_path"
  GHSB_HERDR_WT[pane_id]=$(herdr pane list --workspace "$ws" 2>/dev/null \
    | jq -r '.result.panes[0].pane_id // empty')
}

_ghsb_herdr_wt_list() {
  command -v herdr >/dev/null 2>&1 || return 1
  herdr worktree list --cwd "$1" 2>/dev/null
}

# Existing git worktree path for a local branch, any location.
_ghsb_git_wt_find_branch() {
  local repo_root="$1" branch="$2"
  local line wt_path="" want="branch refs/heads/${branch}"
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      wt_path="${line#worktree }"
    elif [[ "$line" == "$want" ]]; then
      printf '%s\n' "$wt_path"
      return 0
    fi
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
  return 1
}

_ghsb_git_wt_path_from_create_error() {
  printf '%s\n' "$1" | sed -n "s/.*already used by worktree at ['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1
}

# Prints: path<TAB>workspace_id<TAB>branch   (workspace_id/branch may be empty)
_ghsb_herdr_wt_find_branch() {
  local repo_root="$1" branch="$2"
  local listing
  listing=$(_ghsb_herdr_wt_list "$repo_root") || return 1
  printf '%s\n' "$listing" | jq -r --arg b "$branch" '
    .result.worktrees[]
    | select(.is_linked_worktree == true and .branch == $b)
    | "\(.path)\t\(.open_workspace_id // "")\t\(.branch // "")"
  ' | head -1
}

# Linked Herdr worktree whose branch starts with "<issue>-", else legacy Claude path.
_ghsb_herdr_wt_find_issue() {
  local repo_root="$1" issue="$2"
  local listing hit
  listing=$(_ghsb_herdr_wt_list "$repo_root") || listing=""
  hit=$(printf '%s\n' "$listing" | jq -r --arg p "^${issue}-" '
    .result.worktrees[]
    | select(.is_linked_worktree == true and ((.branch // "") | test($p)))
    | "\(.path)\t\(.open_workspace_id // "")\t\(.branch // "")"
  ' | head -1)
  if [[ -n "$hit" ]]; then
    printf '%s\n' "$hit"
    return 0
  fi
  local repo_name worktree_path
  repo_name=$(basename "$repo_root")
  worktree_path="$HOME/.claude/worktrees/${repo_name}-${issue}"
  if [[ -d "$worktree_path" ]]; then
    printf '%s\t\t\n' "$worktree_path"
    return 0
  fi
  local line git_path="" prefix="branch refs/heads/${issue}-"
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      git_path="${line#worktree }"
    elif [[ "$line" == "$prefix"* ]]; then
      printf '%s\t\t\n' "$git_path"
      return 0
    fi
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
  return 1
}

# Best-effort: open an existing git checkout as a Herdr worktree workspace.
# Always sets GHSB_HERDR_WT[path]. Herdr registration is optional so Cursor
# commands still work outside a Herdr TUI / if `herdr` is not on PATH.
_ghsb_herdr_wt_register_path() {
  local repo_root="$1" wt_path="$2" label="$3"
  GHSB_HERDR_WT[path]="$wt_path"
  command -v herdr >/dev/null 2>&1 || return 0
  herdr workspace list >/dev/null 2>&1 || return 0
  local listing ws
  listing=$(_ghsb_herdr_wt_list "$repo_root") || listing=""
  ws=$(printf '%s\n' "$listing" | jq -r --arg p "$wt_path" '
    .result.worktrees[] | select(.path == $p) | .open_workspace_id // empty
  ' | head -1)
  if [[ -n "$ws" && "$ws" != "null" ]]; then
    _ghsb_herdr_wt_from_open_id "$ws" "$wt_path"
    return 0
  fi
  local out
  out=$(herdr worktree open --cwd "$repo_root" --path "$wt_path" --label "$label" --no-focus 2>&1) || {
    echo "herdr worktree open skipped: $out" >&2
    GHSB_HERDR_WT[path]="$wt_path"
    return 0
  }
  _ghsb_herdr_wt_parse "$out"
  [[ -n "${GHSB_HERDR_WT[path]}" ]] || GHSB_HERDR_WT[path]="$wt_path"
}

# Create or open a worktree for an existing local branch.
# Prefers Herdr when the server is up; reuses any existing git checkout
# (including ~/.claude/worktrees) so a second create cannot fail.
# Usage: _ghsb_herdr_wt_ensure_branch <repo_root> <branch> <label>
_ghsb_herdr_wt_ensure_branch() {
  local repo_root="$1" branch="$2" label="$3"
  GHSB_HERDR_WT=()

  local wt_path ws found
  wt_path=$(_ghsb_git_wt_find_branch "$repo_root" "$branch")
  if [[ -z "$wt_path" ]]; then
    found=$(_ghsb_herdr_wt_find_branch "$repo_root" "$branch") || found=""
    if [[ -n "$found" ]]; then
      wt_path=${found%%$'\t'*}
      ws=${found#*$'\t'}; ws=${ws%%$'\t'*}
    fi
  fi
  if [[ -z "$wt_path" ]]; then
    local legacy repo_name
    repo_name=$(basename "$repo_root")
    legacy="$HOME/.claude/worktrees/${label}"
    [[ -d "$legacy" ]] && wt_path="$legacy"
    if [[ -z "$wt_path" && "$label" =~ ^([0-9]+) ]]; then
      legacy="$HOME/.claude/worktrees/${repo_name}-${match[1]}"
      [[ -d "$legacy" ]] && wt_path="$legacy"
    fi
  fi
  if [[ -n "$wt_path" ]]; then
    echo "Worktree already exists at: $wt_path"
    if [[ -n "$ws" && "$ws" != "null" ]]; then
      _ghsb_herdr_wt_from_open_id "$ws" "$wt_path"
    else
      _ghsb_herdr_wt_register_path "$repo_root" "$wt_path" "$label"
    fi
    GHSB_HERDR_WT[path]="${GHSB_HERDR_WT[path]:-$wt_path}"
    _ghsb_herdr_wt_rename_open "$label"
    return 0
  fi

  if ! git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "$repo_root" branch --track "$branch" "origin/${branch}" 2>/dev/null \
      || git -C "$repo_root" fetch origin "${branch}:${branch}" 2>/dev/null \
      || true
  fi

  local herdr_up=0
  if command -v herdr >/dev/null 2>&1 && herdr workspace list >/dev/null 2>&1; then
    herdr_up=1
  fi

  if (( herdr_up )); then
    local out
    out=$(herdr worktree create --cwd "$repo_root" --branch "$branch" --label "$label" --no-focus 2>&1) || {
      wt_path=$(_ghsb_git_wt_path_from_create_error "$out")
      if [[ -n "$wt_path" && -d "$wt_path" ]]; then
        echo "Worktree already exists at: $wt_path"
        _ghsb_herdr_wt_register_path "$repo_root" "$wt_path" "$label"
        _ghsb_herdr_wt_rename_open "$label"
        return 0
      fi
      echo "herdr worktree create failed: $out" >&2
      return 1
    }
    _ghsb_herdr_wt_parse "$out"
    if [[ -z "${GHSB_HERDR_WT[path]}" ]]; then
      echo "Could not parse herdr worktree create:" >&2
      echo "$out" >&2
      return 1
    fi
    echo "Worktree created at: ${GHSB_HERDR_WT[path]}"
    _worktree_setup "${GHSB_HERDR_WT[path]}"
    _ghsb_herdr_wt_rename_open "$label"
    return 0
  fi

  local repo_name slug herdr_path
  repo_name=$(basename "$repo_root")
  slug=$(_ghsb_herdr_branch_slug "$branch")
  herdr_path="$(_ghsb_herdr_worktrees_root)/${repo_name}/${slug}"
  mkdir -p "$(dirname "$herdr_path")"
  git -C "$repo_root" worktree add "$herdr_path" "$branch" || return 1
  echo "Worktree created at: $herdr_path"
  _worktree_setup "$herdr_path"
  GHSB_HERDR_WT[path]="$herdr_path"
}

_ghsb_herdr_wt_rename_open() {
  local label="$1"
  local ws="${GHSB_HERDR_WT[workspace_id]:-}"
  [[ -n "$label" && -n "$ws" ]] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  herdr workspace rename "$ws" "$label" >/dev/null 2>&1 || true
}

_ghsb_herdr_wt_apply_checkout() {
  GHSB_CHECKOUT[worktree]="${GHSB_HERDR_WT[path]}"
  GHSB_CHECKOUT[herdr_workspace]="${GHSB_HERDR_WT[workspace_id]}"
  GHSB_CHECKOUT[herdr_pane]="${GHSB_HERDR_WT[pane_id]}"
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

# Start an agent in an existing Herdr pane (does not create a workspace).
# Prints on stdout (one line): pane_id|agent_name|workspace_id
# Diagnostics → stderr.
# Usage: _ghsb_herdr_launch_in_pane <pane_id> <workspace_id> <label> <worktree> <ai_tool> <prompt>
_ghsb_herdr_launch_in_pane() {
  local pane_id="$1" workspace_id="$2" label="$3" worktree="$4" ai_tool="$5" prompt="$6"
  _ghsb_ensure_herdr || return 1
  [[ -n "$pane_id" ]] || {
    echo "herdr: missing pane id" >&2
    return 1
  }

  # New Claude worktrees always hit the trust dialog otherwise.
  if [[ "$ai_tool" == "claude" ]]; then
    _ghsb_claude_trust_worktree "$worktree"
  fi

  local kind
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

# Canonical Herdr recipe (docs + live-verified on herdr 0.8.0):
#   1. worktree create/open (checkout) — reuse GHSB_CHECKOUT[herdr_pane]
#      else workspace create --cwd … --label … --no-focus
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

  local pane_id workspace_id
  pane_id="${GHSB_CHECKOUT[herdr_pane]:-}"
  workspace_id="${GHSB_CHECKOUT[herdr_workspace]:-}"
  if [[ -n "$pane_id" && -n "$workspace_id" ]]; then
    _ghsb_herdr_launch_in_pane "$pane_id" "$workspace_id" "$label" "$worktree" "$ai_tool" "$prompt"
    return $?
  fi

  local created
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

  _ghsb_herdr_launch_in_pane "$pane_id" "$workspace_id" "$label" "$worktree" "$ai_tool" "$prompt"
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

# Issue → branch → worktree → _worktree_setup. Shared by ghsb and ghi.
# Writes results to GHSB_CHECKOUT: issue branch worktree session_id repo origin default_branch
# Usage: _ghsb_checkout_issue <cmd> <base_branch> <issue_number> <branch_name> <target_fork> [title...]
typeset -gA GHSB_CHECKOUT
_ghsb_checkout_issue() {
  local cmd="${1:-ghsb}"
  local base_branch="$2" issue_number="$3" branch_name="$4" target_fork="$5"
  shift 5
  GHSB_CHECKOUT=()

  local is_fork=false upstream_repo="" fork_repo=""
  local detect
  detect=$(_ghsb_detect_repo)
  is_fork=${detect%%$'\t'*}
  fork_repo=${detect#*$'\t'}; fork_repo=${fork_repo%%$'\t'*}
  upstream_repo=${detect##*$'\t'}

  local issue_repo="$upstream_repo"
  if [[ "$target_fork" == "true" ]]; then
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

  if [[ -z "$issue_number" ]]; then
    local title="$1"
    if [[ -z "$title" ]]; then
      echo "Usage: ${cmd} [-i N] \"Issue title\""
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

  local repo_root repo_name session_id origin_repo
  repo_root=$(_ghsb_repo_root)
  repo_name=$(basename "$repo_root")
  session_id="${repo_name}-${issue_number}"
  origin_repo=$(git remote get-url origin 2>/dev/null | sed 's#.*github\.com[/:]##; s#\.git$##')

  _ghsb_herdr_wt_ensure_branch "$repo_root" "$branch_name" "$(_ghsb_herdr_issue_label "$issue_number" "$branch_name")" || return 1
  _ghsb_herdr_wt_apply_checkout

  GHSB_CHECKOUT[issue]="$issue_number"
  GHSB_CHECKOUT[branch]="$branch_name"
  GHSB_CHECKOUT[session_id]="$session_id"
  GHSB_CHECKOUT[repo]="$issue_repo"
  GHSB_CHECKOUT[origin]="$origin_repo"
  GHSB_CHECKOUT[default_branch]="$default_branch"
  return 0
}

# PR → worktree (gh pr checkout) → _worktree_setup → freshness.
# Writes results to GHSB_CHECKOUT. Shared by ghsbpr and ghipr.
# Usage: _ghsb_checkout_pr <pr-number>
_ghsb_checkout_pr() {
  local pr_number="$1"
  GHSB_CHECKOUT=()

  if [[ -z "$pr_number" || ! "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: PR number must be numeric"
    return 1
  fi

  local is_fork=false upstream_repo="" fork_repo=""
  local detect
  detect=$(_ghsb_detect_repo)
  is_fork=${detect%%$'\t'*}
  fork_repo=${detect#*$'\t'}; fork_repo=${fork_repo%%$'\t'*}
  upstream_repo=${detect##*$'\t'}
  [[ "$is_fork" == "true" ]] && echo "Detected fork of $upstream_repo"

  local -a repo_args=()
  [[ "$is_fork" == "true" ]] && repo_args=(-R "$upstream_repo")

  local pr_data
  pr_data=$(gh pr view "${repo_args[@]}" "$pr_number" \
    --json headRefName,baseRefName,isCrossRepository,maintainerCanModify,mergeable,mergeStateStatus,createdAt,updatedAt,headRepositoryOwner,url,title 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch PR info: $pr_data"
    return 1
  fi

  local head_ref base_ref is_cross can_modify mergeable merge_state created_at updated_at fork_owner pr_url pr_title
  head_ref=$(echo "$pr_data" | jq -r '.headRefName')
  base_ref=$(echo "$pr_data" | jq -r '.baseRefName')
  is_cross=$(echo "$pr_data" | jq -r '.isCrossRepository')
  can_modify=$(echo "$pr_data" | jq -r '.maintainerCanModify')
  mergeable=$(echo "$pr_data" | jq -r '.mergeable')
  merge_state=$(echo "$pr_data" | jq -r '.mergeStateStatus')
  created_at=$(echo "$pr_data" | jq -r '.createdAt')
  updated_at=$(echo "$pr_data" | jq -r '.updatedAt')
  fork_owner=$(echo "$pr_data" | jq -r '.headRepositoryOwner.login')
  pr_url=$(echo "$pr_data" | jq -r '.url')
  pr_title=$(echo "$pr_data" | jq -r '.title')

  local local_branch="$head_ref"
  if [[ "$is_cross" == "true" ]]; then
    echo "PR #${pr_number} is from fork ${fork_owner} (cross-repo)"
  fi

  local repo_root repo_name worktree_path session_id issue_repo origin_repo
  repo_root=$(_ghsb_repo_root)
  repo_name=$(basename "$repo_root")
  session_id="${repo_name}-pr-${pr_number}"
  issue_repo="$upstream_repo"
  origin_repo="$fork_repo"
  [[ -z "$issue_repo" ]] && issue_repo="$origin_repo"

  local slug found rest ws herdr_path legacy
  slug=$(_ghsb_herdr_branch_slug "$head_ref")
  herdr_path="$(_ghsb_herdr_worktrees_root)/${repo_name}/${slug}"
  legacy="$HOME/.claude/worktrees/${repo_name}-${pr_number}"
  GHSB_HERDR_WT=()
  found=$(_ghsb_herdr_wt_find_branch "$repo_root" "$head_ref") || found=""
  if [[ -n "$found" ]]; then
    worktree_path=${found%%$'\t'*}
    rest=${found#*$'\t'}
    ws=${rest%%$'\t'*}
    echo "Worktree already exists at: $worktree_path"
    if [[ -n "$ws" && "$ws" != "null" ]]; then
      _ghsb_herdr_wt_from_open_id "$ws" "$worktree_path"
    else
      _ghsb_herdr_wt_register_path "$repo_root" "$worktree_path" "pr-${pr_number}"
    fi
  elif [[ -d "$legacy" ]]; then
    worktree_path="$legacy"
    echo "Worktree already exists at: $worktree_path"
    _ghsb_herdr_wt_register_path "$repo_root" "$worktree_path" "pr-${pr_number}"
  elif [[ -d "$herdr_path" ]]; then
    worktree_path="$herdr_path"
    echo "Worktree already exists at: $worktree_path"
    _ghsb_herdr_wt_register_path "$repo_root" "$worktree_path" "pr-${pr_number}"
  else
    if git show-ref --verify --quiet "refs/heads/${local_branch}"; then
      echo "Error: local branch '${local_branch}' already exists but has no worktree."
      echo "Delete it first (git branch -D ${local_branch}) or resolve manually."
      return 1
    fi

    echo "Checking out PR #${pr_number} (branch '${local_branch}')..."
    mkdir -p "$(dirname "$herdr_path")"
    worktree_path="$herdr_path"
    if ! git worktree add --detach "$worktree_path" >/dev/null; then
      echo "Failed to create worktree"
      return 1
    fi

    local -a checkout_args=("$pr_number")
    [[ "$is_fork" == "true" ]] && checkout_args+=(-R "$upstream_repo")
    if ! (cd "$worktree_path" && gh pr checkout "${checkout_args[@]}"); then
      echo "Failed to check out PR #${pr_number}"
      git worktree remove --force "$worktree_path" 2>/dev/null
      git branch -D "$local_branch" 2>/dev/null
      return 1
    fi

    if [[ "$is_cross" == "true" ]]; then
      if [[ "$can_modify" == "true" ]]; then
        echo "Maintainer edits allowed — pushes go back to ${fork_owner}'s fork."
      else
        echo "Note: maintainer edits are NOT allowed on this PR (read-only review)."
      fi
    fi

    echo "Worktree created at: $worktree_path"
    _worktree_setup "$worktree_path"
    _ghsb_herdr_wt_register_path "$repo_root" "$worktree_path" "pr-${pr_number}"
  fi
  _ghsb_herdr_wt_apply_checkout

  local base_fetch_source="origin" behind="?" ahead="?"
  [[ "$is_fork" == "true" ]] && base_fetch_source="https://github.com/${upstream_repo}.git"
  if git -C "$worktree_path" fetch "$base_fetch_source" "$base_ref" 2>/dev/null; then
    behind=$(git -C "$worktree_path" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)
    ahead=$(git -C "$worktree_path" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)
  fi
  echo "PR is ${behind} commit(s) behind ${base_ref}, ${ahead} ahead (mergeable: ${mergeable})"

  local relevance_note
  relevance_note="PR #${pr_number} freshness context for this review:
- Title: ${pr_title}
- Base branch: ${base_ref}
- Behind ${base_ref} by: ${behind} commit(s)
- Ahead of ${base_ref} by: ${ahead} commit(s)
- Mergeable: ${mergeable} / merge state: ${merge_state}
- From fork: ${is_cross} (owner: ${fork_owner}, maintainer edits: ${can_modify})
- Opened: ${created_at}; last updated: ${updated_at}

As part of the review, assess how relevant and current this PR still is. If it is
significantly behind ${base_ref}, conflicting, or stale, flag it, explain whether
the changes are still applicable to the current codebase, and recommend whether it
needs a rebase or update before it can be merged."

  GHSB_CHECKOUT[pr]="$pr_number"
  GHSB_CHECKOUT[branch]="$head_ref"
  GHSB_CHECKOUT[base]="$base_ref"
  GHSB_CHECKOUT[worktree]="$worktree_path"
  GHSB_CHECKOUT[session_id]="$session_id"
  GHSB_CHECKOUT[repo]="$issue_repo"
  GHSB_CHECKOUT[origin]="$origin_repo"
  GHSB_CHECKOUT[is_fork]="$is_fork"
  GHSB_CHECKOUT[is_cross]="$is_cross"
  GHSB_CHECKOUT[can_modify]="$can_modify"
  GHSB_CHECKOUT[mergeable]="$mergeable"
  GHSB_CHECKOUT[merge_state]="$merge_state"
  GHSB_CHECKOUT[created_at]="$created_at"
  GHSB_CHECKOUT[updated_at]="$updated_at"
  GHSB_CHECKOUT[fork_owner]="$fork_owner"
  GHSB_CHECKOUT[pr_url]="$pr_url"
  GHSB_CHECKOUT[pr_title]="$pr_title"
  GHSB_CHECKOUT[behind]="$behind"
  GHSB_CHECKOUT[ahead]="$ahead"
  GHSB_CHECKOUT[relevance_note]="$relevance_note"
  return 0
}

# Rank changed files + SUMMARY.md for a PR review. Requires GHSB_CHECKOUT from
# _ghsb_checkout_pr. Sets GHSB_CHECKOUT[artifacts] and [preview_url].
_ghsb_pr_write_artifacts() {
  local worktree="${GHSB_CHECKOUT[worktree]}"
  local session_id="${GHSB_CHECKOUT[session_id]}"
  local base_ref="${GHSB_CHECKOUT[base]}"
  local pr="${GHSB_CHECKOUT[pr]}"
  local repo="${GHSB_CHECKOUT[repo]}"
  local branch="${GHSB_CHECKOUT[branch]}"
  local pr_title="${GHSB_CHECKOUT[pr_title]}"
  local pr_url="${GHSB_CHECKOUT[pr_url]}"
  local behind="${GHSB_CHECKOUT[behind]}"
  local ahead="${GHSB_CHECKOUT[ahead]}"

  local art
  art="$GHSB_ARTIFACTS_DIR/${session_id}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$art"

  local base_ref_for_diff="FETCH_HEAD"
  if git -C "$worktree" rev-parse --verify "origin/${base_ref}" >/dev/null 2>&1; then
    base_ref_for_diff="origin/${base_ref}"
  elif git -C "$worktree" rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    base_ref_for_diff="$base_ref"
  fi
  (
    cd "$worktree" || exit 0
    _ghsb_rank_files "$base_ref_for_diff" "$art/files-to-review.txt"
  )
  if [[ -s "$art/files-to-review.txt" ]]; then
    echo ""
    echo "Most relevant files to review manually (in order):"
    head -20 "$art/files-to-review.txt" | sed 's/^/  /'
    echo "  (full list: $art/files-to-review.txt)"
    echo ""
  fi

  local preview_url=""
  preview_url=$(_ghsb_resolve_preview_url "$repo" "$pr" 2>/dev/null) || preview_url=""

  {
    echo "# ghsbpr — PR #${pr}"
    echo ""
    echo "- Title: $pr_title"
    echo "- PR: $pr_url"
    echo "- Branch: $branch"
    echo "- Base: $base_ref (${behind} behind, ${ahead} ahead)"
    echo "- Worktree: $worktree"
    [[ -n "$preview_url" ]] && echo "- Preview: $preview_url"
    echo ""
    echo "## Files to review (ranked)"
    echo ""
    cat "$art/files-to-review.txt" 2>/dev/null || echo "(none)"
  } > "$art/SUMMARY.md"

  GHSB_CHECKOUT[artifacts]="$art"
  GHSB_CHECKOUT[preview_url]="$preview_url"
}

_ghsb_pr_review_prompt() {
  local ai_tool="$1"
  local pr="${GHSB_CHECKOUT[pr]}"
  local art="${GHSB_CHECKOUT[artifacts]}"
  local relevance="${GHSB_CHECKOUT[relevance_note]}"
  if [[ "$ai_tool" == "grok" ]]; then
    printf '%s\n' "/review-pr ${pr}

${relevance}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files for findings."
  else
    printf '%s\n' "/pr-review-toolkit:review-pr ${pr}

${relevance}

Also read ${art}/SUMMARY.md and ${art}/files-to-review.txt. Prioritise the ranked files for findings."
  fi
}

# Require a live Herdr pane (HERDR_PANE_ID + HERDR_WORKSPACE_ID).
# Usage: _ghsb_require_herdr_pane <cmd>
_ghsb_require_herdr_pane() {
  local cmd="${1:-ghi}"
  if [[ -z "${HERDR_PANE_ID:-}" || -z "${HERDR_WORKSPACE_ID:-}" ]]; then
    echo "${cmd} must be run from inside a Herdr pane (e.g. the repo root space)."
    echo "  1. herdr"
    echo "  2. ${cmd} …"
    return 1
  fi
  _ghsb_ensure_herdr
}

# Agent name in a Herdr pane, or empty.
_ghsb_pane_agent() {
  local pane_id="${1:-}"
  [[ -n "$pane_id" ]] || return 1
  local agent
  agent=$(herdr pane get "$pane_id" 2>/dev/null | jq -r '.result.pane.agent // empty')
  [[ -n "$agent" && "$agent" != "null" ]] || return 1
  printf '%s\n' "$agent"
}

_ghsb_issue_space_label() {
  local fallback="${1:-}"
  if [[ -n "${GHSB_CHECKOUT[issue]:-}" && -n "${GHSB_CHECKOUT[branch]:-}" ]]; then
    _ghsb_herdr_issue_label "${GHSB_CHECKOUT[issue]}" "${GHSB_CHECKOUT[branch]}"
  elif [[ -n "${GHSB_CHECKOUT[pr]:-}" ]]; then
    printf 'pr-%s\n' "${GHSB_CHECKOUT[pr]}"
  else
    printf '%s\n' "$fallback"
  fi
}

# Focus the checkout's Herdr worktree space when it is not this space.
# Leaves the caller's space (repo root) unnamed/un-cd'd. Returns 0 if switched.
_ghsb_focus_worktree_if_other() {
  local wt_ws="${GHSB_CHECKOUT[herdr_workspace]:-}"
  local here="${HERDR_WORKSPACE_ID:-}"
  local label="${1:-}"
  [[ -n "$wt_ws" && "$wt_ws" != "$here" ]] || return 1
  [[ -n "$label" ]] && herdr workspace rename "$wt_ws" "$label" >/dev/null 2>&1 || true
  herdr workspace focus "$wt_ws" >/dev/null 2>&1 || {
    echo "herdr workspace focus $wt_ws failed" >&2
    return 1
  }
  echo "Switched to worktree ${label:-$wt_ws}"
  return 0
}

# Start an agent in the worktree's Herdr space. From the repo root, that means
# focusing the grouped worktree (does not rename or cd this space). If this
# pane already is that space and has an agent, the prompt goes there.
# Usage: _ghsb_launch_in_current_space <label> <worktree> <ai_tool> <prompt> <session_id> [--review]
_ghsb_launch_in_current_space() {
  local label="$1" worktree="$2" ai_tool="$3" prompt="$4" session_id="$5"
  local as_review=false
  [[ "${6:-}" == "--review" ]] && as_review=true

  local pane_id="${HERDR_PANE_ID:-}"
  local workspace_id="${HERDR_WORKSPACE_ID:-}"
  [[ -n "$pane_id" && -n "$workspace_id" ]] || {
    echo "herdr: missing HERDR_PANE_ID / HERDR_WORKSPACE_ID" >&2
    return 1
  }

  local space_label
  space_label=$(_ghsb_issue_space_label "$session_id")
  local wt_ws="${GHSB_CHECKOUT[herdr_workspace]:-}"
  local wt_pane="${GHSB_CHECKOUT[herdr_pane]:-}"

  if _ghsb_focus_worktree_if_other "$space_label"; then
    pane_id="${wt_pane:-$pane_id}"
    workspace_id="$wt_ws"
  else
    herdr workspace rename "$workspace_id" "$space_label" >/dev/null 2>&1 || true
    cd "$worktree" || return 1
  fi
  _ghsb_session_set "$session_id" "herdr_pane" "$pane_id"
  _ghsb_session_set "$session_id" "herdr_workspace" "$workspace_id"

  local current_agent=""
  current_agent=$(_ghsb_pane_agent "$pane_id") || current_agent=""

  if [[ -n "$current_agent" ]]; then
    echo "This pane already has agent '$current_agent'; sending the prompt there."
    _ghsb_herdr_send_prompt "$current_agent" "$prompt" \
      || _ghsb_herdr_send_prompt "$pane_id" "$prompt" \
      || true
    _ghsb_session_set "$session_id" "herdr_agent" "$current_agent"
    if $as_review; then
      _ghsb_session_set "$session_id" "review_pane" "$pane_id"
      _ghsb_session_set "$session_id" "review_agent" "$current_agent"
    fi
    return 0
  fi

  local log_dir log
  log_dir="$GHSB_HOME/logs"
  mkdir -p "$log_dir"
  log="$log_dir/${session_id}.log"
  echo "Starting ${ai_tool} in ${workspace_id} once the shell is idle."
  echo "Log: $log"

  (
    sleep 0.5
    local launch_line agent_name
    launch_line=$(_ghsb_herdr_launch_in_pane "$pane_id" "$workspace_id" "$label" "$worktree" "$ai_tool" "$prompt") || launch_line=""
    if [[ -n "$launch_line" ]]; then
      agent_name=${launch_line#*|}; agent_name=${agent_name%%|*}
      _ghsb_session_set "$session_id" "herdr_agent" "$agent_name"
      if $as_review; then
        _ghsb_session_set "$session_id" "review_pane" "$pane_id"
        _ghsb_session_set "$session_id" "review_agent" "$agent_name"
      fi
    fi
  ) >>"$log" 2>&1 &!
}

# Shared implement prompt for ghsb / ghi agents.
# Optional 6th/7th args: want_video want_review ("true"/"false"). Default: push + PR only.
_ghsb_implement_prompt() {
  local issue_number="$1" issue_repo="$2" branch_name="$3" session_id="$4"
  local ai_tool="${5:-}"
  local want_video="${6:-false}" want_review="${7:-false}"
  local review_skill="/pr-review-toolkit:review-pr"
  [[ "$ai_tool" == "grok" ]] && review_skill="/review-pr"
  local issue_view_cmd="gh issue view ${issue_number} -R ${issue_repo}"
  local wrap step=3
  wrap="When implementation is complete:
1. Push the branch
2. Open a PR if one does not exist (gh pr create), linking issue #${issue_number}"
  if [[ "$want_video" == true ]]; then
    wrap+=$'\n'"${step}. Run: ghsb finish --video ${session_id}
   Records a Playwright walkthrough if UI files changed. Stay in this session."
    step=$((step + 1))
  fi
  if [[ "$want_review" == true ]]; then
    wrap+=$'\n'"${step}. Review the PR here: ${review_skill} <pr-number>
   Fix any issues you find. Stay in this session — do not start another agent."
  fi
  printf '%s\n' "Implement GitHub issue #${issue_number}. First run ${issue_view_cmd} for details. If the issue body is empty or lacks context, ask me what to accomplish and any constraints, then update the issue via 'gh issue edit ${issue_number} -R ${issue_repo}' before coding.

Work in this worktree. Commit on branch ${branch_name} and push to origin regularly.

${wrap}"
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
