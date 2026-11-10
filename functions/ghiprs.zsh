# ghiprs — ghipr every open PR assigned to me whose Herdr workspace is closed
# Usage: ghiprs [--dry-run] [--max N] [--all]
#
# From the repo root Herdr space. Skips a PR when its review workspace is
# still open. Otherwise reopens the worktree if it is on disk, or creates
# one, and starts a review agent. Does not focus those spaces.
# --all lists every open PR in the repo, not only ones assigned to you.
ghiprs() {
  local dry_run=false max=5 all=false

  while [[ "$1" == -* ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      --all)
        all=true
        shift
        ;;
      --max)
        shift
        max="${1:-}"
        [[ "$max" == <-> && "$max" -ge 1 ]] || {
          echo "ghiprs: --max needs a positive number" >&2
          return 1
        }
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

  local repo_root listing live_ids wt_listing open_wts
  repo_root=$(_ghsb_repo_root) || return 1
  listing=$(herdr workspace list 2>&1) || {
    echo "herdr workspace list failed: $listing" >&2
    return 1
  }
  live_ids=$(printf '%s\n' "$listing" | jq -r '.result.workspaces[]?.workspace_id // empty') || {
    echo "herdr workspace list was not JSON" >&2
    return 1
  }
  wt_listing=$(_ghsb_herdr_wt_list "$repo_root") || wt_listing=""
  open_wts=""
  if [[ -n "$wt_listing" ]]; then
    open_wts=$(printf '%s\n' "$wt_listing" | jq -r '
      .result.worktrees[]?
      | select((.open_workspace_id // "") != "")
      | "\(.branch // "")\t\(.path)\t\(.open_workspace_id)"
    ') || open_wts=""
  fi

  local -a list_args=()
  list_args=("${(@f)$(_ghiprs_list_args "$all")}")
  local prs
  prs=$("$(_ghsb_forge)" pr list "${list_args[@]}" 2>&1) || {
    echo "$(_ghsb_forge) pr list failed: $prs" >&2
    return 1
  }

  local scope="Assigned open PRs" none="No open PRs assigned to you in this repo."
  if $all; then
    scope="Open PRs"
    none="No open PRs in this repo."
  fi

  local count
  count=$(printf '%s\n' "$prs" | jq 'length')
  if [[ "$count" == "0" ]]; then
    echo "$none"
    return 0
  fi

  local -a start=() skip=()
  local n title url draft branch action note
  while IFS=$'\t' read -r n title url draft branch; do
    [[ -n "$n" ]] || continue
    action=$(_ghsb_pr_review_action "$n" "$branch" "$live_ids" "$open_wts")
    if [[ "$action" == skip ]]; then
      skip+=("$n	$title	$url")
    else
      start+=("$n	$title	$url	$draft	$action")
    fi
  done < <(printf '%s\n' "$prs" | jq -r '.[] | [.number, .title, .url, (.isDraft|tostring), .headRefName] | @tsv')

  local -a ordered=() later=()
  if (( ${#start[@]} )); then
    ordered=("${(@f)$(_ghsb_rows_by_number "${start[@]}")}")
  fi
  if (( ${#ordered[@]} > max )); then
    later=("${ordered[@]:$max}")
    start=("${ordered[@]:0:$max}")
  else
    start=("${ordered[@]}")
  fi

  echo "$scope: $count  start: ${#start[@]}  later: ${#later[@]}  skip (workspace open): ${#skip[@]}"
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
    rest=${rest#*	}
    rest=${rest#*	}
    action=${rest#*	}
    case "$action" in
      reopen) note="reopen worktree" ;;
      *) note="new worktree" ;;
    esac
    echo "  #$n  $title  ($note)"
  done
  if (( ${#later[@]} )); then
    echo "Later:"
    for row in "${later[@]}"; do
      n=${row%%	*}
      rest=${row#*	}
      title=${rest%%	*}
      echo "  #$n  $title"
    done
  fi

  if $dry_run; then
    echo "Dry run; not starting agents."
    return 0
  fi

  local failed=0
  for row in "${start[@]}"; do
    n=${row%%	*}
    echo ""
    echo "=== $(_ghsb_user_cmd ghipr) --no-focus $n ==="
    if ! ghipr --no-focus "$n"; then
      echo "$(_ghsb_user_cmd ghipr) $n failed" >&2
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "Started $(( ${#start[@]} - failed )) review(s). Failed: $failed"
  echo "This pane stayed on the repo root. Switch to a pr-N space to watch a review."
  (( failed == 0 ))
}

# gh/src pr list arguments. "true" drops --assignee @me.
_ghiprs_list_args() {
  local -a args=(
    --state open
    --limit 100
    --search "sort:created-asc"
    --json number,title,url,isDraft,headRefName
  )
  if [[ "$1" != true ]]; then
    args=(--assignee @me "${args[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

_ghiprs_help() {
  cat <<'EOF'
ghiprs — review open PRs whose Herdr workspace is closed

Run from the repo root Herdr space. Lists open PRs assigned to you.
--all lists every open PR in the repo. Skips one whose review workspace
is still open, and starts the rest lowest number first. The default
batch is 5. Run it again for the next batch. Each start is
ghipr --no-focus. Does not steal this pane's focus.

  ghiprs [--dry-run] [--max N] [--all]

Flags:
  --dry-run    Print start/skip lists only
  --max N      Start at most N reviews (default 5)
  --all        Every open PR, not only ones assigned to you
EOF
}
