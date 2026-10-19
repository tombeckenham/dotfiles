# Shared Trello helpers for tri / tris.
# A card URL names the branch by itself: /c/SHORT/196-slug. The shell does
# not read the card to check out that worktree.

_tri_config_file() {
  echo "${GHSB_TRELLO_CONFIG:-$GHSB_HOME/trello.json}"
}

# Fills GHSB_TRELLO_LIST_ID and GHSB_TRELLO_BOARD_ID. Env wins over the file.
_tri_config_load() {
  local f list_id board_id
  f=$(_tri_config_file)
  list_id="${GHSB_TRELLO_LIST:-}"
  board_id="${GHSB_TRELLO_BOARD:-}"
  if [[ -f "$f" ]]; then
    [[ -n "$list_id" ]] || list_id=$(jq -r '.list // empty' "$f" 2>/dev/null) || list_id=""
    [[ -n "$board_id" ]] || board_id=$(jq -r '.board // empty' "$f" 2>/dev/null) || board_id=""
  fi
  GHSB_TRELLO_LIST_ID="$list_id"
  GHSB_TRELLO_BOARD_ID="$board_id"
}

# Inbox lists for tris: the create list, then extra ids in .lists. One per line.
_tri_inbox_lists() {
  local f extra
  _tri_config_load
  [[ -n "${GHSB_TRELLO_LIST_ID:-}" ]] && printf '%s\n' "$GHSB_TRELLO_LIST_ID"
  f=$(_tri_config_file)
  if [[ -f "$f" ]]; then
    extra=$(jq -r '.lists[]? // empty' "$f" 2>/dev/null) || extra=""
    [[ -n "$extra" ]] && printf '%s\n' "$extra"
  fi
}

# Card ref: Trello URL, card number, 24-hex id, or 8-char short link with a digit.
# A bare word such as "deadline" stays a title. A URL returns its short link.
# A number is the digits in /c/SHORT/196-slug.
_tri_card_ref() {
  local raw="$1" short
  [[ -n "$raw" ]] || return 1
  raw=${raw%%\?*}
  raw=${raw%/}
  if [[ "$raw" == \#<-> ]]; then
    printf '%s\n' "${raw#\#}"
    return 0
  fi
  if [[ "$raw" == <-> ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  if [[ "$raw" == *trello.com/c/* ]]; then
    raw=${raw##*trello.com/c/}
    raw=${raw%%/*}
  fi
  if [[ "$raw" =~ '^[0-9a-fA-F]{24}$' ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  if [[ "$raw" =~ '^[A-Za-z0-9]{8}$' && "$raw" == *[0-9]* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  return 1
}

# One card JSON object from a URL, short link, or card number. No Trello call.
# The branch name is the short link plus the URL slug.
_tri_card_json_from_ref() {
  local raw="$1" tail short="" rest="" num="" slug="" url="" name=""
  [[ -n "$raw" ]] || return 1
  raw=${raw%%\?*}
  raw=${raw%/}
  if [[ "$raw" == *trello.com/c/* ]]; then
    tail=${raw##*trello.com/c/}
    short=${tail%%/*}
    rest=${tail#*/}
    [[ "$rest" == "$tail" ]] && rest=""
    url="https://trello.com/c/${tail}"
  elif [[ "$raw" == \#<-> || "$raw" == <-> ]]; then
    num=${raw#\#}
    short="$num"
    name="card-${num}"
  else
    short=$(_tri_card_ref "$raw") || {
      echo "Not a Trello card ref: $raw" >&2
      return 1
    }
    url="https://trello.com/c/${short}"
  fi
  if [[ -n "$rest" ]]; then
    if [[ "$rest" == <->-* ]]; then
      num=${rest%%-*}
      slug=$(_tri_slug "${rest#*-}")
    elif [[ "$rest" == <-> ]]; then
      num=$rest
    else
      slug=$(_tri_slug "$rest")
    fi
  fi
  [[ -n "$slug" ]] && name="$slug"
  [[ -n "$name" ]] || name="$short"
  [[ -n "$num" ]] || num=0
  jq -nc \
    --arg short "$short" \
    --arg name "$name" \
    --arg url "$url" \
    --argjson num "$num" \
    '{id:"", shortLink:$short, name:$name, url:$url, idShort:$num, desc:"", closed:false, members:[]}'
}

# Card number from a trello.com/c/SHORT/196-slug URL, or empty.
_tri_card_number() {
  local raw="$1" n
  [[ -n "$raw" ]] || return 1
  raw=${raw%%\?*}
  n=${raw##*trello.com/c/*/}
  n=${n%%-*}
  n=${n%%/*}
  if [[ "$n" == <-> ]]; then
    printf '%s\n' "$n"
    return 0
  fi
  return 1
}

_tri_slug() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-48
}

# Stable agent-pool seed from a short link (not its length).
_tri_ai_seed() {
  local s="$1" i c n=0
  for (( i = 1; i <= $#s; i++ )); do
    c=$(printf '%d' "'${s[i]}")
    n=$(( n + c ))
  done
  echo "$n"
}

# Normalize a Trello MCP card, or a list of them, to one JSON object per card.
_tri_normalize_cards() {
  jq -c '
    def as_text:
      if type == "object" then (.text // .content // .markdown // .value // "")
      elif type == "string" then .
      elif type == "null" then ""
      else "" end;
    def member_ids:
      [ (.idMembers // .memberIds // [])[]
        , (if (.members | type) == "array" then
            .members[] | if type == "object" then (.id // .memberId // empty) else . end
          else empty end)
        , (if (.members | type) == "object" then
            ((.members.edges // .members.nodes // [])[] | (.node.id // .id // empty))
          else empty end)
      ] | map(select(type == "string" and length > 0)) | unique;
    def one:
      {
        id: (.id // ""),
        short: (
          .shortLink // .shortlink // .short_link
          // (try ((.shortUrl // .url // "") | capture("trello\\.com/c/(?<s>[A-Za-z0-9]+)").s) catch empty)
          // ""
        ),
        name: (.name // .title // ""),
        desc: ((.desc // .description // "") | as_text),
        url: (.shortUrl // .url // ""),
        closed: ((.closed // .isClosed // false) == true),
        id_short: (
          if (.idShort // .id_short) != null then (.idShort // .id_short)
          elif ((.url // .shortUrl // "") | test("trello\\.com/c/[A-Za-z0-9]+/[0-9]+")) then
            ((.url // .shortUrl) | capture("trello\\.com/c/[A-Za-z0-9]+/(?<n>[0-9]+)").n | tonumber)
          else 0
          end
        ),
        members: member_ids,
        has_members: (has("idMembers") or has("memberIds") or has("members"))
      };
    def nodes:
      if type == "array" then .
      elif .data.cards? then .data.cards
      elif .data.nodes? then .data.nodes
      elif .data.items? then .data.items
      elif .data.edges? then [.data.edges[].node]
      elif (.lists | type) == "array" then [ .lists[] | (.cards // [])[] ]
      elif .cards.nodes? then .cards.nodes
      elif .cards? then .cards
      elif .nodes? then .nodes
      elif (.data | type) == "array" then .data
      elif (.data | type) == "object" and (.data | has("id") or has("shortLink") or has("name")) then [.data]
      elif has("id") or has("shortLink") or has("name") then [.]
      else [] end;
    nodes
    | map(if type == "object" and has("node") and (.node | type) == "object" then .node else . end)
    | map(one)
    | .[]
  '
}

# stdin: normalized cards (JSONL). $1 is the current member id.
# TSV: id_short, short, name, url, ready, closed, mine, id
_tri_rows_for_me() {
  local me="$1"
  jq -r --arg me "$me" '
    [
      (.id_short // 0),
      (.short // ""),
      (.name // ""),
      (.url // ""),
      (if ((.desc // "") | test("\\S")) then "yes" else "no" end),
      (if .closed == true then "yes" else "no" end),
      (if .has_members | not then "unknown"
       elif ([.members[]?] | index($me)) != null then "yes"
       else "no" end),
      (.id // "")
    ] | @tsv
  '
}

# $1 short link, remaining args are existing branch names.
# Prints the branch to use, or NEW. Returns 2 when GHSB_YES must not choose.
_tri_choose_branch() {
  local short="$1" explicit="${2:-}"
  shift 2
  local -a matches=("$@")
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if (( ${#matches[@]} == 1 )); then
    printf '%s\n' "${matches[1]}"
    return 0
  fi
  if (( ${#matches[@]} > 1 )); then
    echo "Found multiple branches for card ${short}:" >&2
    local b i reply
    i=1
    for b in "${matches[@]}"; do
      echo "  [$i] $b" >&2
      i=$((i + 1))
    done
    if [[ -t 0 && -z "${GHSB_YES:-}" ]]; then
      printf "Select [1-%d, or n for new]: " "${#matches[@]}" >&2
      read -r reply
      if [[ "$reply" == <-> ]] && (( reply >= 1 && reply <= ${#matches[@]} )); then
        printf '%s\n' "${matches[$reply]}"
        return 0
      fi
      echo "NEW"
      return 0
    fi
    echo "Will not pick among ${#matches[@]} branches. Run: tri --card ${short} -b <branch>" >&2
    return 2
  fi
  echo "NEW"
}

# Session files in this repo whose trello_card is <short> and that have no PR.
_tri_card_session_files() {
  local short="$1" repo_root repo_name f canonical
  [[ -n "$short" ]] || return 1
  repo_root=$(_ghsb_repo_root) || return 1
  repo_name=$(basename "$repo_root")
  _ghsb_init_dirs
  canonical="$(_ghsb_session_path "${repo_name}-c-${short}")"
  if [[ -f "$canonical" ]] && jq -e '.pr == null or .pr == ""' "$canonical" >/dev/null 2>&1; then
    printf '%s\n' "$canonical"
  fi
  for f in "$GHSB_SESSIONS_DIR"/*.json(N); do
    [[ "$f" == "$canonical" ]] && continue
    jq -e --arg n "$short" --arg prefix "${repo_name}-" \
      '((.trello_card // "") == $n) and ((.id // "") | startswith($prefix)) and (.pr == null or .pr == "")' \
      "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
  done
  return 0
}

# skip / reopen / new for one card. Same workspace rule as ghis.
# Args: short, live workspace ids, open worktrees (branch, path, workspace).
_tri_card_start_action() {
  local short="$1" live_ids="$2" open_wts="$3"
  local obr open_path ow files f ws wt repo_root repo_name line git_path=""
  local have_dir=false
  local prefix="branch refs/heads/${short}-"

  if [[ -n "$open_wts" ]]; then
    while IFS=$'\t' read -r obr open_path ow; do
      [[ "$obr" == ${short}-* ]] || continue
      if _ghsb_id_listed "$ow" "$live_ids"; then
        echo skip
        return 0
      fi
      [[ -n "$open_path" && -d "$open_path" ]] && have_dir=true
    done <<< "$open_wts"
  fi

  files=$(_tri_card_session_files "$short") || files=""
  if [[ -n "$files" ]]; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      ws=$(jq -r '.herdr_workspace // empty' "$f")
      if _ghsb_id_listed "$ws" "$live_ids"; then
        echo skip
        return 0
      fi
      wt=$(jq -r '.worktree // empty' "$f")
      [[ -n "$wt" && -d "$wt" ]] && have_dir=true
    done <<< "$files"
  fi

  repo_root=$(_ghsb_repo_root) || { echo new; return 0; }
  repo_name=$(basename "$repo_root")
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      git_path="${line#worktree }"
    elif [[ "$line" == "$prefix"* && -n "$git_path" && -d "$git_path" ]]; then
      have_dir=true
    fi
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)

  if $have_dir; then
    echo reopen
  else
    echo new
  fi
}

# Next page cursor, or empty. Trello MCP list_by_board uses hasNextPage/nextCursor.
_tri_page_after() {
  jq -r '
    if (.data.pageInfo.hasNextPage // .pageInfo.hasNextPage // .hasNextPage) == true
    then (.data.pageInfo.endCursor // .pageInfo.endCursor // .nextCursor // .after // empty)
    else empty end
  '
}
