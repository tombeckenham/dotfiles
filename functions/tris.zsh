# tris — start an agent for Trello cards assigned to me
# Usage: tris [--dry-run] [--max N] [--list ID]
#
# From the repo root Herdr space. The agent writes one card JSON object per
# line and passes --me. Skips a card when its workspace is still open, when
# it is archived, or when the description is empty.
tris() {
  local dry_run=false max=5 cards_file="" me=""
  local -a extra_lists=()

  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      --max)
        shift
        max="${1:-}"
        [[ "$max" == <-> && "$max" -ge 1 ]] || {
          echo "tris: --max needs a positive number" >&2
          return 1
        }
        shift
        ;;
      --list)
        extra_lists+=("$2")
        shift 2
        ;;
      --cards)
        cards_file="$2"
        shift 2
        ;;
      --me)
        me="$2"
        shift 2
        ;;
      -h|--help)
        _tris_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _tris_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane tris || return 1

  if [[ -z "$cards_file" ]]; then
    echo "tris does not call Trello. In Grok, run /tris." >&2
    return 2
  fi
  [[ -f "$cards_file" ]] || {
    echo "No card file: $cards_file" >&2
    return 1
  }
  [[ -n "$me" ]] || {
    echo "tris --cards needs --me <member ARI from trelloReadMember get_me>" >&2
    return 1
  }

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

  local -a rows=()
  local seen=" " row short line
  typeset -A tri_card_json
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      short=$(jq -r '.short // empty' <<< "$row")
      [[ -n "$short" ]] || continue
      [[ "$seen" == *" $short "* ]] && continue
      seen+=" $short "
      rows+=("$row")
      tri_card_json[$short]="$row"
    done < <(printf '%s\n' "$line" | _tri_normalize_cards)
  done < "$cards_file"

  local -a classified=()
  if (( ${#rows[@]} )); then
    while IFS= read -r row; do
      [[ -n "$row" ]] && classified+=("$row")
    done < <(printf '%s\n' "${rows[@]}" | _tri_rows_for_me "$me")
  fi

  local -a start=() skip=() empty=() other=()
  local n name url ready closed mine action rest parts
  for row in "${classified[@]}"; do
    parts=$(_tris_parts "$row")
    n=${parts%%	*}
    rest=${parts#*	}
    short=${rest%%	*}
    rest=${rest#*	}
    name=${rest%%	*}
    rest=${rest#*	}
    url=${rest%%	*}
    rest=${rest#*	}
    ready=${rest%%	*}
    rest=${rest#*	}
    closed=${rest%%	*}
    mine=${rest#*	}
    if [[ "$closed" == yes ]]; then
      continue
    fi
    if [[ "$mine" != yes ]]; then
      other+=("$n	$short	$name	$url")
      continue
    fi
    if [[ "$ready" != yes ]]; then
      empty+=("$n	$short	$name	$url")
      continue
    fi
    action=$(_tri_card_start_action "$short" "$live_ids" "$open_wts")
    if [[ "$action" == skip ]]; then
      skip+=("$n	$short	$name	$url")
    else
      start+=("$n	$short	$name	$url	$action")
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

  echo "Assigned cards: $(( ${#start[@]} + ${#later[@]} + ${#skip[@]} + ${#empty[@]} ))  start: ${#start[@]}  later: ${#later[@]}  skip (workspace open): ${#skip[@]}  skip (empty description): ${#empty[@]}  other: ${#other[@]}"
  if (( ${#skip[@]} )); then
    echo "Skip (workspace open):"
    for row in "${skip[@]}"; do
      rest=${row#*	}
      short=${rest%%	*}
      rest=${rest#*	}
      name=${rest%%	*}
      echo "  $short  $name"
    done
  fi
  if (( ${#empty[@]} )); then
    echo "Skip (empty description):"
    for row in "${empty[@]}"; do
      rest=${row#*	}
      short=${rest%%	*}
      rest=${rest#*	}
      name=${rest%%	*}
      echo "  $short  $name"
    done
  fi
  if (( ${#start[@]} == 0 )); then
    echo "Nothing to start."
    return 0
  fi
  echo "Start:"
  for row in "${start[@]}"; do
    rest=${row#*	}
    short=${rest%%	*}
    rest=${rest#*	}
    name=${rest%%	*}
    action=${row##*	}
    case "$action" in
      reopen) echo "  $short  $name  (reopen worktree)" ;;
      *) echo "  $short  $name  (new worktree)" ;;
    esac
  done
  if (( ${#later[@]} )); then
    echo "Later:"
    for row in "${later[@]}"; do
      rest=${row#*	}
      short=${rest%%	*}
      rest=${rest#*	}
      name=${rest%%	*}
      echo "  $short  $name"
    done
  fi

  if $dry_run; then
    echo "Dry run; not starting agents."
    return 0
  fi

  local failed=0
  for row in "${start[@]}"; do
    rest=${row#*	}
    short=${rest%%	*}
    echo ""
    echo "=== tri --no-focus --card-json $short ==="
    local card_file
    card_file=$(mktemp)
    printf '%s\n' "${tri_card_json[$short]}" > "$card_file"
    if ! GHSB_YES=1 tri --no-focus --card-json "$card_file"; then
      rm -f "$card_file"
      echo "tri $short failed" >&2
      failed=$((failed + 1))
    else
      rm -f "$card_file"
    fi
  done

  echo ""
  echo "Started $(( ${#start[@]} - failed )) card agent(s). Failed: $failed"
  echo "This pane stayed on the repo root. Switch to a card space to watch one."
  (( failed == 0 ))
}

# TSV from _tri_rows_for_me: id_short, short, name, url, ready, closed, mine, id
# Prints the same row without the trailing id, so the last field is mine.
_tris_parts() {
  local row="$1" rest id_short short name url ready closed mine
  id_short=${row%%	*}
  rest=${row#*	}
  short=${rest%%	*}
  rest=${rest#*	}
  name=${rest%%	*}
  rest=${rest#*	}
  url=${rest%%	*}
  rest=${rest#*	}
  ready=${rest%%	*}
  rest=${rest#*	}
  closed=${rest%%	*}
  rest=${rest#*	}
  mine=${rest%%	*}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id_short" "$short" "$name" "$url" "$ready" "$closed" "$mine"
}

_tris_help() {
  cat <<'EOF'
tris — start agents for Trello cards assigned to you

Run from the repo root Herdr space. tris does not call Trello. The agent
lists the cards, then passes them here. Skips a card whose Herdr workspace
is still open, and skips a card with an empty description. Starts the
lowest card number first. The default batch is 5.

  tris --cards FILE --me MEMBER_ARI [--dry-run] [--max N]
  tri cards --cards FILE --me MEMBER_ARI

FILE is one Trello MCP card object per line. MEMBER_ARI is the id from
trelloReadMember action get_me. A card number is the digits in
/c/SHORT/196-slug.

Flags:
  --cards FILE Card JSONL from the Trello MCP
  --me ARI     Your Trello member id
  --dry-run    Print start/skip lists only
  --max N      Start at most N cards (default 5)
  --list ID    Ignored. The agent chooses the lists
EOF
}
