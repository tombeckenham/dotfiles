# ghis — start an agent for every open issue assigned to me that has no PR
# Usage: ghis [--dry-run] [--max N] [--all]
#
# From the repo root Herdr space. Skips an issue when its workspace is still
# open, or when the issue body is empty. Otherwise runs ghi --no-focus.
# --all lists every open issue in the repo, not only ones assigned to you.
ghis() {
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
          echo "ghis: --max needs a positive number" >&2
          return 1
        }
        shift
        ;;
      -h|--help)
        _ghis_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _ghis_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane ghis || return 1

  local repo_root listing live_ids wt_listing open_wts issues
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
  list_args=("${(@f)$(_ghis_list_args "$all")}")
  issues=$("$(_ghsb_forge)" issue list "${list_args[@]}" 2>&1) || {
    echo "$(_ghsb_forge) issue list failed: $issues" >&2
    return 1
  }

  local -a rows=()
  local row
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(_ghis_select "$issues")

  local scope="Assigned issues" none="No open issues assigned to you without a pull request."
  if $all; then
    scope="Open issues"
    none="No open issues without a pull request."
  fi

  if (( ${#rows[@]} == 0 )); then
    echo "$none"
    return 0
  fi

  local -a start=() skip=() empty=()
  local n title url ready action
  for row in "${rows[@]}"; do
    n=${row%%	*}
    row=${row#*	}
    title=${row%%	*}
    row=${row#*	}
    url=${row%%	*}
    ready=${row##*	}
    if [[ "$ready" != yes ]]; then
      empty+=("$n	$title	$url")
      continue
    fi
    action=$(_ghsb_issue_start_action "$n" "$live_ids" "$open_wts")
    if [[ "$action" == skip ]]; then
      skip+=("$n	$title	$url")
    else
      start+=("$n	$title	$url	$action")
    fi
  done

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

  echo "$scope without a PR: ${#rows[@]}  start: ${#start[@]}  later: ${#later[@]}  skip (workspace open): ${#skip[@]}  skip (empty body): ${#empty[@]}"
  local rest
  if (( ${#skip[@]} )); then
    echo "Skip (workspace open):"
    for row in "${skip[@]}"; do
      n=${row%%	*}
      rest=${row#*	}
      title=${rest%%	*}
      echo "  #$n  $title"
    done
  fi
  if (( ${#empty[@]} )); then
    echo "Skip (empty body):"
    for row in "${empty[@]}"; do
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
    action=${row##*	}
    case "$action" in
      reopen) echo "  #$n  $title  (reopen worktree)" ;;
      *) echo "  #$n  $title  (new worktree)" ;;
    esac
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
    echo "=== $(_ghsb_user_cmd ghi) --no-focus -i $n ==="
    if ! GHSB_YES=1 ghi --no-focus -i "$n"; then
      echo "$(_ghsb_user_cmd ghi) $n failed" >&2
      failed=$((failed + 1))
    fi
  done

  echo ""
  echo "Started $(( ${#start[@]} - failed )) issue agent(s). Failed: $failed"
  echo "This pane stayed on the repo root. Switch to an issue space to watch one."
  (( failed == 0 ))
}

# gh issue list arguments. "true" drops --assignee @me.
_ghis_list_args() {
  local -a args=(
    --state open
    --limit 100
    --search "-linked:pr sort:created-asc"
    --json number,title,url,body,closedByPullRequestsReferences
  )
  if [[ "$1" != true ]]; then
    args=(--assignee @me "${args[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

# Print number, title, url, and yes/no for issues that have no pull request.
# Empty-body issues are included with "no" so the caller can skip them.
_ghis_select() {
  jq -r '
    .[]
    | select((.closedByPullRequestsReferences // []) | length == 0)
    | [ .number, .title, .url,
        (if ((.body // "") | test("\\S")) then "yes" else "no" end) ]
    | @tsv
  ' <<< "$1"
}

_ghis_help() {
  cat <<'EOF'
ghis — start agents for open issues that have no pull request

Run from the repo root Herdr space. Lists open issues assigned to you
that GitHub does not link to a pull request. --all lists every open
issue in the repo. Skips an issue whose Herdr workspace is still open,
and skips an issue with an empty body. Starts the rest lowest number
first. The default batch is 5. Each start is ghi --no-focus -i N.
Does not steal this pane's focus.

  ghis [--dry-run] [--max N] [--all]
  ghi issues [--dry-run] [--max N] [--all]

Flags:
  --dry-run    Print start/skip lists only
  --max N      Start at most N issues (default 5)
  --all        Every open issue, not only ones assigned to you
EOF
}
