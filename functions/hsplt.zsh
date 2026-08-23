# hsplt — Cursor left + attach a running Herdr workspace for an issue/PR
# Usage: hsplt [--remote HOST] [--session NAME] [--pr] [--here|-n] [<issue|pr|label>]
#        hsplt 1220
#        hsplt pr 1178
#        hsplt --remote workbox 1220
#
# Default: new Ghostty window (PICK ME + Cursor + herdr agent attach).
# Direct-attaches that workspace's agent so two windows can show different
# spaces. --here uses this terminal. Does not create a worktree or start an agent.

hsplt() {
  local remote="" session="" as_pr=false here=false
  local -a positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--remote)
        [[ -n "${2:-}" ]] || { echo "hsplt: --remote needs a host"; return 1; }
        remote="$2"
        shift 2
        ;;
      -s|--session)
        [[ -n "${2:-}" ]] || { echo "hsplt: --session needs a name"; return 1; }
        session="$2"
        shift 2
        ;;
      --pr)
        as_pr=true
        shift
        ;;
      -n|--new-window)
        here=false
        shift
        ;;
      --here)
        here=true
        shift
        ;;
      -h|--help)
        _hsplt_help
        return 0
        ;;
      pr)
        as_pr=true
        shift
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local query="${positional[1]:-}"
  if [[ "$query" == \#* ]]; then
    query="${query#\#}"
  fi
  if [[ "$query" == pr-* && "$query" != pr-*-* ]]; then
    as_pr=true
    query="${query#pr-}"
  fi
  if (( ${#positional[@]} > 1 )); then
    echo "hsplt: extra arguments: ${positional[*]:1}"
    _hsplt_help
    return 1
  fi

  if [[ -n "$remote" ]]; then
    command -v herdr >/dev/null 2>&1 || {
      echo "Error: herdr not found. Install: curl -fsSL https://herdr.dev/install.sh | sh"
      return 1
    }
  else
    _ghsb_ensure_herdr || return 1
  fi

  local listing
  listing=$(_hsplt_cli "$remote" "$session" workspace list) || {
    echo "hsplt: could not list Herdr workspaces."
    [[ -n "$remote" ]] && echo "  ssh to ${remote} and check that herdr is on PATH, then: herdr"
    return 1
  }

  local repo="" cwd="$PWD"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo=$(basename "$(_ghsb_repo_root)")
  fi

  local kind="issue"
  if $as_pr; then
    kind="pr"
  elif [[ -z "$query" ]]; then
    kind="cwd"
  elif [[ "$query" =~ ^[0-9]+$ ]]; then
    kind="issue"
  else
    kind="label"
  fi

  local pick="" pick_ec=0
  pick=$(_hsplt_pick "$listing" "$kind" "$query" "$repo" "$cwd")
  pick_ec=$?
  (( pick_ec == 2 )) && return 1

  # Bare number: if no issue workspace, try PR.
  if (( pick_ec != 0 )) && [[ "$kind" == "issue" ]]; then
    pick=$(_hsplt_pick "$listing" "pr" "$query" "$repo" "$cwd")
    pick_ec=$?
    (( pick_ec == 2 )) && return 1
  fi

  # ghsb session metadata as a last resort (must still be a live workspace).
  if (( pick_ec != 0 )) && [[ -n "$query" ]]; then
    pick=$(_hsplt_from_ghsb "$listing" "$query" "$as_pr") || pick=""
  fi

  if [[ -z "$pick" ]]; then
    echo "No running Herdr workspace for: ${query:-$cwd}"
    echo ""
    echo "Live workspaces:"
    printf '%s\n' "$listing" | jq -r '
      .result.workspaces[]
      | "  \(.label)\t\(.workspace_id)\t\(.worktree.checkout_path // "")"
    '
    echo ""
    echo "Start one first (ghi / ghipr / ghsb / ghwtv), then: hsplt ${query:-<issue|pr>}"
    return 1
  fi

  # Never `local path` — zsh ties path to PATH and herdr/cursor vanish.
  local ws_id label wt_path rest
  ws_id=${pick%%$'\t'*}
  rest=${pick#*$'\t'}
  label=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  wt_path=${rest%%$'\t'*}

  if [[ -z "$wt_path" || "$wt_path" == "null" ]]; then
    wt_path=$(_hsplt_pane_path "$remote" "$session" "$ws_id") || wt_path=""
  fi

  echo "Workspace: $label  ($ws_id)"
  [[ -n "$wt_path" ]] && echo "Worktree:  $wt_path"

  if ! $here; then
    local -a child=(--here)
    [[ -n "$remote" ]] && child+=(--remote "$remote")
    [[ -n "$session" ]] && child+=(--session "$session")
    $as_pr && child+=(--pr)
    [[ -n "$query" ]] && child+=("$query")
    echo "Opening a new Ghostty window…"
    _hsplt_ghostty_window "${wt_path:-$PWD}" "${child[@]}"
    return 0
  fi

  if [[ -n "$wt_path" ]]; then
    if [[ -t 1 ]]; then
      _splt_banner
    fi
    _hsplt_open_cursor "$wt_path" "$remote" || true
    if [[ -t 1 ]]; then
      _splt_wait
    fi
  else
    echo "No worktree path on this workspace; attaching Herdr without Cursor."
  fi

  local target
  target=$(_hsplt_attach_target "$remote" "$session" "$ws_id" "$wt_path") || target=""
  if [[ -z "$target" ]]; then
    echo "hsplt: no agent or pane to attach in workspace $label ($ws_id)"
    return 1
  fi

  if [[ "${HERDR_ENV:-}" == 1 ]]; then
    echo "Already inside Herdr; Cursor opened for $label."
    echo "Attach from Ghostty: hsplt --here ${query:-$label}"
    return 0
  fi

  if [[ ! -t 1 ]]; then
    echo "Not a TTY. Attach with:"
    _hsplt_print_attach "$remote" "$session" "$target"
    return 0
  fi

  if [[ "${TERM_PROGRAM:-}" == "ghostty" ]]; then
    osascript -e 'tell application "Ghostty" to activate' >/dev/null 2>&1 || true
  fi

  _hsplt_agent_attach "$remote" "$session" "$target"
}

_hsplt_help() {
  cat <<'EOF'
hsplt — open Cursor + attach a running Herdr workspace

Looks up a live Herdr workspace for an issue, PR, or label. Default: open a
new Ghostty window, show PICK ME, tile Cursor left, then
`herdr agent attach` that space's agent (so two windows can show different
spaces). Does not create a worktree or start an agent.

  hsplt 1220                      # new window (issue 1220, else PR)
  hsplt pr 1178
  hsplt --here 1220               # this terminal instead
  hsplt --remote workbox 1220
  hsplt --remote workbox --session agents pr 46
  hsplt                           # workspace for the current directory

Flags:
  -n, --new-window    New Ghostty window (default)
  --here              Use this terminal (PICK ME + attach here)
  -r, --remote HOST   Lookup/attach over SSH (Host or user@host)
  -s, --session NAME  Named Herdr session (HERDR_SESSION / --session)
  --pr                Treat the number as a PR
EOF
}

# New Ghostty window that runs hsplt --here … (PICK ME + Cursor + attach).
# Ghostty registers .command as a terminal script; `open -a` runs it in a new
# surface. Do not keystroke into Cmd+N — those keys land in the Herdr pane.
_hsplt_ghostty_window() {
  local dir="$1"
  shift
  local launcher
  launcher=$(mktemp "${TMPDIR:-/tmp}/hsplt.XXXXXX") || return 1
  mv "$launcher" "$launcher.command" || return 1
  launcher="$launcher.command"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID'
    print -r -- 'export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:$PATH"'
    print -r -- 'trap '\''rm -f -- "$0"'\'' EXIT'
    print -r -- 'if [[ -d "$HOME/.zsh_functions" ]]; then'
    print -r -- '  setopt NULL_GLOB'
    print -r -- '  for f in "$HOME/.zsh_functions"/*.zsh; do'
    print -r -- '    source "$f"'
    print -r -- '  done'
    print -r -- 'fi'
    print -r -- "cd $(printf '%q' "$dir") || true"
    print -rn -- 'hsplt '
    printf '%q ' "$@"
    print
  } > "$launcher"
  chmod +x "$launcher"
  open -a Ghostty.app "$launcher" || {
    echo "hsplt: could not open Ghostty. Run in this terminal:"
    echo "  hsplt --here $(printf '%q ' "$@")"
    return 1
  }
}

# herdr CLI against the local or remote server (not the TUI).
_hsplt_cli() {
  local remote="$1" session="$2"
  shift 2
  if [[ -z "$remote" ]]; then
    if [[ -n "$session" ]]; then
      HERDR_SESSION="$session" herdr "$@"
    else
      herdr "$@"
    fi
    return $?
  fi
  local cmd
  cmd=$(printf '%q ' herdr "$@")
  [[ -n "$session" ]] && cmd="HERDR_SESSION=$(printf '%q' "$session") ${cmd}"
  cmd="PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\" ${cmd}"
  local dest="$remote" port=""
  if [[ "$remote" == ssh://* ]]; then
    dest="${remote#ssh://}"
    dest="${dest%%/*}"
    if [[ "$dest" == *:* && "$dest" != \[* ]]; then
      port="${dest##*:}"
      dest="${dest%:*}"
    fi
  fi
  local -a ssh=(ssh -q -o BatchMode=yes -o ConnectTimeout=8)
  [[ -n "$port" ]] && ssh+=(-p "$port")
  "${ssh[@]}" "$dest" -- "bash -lc $(printf '%q' "$cmd")"
}

# Agent name or pane id in $ws, preferring ghi/ghsb/ghwt* names.
_hsplt_attach_target() {
  local remote="$1" session="$2" ws="$3" wt_path="$4"
  local json target
  json=$(_hsplt_cli "$remote" "$session" agent list) || json=""
  target=$(printf '%s\n' "$json" | jq -r --arg ws "$ws" --arg cwd "${wt_path:-}" '
    def score:
      (if (.name // "") != "" then 10 else 0 end)
      + (if ((.name // "") | test("^(ghi|ghsb|ghwt)")) then 20 else 0 end)
      + (if $cwd != "" and ((.foreground_cwd // .cwd // "") | startswith($cwd)) then 5 else 0 end);
    [.result.agents[]? | select(.workspace_id == $ws)]
    | if length == 0 then empty
      else sort_by(-score) | .[0] | (.name // .pane_id // empty)
      end
  ')
  if [[ -n "$target" && "$target" != "null" ]]; then
    printf '%s\n' "$target"
    return 0
  fi
  json=$(_hsplt_cli "$remote" "$session" pane list --workspace "$ws") || return 1
  printf '%s\n' "$json" | jq -r '.result.panes[0].pane_id // empty'
}

_hsplt_agent_attach() {
  local remote="$1" session="$2" target="$3"
  [[ -n "$target" ]] || return 1
  echo "Attaching ${target}…"
  if [[ -z "$remote" ]]; then
    if [[ -n "$session" ]]; then
      HERDR_SESSION="$session" herdr agent attach "$target" \
        || HERDR_SESSION="$session" herdr agent attach "$target" --takeover
    else
      herdr agent attach "$target" \
        || herdr agent attach "$target" --takeover
    fi
    return $?
  fi
  local cmd dest="$remote" port=""
  cmd="herdr agent attach $(printf '%q' "$target") --takeover"
  [[ -n "$session" ]] && cmd="HERDR_SESSION=$(printf '%q' "$session") ${cmd}"
  cmd="PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\" ${cmd}"
  if [[ "$remote" == ssh://* ]]; then
    dest="${remote#ssh://}"
    dest="${dest%%/*}"
    if [[ "$dest" == *:* && "$dest" != \[* ]]; then
      port="${dest##*:}"
      dest="${dest%:*}"
    fi
  fi
  local -a ssh=(ssh -t -q -o BatchMode=yes -o ConnectTimeout=8)
  [[ -n "$port" ]] && ssh+=(-p "$port")
  "${ssh[@]}" "$dest" -- "bash -lc $(printf '%q' "$cmd")"
}

_hsplt_print_attach() {
  local remote="$1" session="$2" target="$3"
  if [[ -n "$remote" ]]; then
    echo "  ssh -t $(printf '%q' "$remote") -- herdr agent attach $(printf '%q' "$target") --takeover"
    return 0
  fi
  if [[ -n "$session" ]]; then
    echo "  HERDR_SESSION=$(printf '%q' "$session") herdr agent attach $(printf '%q' "$target")"
  else
    echo "  herdr agent attach $(printf '%q' "$target")"
  fi
}

# Winner line: workspace_id<TAB>label<TAB>path<TAB>score
# Exit 1 = no match. Exit 2 = ambiguous (tie printed on stderr).
_hsplt_pick() {
  local json="$1" kind="$2" query="$3" repo="$4" cwd="$5"
  local rows winner_score count
  rows=$(printf '%s\n' "$json" | jq -r \
    --arg kind "$kind" \
    --arg n "$query" \
    --arg repo "$repo" \
    --arg cwd "$cwd" '
      def pathof: (.worktree.checkout_path // "");
      def repo_of: (.worktree.repo_name // "");
      def score_issue:
        (pathof) as $p
        | if $repo != "" and .label == ($repo + "-" + $n) then 100
          elif .label == $n then 95
          elif .label | test("^" + $n + "-") then 90
          elif (.label | test("-" + $n + "$"))
               and (.label | test("^pr-") | not)
               and (.label | test("-pr-" + $n + "$") | not) then 80
          elif ($p | test("(^|/)" + $n + "-")) then 70
          elif ($p | test("(^|/)" + $n + "$")) then 65
          else 0 end;
      def score_pr:
        if .label == ("pr-" + $n) then 100
        elif $repo != "" and .label == ($repo + "-pr-" + $n) then 100
        elif .label | test("-pr-" + $n + "$") then 90
        else 0 end;
      def score_label:
        if .label == $n or .workspace_id == $n then 100
        elif ($n != "" and (.label | contains($n))) then 60
        else 0 end;
      def score_cwd:
        (pathof) as $p
        | if $p != "" and ($cwd == $p or ($cwd | startswith($p + "/"))) then 100
          elif ($cwd | split("/") | .[-1]) == .label then 90
          else 0 end;
      .result.workspaces[]
      | . as $w
      | ($w | pathof) as $p
      | ($kind
          | if . == "pr" then ($w | score_pr)
            elif . == "label" then ($w | score_label)
            elif . == "cwd" then ($w | score_cwd)
            else ($w | score_issue)
            end) as $base
      | select($base > 0)
      | ($base
          + (if $repo != "" and ($w | repo_of) == $repo then 10 else 0 end)
          + (if $p != "" and $cwd != ""
                and ($cwd == $p or ($cwd | startswith($p + "/")))
             then 5 else 0 end)) as $score
      | [$score, $w.workspace_id, $w.label, $p]
      | @tsv
    ') || rows=""

  [[ -n "$rows" ]] || return 1

  winner_score=$(printf '%s\n' "$rows" | awk -F'\t' 'BEGIN{m=0} $1+0>m{m=$1+0} END{print m}')
  local -a winners=()
  local line s
  while IFS= read -r line; do
    s=${line%%$'\t'*}
    [[ "$s" == "$winner_score" ]] || continue
    winners+=("$line")
  done <<< "$rows"

  count=${#winners[@]}
  if (( count == 0 )); then
    return 1
  fi
  if (( count > 1 )); then
    echo "hsplt: ${count} workspaces match '${query:-$cwd}'. Be more specific:" >&2
    local w
    for w in "${winners[@]}"; do
      echo "  ${w#*$'\t'}" >&2
    done
    return 2
  fi

  # Drop leading score so callers get id, label, path, score
  local rest
  line="${winners[1]}"
  s=${line%%$'\t'*}
  rest=${line#*$'\t'}
  printf '%s\t%s\n' "$rest" "$s"
}

_hsplt_from_ghsb() {
  local listing="$1" query="$2" as_pr="$3"
  local sid=""
  if [[ "$as_pr" == true && "$query" =~ ^[0-9]+$ ]]; then
    local match
    match=$(find "${GHSB_SESSIONS_DIR:-$HOME/.ghsb/sessions}" -maxdepth 1 -name "*-pr-${query}.json" 2>/dev/null | head -1)
    [[ -n "$match" ]] && sid=$(basename "$match" .json)
  fi
  if [[ -z "$sid" ]]; then
    sid=$(_ghsb_resolve_session_id "$query") || sid=""
  fi
  [[ -n "$sid" ]] || return 1

  local ws wt_path label
  ws=$(_ghsb_session_get "$sid" "herdr_workspace") || ws=""
  wt_path=$(_ghsb_session_get "$sid" "worktree") || wt_path=""
  label="$sid"

  local live
  if [[ -n "$ws" ]]; then
    live=$(printf '%s\n' "$listing" | jq -r --arg id "$ws" '
      .result.workspaces[] | select(.workspace_id == $id)
      | "\(.workspace_id)\t\(.label)\t\(.worktree.checkout_path // "")"
    ')
  fi
  if [[ -z "$live" ]]; then
    live=$(printf '%s\n' "$listing" | jq -r --arg label "$sid" '
      .result.workspaces[] | select(.label == $label)
      | "\(.workspace_id)\t\(.label)\t\(.worktree.checkout_path // "")"
    ')
  fi
  [[ -n "$live" ]] || return 1

  local live_path
  live_path=${live##*$'\t'}
  [[ -n "$live_path" && "$live_path" != "null" ]] || live_path="$wt_path"
  local live_id live_label
  live_id=${live%%$'\t'*}
  live_label=${live#*$'\t'}; live_label=${live_label%%$'\t'*}
  printf '%s\t%s\t%s\t%s\n' "$live_id" "$live_label" "$live_path" "ghsb"
}

_hsplt_pane_path() {
  local remote="$1" session="$2" ws="$3"
  local panes
  panes=$(_hsplt_cli "$remote" "$session" pane list --workspace "$ws") || return 1
  printf '%s\n' "$panes" | jq -r '
    [.result.panes[]? | .foreground_cwd // .cwd // empty]
    | map(select(. != "" and . != "null"))
    | .[0] // empty
  '
}

_hsplt_open_cursor() {
  local wt_path="$1" remote="$2"
  command -v cursor >/dev/null 2>&1 || {
    echo "cursor not on PATH; skip tiling."
    return 1
  }

  if [[ -n "$remote" ]]; then
    local dest="$remote"
    [[ "$dest" == ssh://* ]] && dest="${dest#ssh://}"
    dest="${dest%%/*}"
    dest="${dest%:*}"
    local uri="vscode-remote://ssh-remote+${dest}${wt_path}"
    cursor --new-window --folder-uri "$uri" >/dev/null 2>&1 \
      || open "cursor://vscode-remote/ssh-remote+${dest}${wt_path}" >/dev/null 2>&1 \
      || {
        echo "Could not open Cursor on remote ${dest}:${wt_path}"
        return 1
      }
    _cursor_tile_left "${wt_path:t}"
    return 0
  fi

  if [[ ! -e "$wt_path" ]]; then
    echo "Worktree path missing locally: $wt_path"
    return 1
  fi
  cursor --new-window "$wt_path"
  _cursor_tile_left "$wt_path"
}
