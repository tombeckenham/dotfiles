# ghiprs — ghipr every open PR assigned to me that has no ghsb session
# Usage: ghiprs [--dry-run]
#
# From the repo root Herdr space. Creates a worktree and starts a review
# agent per PR. Does not focus those spaces, so this pane stays put.
ghiprs() {
  local dry_run=false

  while [[ "$1" == -* ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      -h|--help)
        _ghiprs_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghiprs_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane ghiprs || return 1

  local prs
  prs=$(gh pr list --assignee @me --state open \
    --json number,title,url,isDraft 2>&1) || {
    echo "gh pr list failed: $prs" >&2
    return 1
  }

  local count
  count=$(printf '%s\n' "$prs" | jq 'length')
  if [[ "$count" == "0" ]]; then
    echo "No open PRs assigned to you in this repo."
    return 0
  fi

  local -a start=() skip=()
  local n title url draft
  while IFS=$'\t' read -r n title url draft; do
    [[ -n "$n" ]] || continue
    if _ghsb_pr_session_exists "$n"; then
      skip+=("$n	$title	$url")
    else
      start+=("$n	$title	$url	$draft")
    fi
  done < <(printf '%s\n' "$prs" | jq -r '.[] | [.number, .title, .url, (.isDraft|tostring)] | @tsv')

  echo "Assigned open PRs: $count  start: ${#start[@]}  skip (session exists): ${#skip[@]}"
  local row rest
  if (( ${#skip[@]} )); then
    echo "Skip:"
    for row in "${skip[@]}"; do
      n=${row%%	*}
      rest=${row#*	}
      title=${rest%%	*}
      echo "  #$n  $title"
    done
  fi
  if (( ${#start[@]} == 0 )); then
    echo "Nothing to start."
    return 0
  fi
  echo "Start:"
  for row in "${start[@]}"; do
    n=${row%%	*}
    rest=${row#*	}
    title=${rest%%	*}
    echo "  #$n  $title"
  done

  if $dry_run; then
    echo "Dry run; not starting agents."
    return 0
  fi

  local failed=0
  for row in "${start[@]}"; do
    n=${row%%	*}
    echo ""
    echo "=== ghipr --no-focus $n ==="
    if ! ghipr --no-focus "$n"; then
      echo "ghipr $n failed" >&2
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "Started $(( ${#start[@]} - failed )) review(s). Failed: $failed"
  echo "This pane stayed on the repo root. Switch to a pr-N space to watch a review."
  (( failed == 0 ))
}

_ghiprs_help() {
  cat <<'EOF'
ghiprs — review every assigned open PR that has no session

Run from the repo root Herdr space. For each open PR assigned to you
(gh pr list --assignee @me) that does not already have a ghsb session
({repo}-pr-{N} or any {repo}-* session with that PR number), runs
ghipr --no-focus: worktree + reviewr + review agent. Does not steal
this pane's focus, so several reviews can start from one command.

  ghiprs [--dry-run]

Flags:
  --dry-run    Print start/skip lists only
EOF
}
