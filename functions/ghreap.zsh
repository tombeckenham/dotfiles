# Reap Herdr agents whose branch's PR is already merged or closed.
#
# ghi / ghipr / ghwt start an agent per issue and nothing ever stopped them, so
# every finished ticket kept an agent and its worktree resident. This closes the
# loop: find agents sitting in a worktree whose PR is done, and remove the
# workspace (which stops the agent and deletes the worktree, same as ghwtrm).
#
# Usage: ghreap [-n|--dry-run] [-y|--yes]

# Agents that are safe to consider: in a linked worktree, not this pane, not busy.
# Reads `herdr agent list` JSON on stdin, prints: name<TAB>cwd<TAB>workspace_id
_ghsb_reap_candidates() {
  local pane="${1:-}"
  jq -r --arg pane "$pane" --arg home "$HOME" '
    .result.agents[]
    | select(.pane_id != $pane)
    | select(.agent_status != "working")
    | select(.cwd | startswith($home + "/.herdr/worktrees/") or startswith($home + "/.claude/worktrees/"))
    | [(.name // .agent), .cwd, (.workspace_id // "")] | @tsv
  '
}

ghreap() {
  local dry=false assume_yes=false
  while (( $# )); do
    case "$1" in
      -n|--dry-run) dry=true ;;
      -y|--yes) assume_yes=true ;;
      -h|--help)
        cat <<'EOF'
Usage: ghreap [-n|--dry-run] [-y|--yes]

Stops Herdr agents whose branch has a merged or closed PR — they are done
and only holding memory. The worktree is deleted too when it is clean and
pushed; when it still has uncommitted changes or unpushed commits the files
are kept and only the agent stops.

Skips: this pane, agents still working, and branches with no PR yet.

  -n, --dry-run   List what would be reaped, change nothing
  -y, --yes       Skip the confirmation prompt
EOF
        return 0 ;;
      *) echo "ghreap: unknown flag $1 (see --help)" >&2; return 1 ;;
    esac
    shift
  done

  command -v herdr >/dev/null 2>&1 || { echo "ghreap: herdr not found" >&2; return 1; }
  command -v gh >/dev/null 2>&1 || { echo "ghreap: gh not found" >&2; return 1; }

  local agents
  agents=$(herdr agent list 2>/dev/null) || { echo "ghreap: herdr agent list failed" >&2; return 1; }

  local -a ws_list desc_list act_list
  local name cwd ws branch repo pr state dirty unpushed
  while IFS=$'\t' read -r name cwd ws; do
    [[ -n "$cwd" && -d "$cwd" ]] || continue
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
    [[ -n "$branch" && "$branch" != "HEAD" ]] || continue

    repo=$(git -C "$cwd" remote get-url origin 2>/dev/null \
      | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
    [[ -n "$repo" ]] || continue

    pr=$(gh pr list -R "$repo" --head "$branch" --state all \
      --json number,state --limit 1 2>/dev/null) || continue
    state=$(printf '%s' "$pr" | jq -r '.[0].state // ""')
    case "$state" in
      MERGED|CLOSED) ;;
      *) continue ;;
    esac

    # The agent goes either way — its PR is done, so it is only holding memory.
    # The worktree only goes when nothing would be lost with it.
    dirty=$(git -C "$cwd" status --porcelain 2>/dev/null)
    unpushed=$(git -C "$cwd" log --oneline "@{upstream}..HEAD" 2>/dev/null)
    local why=""
    [[ -n "$dirty" ]] && why="uncommitted changes"
    [[ -n "$unpushed" ]] && why="${why:+$why, }unpushed commits"

    ws_list+=("$ws")
    if [[ -n "$why" ]]; then
      act_list+=("close")
      desc_list+=("${name}  ${state} #$(printf '%s' "$pr" | jq -r '.[0].number')  ${branch} — stop agent, keep worktree (${why})")
    else
      act_list+=("remove")
      desc_list+=("${name}  ${state} #$(printf '%s' "$pr" | jq -r '.[0].number')  ${branch} — stop agent, remove worktree")
    fi
  done < <(_ghsb_reap_candidates "${HERDR_PANE_ID:-}" <<< "$agents")

  if (( ${#ws_list} == 0 )); then
    echo "Nothing to reap."
    return 0
  fi

  echo "Reapable agents (${#ws_list}):"
  printf '  %s\n' "${desc_list[@]}"

  if $dry; then
    echo "(dry run — nothing removed)"
    return 0
  fi
  if ! $assume_yes; then
    local reply
    read -q "reply?Stop these agents and remove their worktrees? [y/N] " || { echo; echo "Aborted."; return 1; }
    echo
  fi

  local i
  for i in {1..${#ws_list}}; do
    if [[ -z "${ws_list[$i]}" ]]; then
      echo "  ! ${desc_list[$i]} — no workspace id, skipped"
      continue
    fi
    if [[ "${act_list[$i]}" == remove ]]; then
      herdr worktree remove --workspace "${ws_list[$i]}" --force >/dev/null 2>&1
    else
      herdr workspace close "${ws_list[$i]}" >/dev/null 2>&1
    fi \
      && echo "  reaped ${desc_list[$i]}" \
      || echo "  ! failed ${desc_list[$i]}"
  done
}
