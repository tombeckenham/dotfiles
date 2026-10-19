# tri — start Trello card work from a Herdr pane (repo root space)
# Usage: tri [--card REF] [-c] [-b BRANCH] [--desc TEXT] [--no-agent] "Card name"
#        tri cards […]     # same as tris
#        tri branch […]    # same as ghb (no card)
#        tri config …
#
# Creates a Herdr worktree grouped under the repo and starts the agent there.
# A card URL supplies the branch name. The shell does not read the card.
tri() {
  case "${1:-}" in
    cards)
      shift
      tris "$@"
      return $?
      ;;
    branch)
      shift
      ghb "$@"
      return $?
      ;;
    config)
      shift
      _tri_config "$@"
      return $?
      ;;
  esac

  local base_branch="" branch_name="" card_ref="" card_json_file="" list_id="" board_id="" desc=""
  local no_agent=false no_focus=false want_video=false want_review=false

  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -c|--current)
        base_branch=$(git branch --show-current)
        shift
        ;;
      -b|--branch)
        branch_name="$2"
        shift 2
        ;;
      --card)
        card_ref="$2"
        shift 2
        ;;
      --card-json)
        card_json_file="$2"
        shift 2
        ;;
      --desc)
        desc="$2"
        shift 2
        ;;
      --list)
        list_id="$2"
        shift 2
        ;;
      --board)
        board_id="$2"
        shift 2
        ;;
      --no-agent)
        no_agent=true
        shift
        ;;
      --no-focus)
        no_focus=true
        shift
        ;;
      --video)
        want_video=true
        shift
        ;;
      --review-fix|--review)
        want_review=true
        shift
        ;;
      -h|--help)
        _tri_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        _tri_help
        return 1
        ;;
    esac
  done

  _ghsb_require_herdr_pane tri || return 1

  local title="$*" ref=""
  if [[ -z "$card_ref" && -n "$title" ]]; then
    ref=$(_tri_card_ref "$title" 2>/dev/null) || ref=""
    if [[ -n "$ref" && "$title" != *" "* ]]; then
      card_ref="$title"
      title=""
    fi
  fi

  local card_json short name url card_id ready from_url=false
  if [[ -n "$card_json_file" ]]; then
    [[ -f "$card_json_file" ]] || {
      echo "No card file: $card_json_file" >&2
      return 1
    }
    card_json=$(<"$card_json_file")
  elif [[ -n "$card_ref" ]]; then
    card_json=$(_tri_card_json_from_ref "$card_ref") || return 1
    from_url=true
  else
    [[ -n "$title" ]] || {
      echo "Usage: tri --card-json FILE"
      return 1
    }
    echo "tri does not create Trello cards. In Grok, run /tri and give it the title and description." >&2
    return 2
  fi

  local record
  record=$(printf '%s\n' "$card_json" | _tri_normalize_cards | head -n 1)
  [[ -n "$record" ]] || {
    echo "Card file had no Trello card" >&2
    return 1
  }
  short=$(jq -r '.short // empty' <<< "$record")
  name=$(jq -r '.name // empty' <<< "$record")
  url=$(jq -r '.url // empty' <<< "$record")
  card_id=$(jq -r '.id // empty' <<< "$record")
  ready=$(jq -r 'if ((.desc // "") | test("\\S")) then "yes" else "no" end' <<< "$record")
  [[ -n "$short" ]] || short="$ref"
  [[ -n "$url" && -n "$short" ]] || url="https://trello.com/c/${short}"

  local -a existing=()
  local hit
  if [[ -z "$branch_name" ]]; then
    while IFS= read -r hit; do
      [[ -n "$hit" ]] && existing+=("$hit")
    done < <(git ls-remote --heads origin 2>/dev/null \
      | grep -E "refs/heads/${short}-[a-z0-9-]+$" \
      | sed 's#.*refs/heads/##')
    branch_name=$(_tri_choose_branch "$short" "" "${existing[@]}") || return 1
    if [[ "$branch_name" == NEW ]]; then
      local slug
      slug=$(_tri_slug "${name:-card}")
      [[ -n "$slug" ]] || slug="card"
      branch_name="${short}-${slug}"
    fi
  fi

  _ghsb_parse_branch_args tri "$branch_name" || return 1
  _ghsb_checkout_branch tri "$base_branch" || return 1

  local repo_root repo_name session_id
  repo_root=$(_ghsb_repo_root) || return 1
  repo_name=$(basename "$repo_root")
  session_id="${repo_name}-c-${short}"
  GHSB_CHECKOUT[session_id]="$session_id"
  GHSB_CHECKOUT[issue]="$short"

  branch_name="${GHSB_CHECKOUT[branch]}"
  local worktree_path="${GHSB_CHECKOUT[worktree]}"
  local issue_repo="${GHSB_CHECKOUT[repo]}"
  local origin_repo="${GHSB_CHECKOUT[origin]}"
  local default_branch="${GHSB_CHECKOUT[default_branch]}"

  local ai_tool
  ai_tool=$(_ghsb_pick_ai "$(_tri_ai_seed "$short")")

  local session_json
  session_json=$(jq -n \
    --arg id "$session_id" \
    --arg card "$short" \
    --arg card_id "$card_id" \
    --arg card_url "$url" \
    --arg branch "$branch_name" \
    --arg repo "$issue_repo" \
    --arg origin "$origin_repo" \
    --arg worktree "$worktree_path" \
    --arg ai "$ai_tool" \
    --arg base "$default_branch" \
    --arg pane "${GHSB_CHECKOUT[herdr_pane]:-${HERDR_PANE_ID}}" \
    --arg workspace "${GHSB_CHECKOUT[herdr_workspace]:-${HERDR_WORKSPACE_ID}}" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      issue: null,
      pr: null,
      trello_card: $card,
      trello_id: $card_id,
      trello_url: $card_url,
      branch: $branch,
      repo: $repo,
      origin: $origin,
      worktree: $worktree,
      backend: "local",
      ai_tool: $ai,
      base_branch: $base,
      sandbox_id: "",
      preview_url: "",
      dev_url: "",
      terminal_url: "",
      herdr_pane: $pane,
      herdr_agent: "",
      herdr_workspace: $workspace,
      review_pane: "",
      review_agent: "",
      created_at: $created,
      finished_at: null
    }')
  _ghsb_write_session "$session_id" "$session_json"

  echo "Card:     ${url}"
  echo "Worktree: $worktree_path"
  echo "Session:  $session_id"

  local skip_agent=false
  if $no_agent; then
    skip_agent=true
  elif [[ "$from_url" != true && "$ready" != yes ]]; then
    skip_agent=true
    echo "Card ${short} has an empty description; worktree is ready, agent not started."
    echo "Fill the card, then: tri --card ${url}"
  fi
  if $skip_agent; then
    if ! $no_focus; then
      _ghsb_focus_worktree_if_other "$(_ghsb_issue_space_label "$session_id")" \
        || cd "$worktree_path" || return 1
    fi
    _ghsb_open_reviewr "${GHSB_CHECKOUT[herdr_pane]:-}" "$worktree_path" \
      "${GHSB_CHECKOUT[herdr_workspace]:-}"
    $no_agent && echo "No agent (--no-agent)."
    return 0
  fi

  local ai_prompt
  ai_prompt=$(_tri_implement_prompt "$short" "$name" "$url" "$branch_name" "$session_id" "$ai_tool" "$want_video" "$want_review")
  local -a launch_flags=()
  $no_focus && launch_flags+=(--no-focus)
  _ghsb_launch_in_current_space "tri-${short}" "$worktree_path" "$ai_tool" "$ai_prompt" "$session_id" "${launch_flags[@]}"
  echo "When done: push + PR. Optional: ghsb finish [--video] [--review-fix] $session_id"
}

_tri_implement_prompt() {
  local short="$1" name="$2" url="$3" branch_name="$4" session_id="$5"
  local ai_tool="${6:-}"
  local want_video="${7:-false}" want_review="${8:-false}"
  local review_skill
  review_skill="$(_ghsb_review_cmd "$ai_tool" "<pr-number>")"
  local wrap step=3
  wrap="When implementation is complete:
1. Push the branch
2. Open a PR if one does not exist (gh pr create). Put ${url} in the PR body."
  if [[ "$want_video" == true ]]; then
    wrap+=$'\n'"${step}. Run: ghsb finish --video ${session_id}
   Records a Playwright walkthrough if UI files changed. Stay in this session."
    step=$((step + 1))
  fi
  if [[ "$want_review" == true ]]; then
    wrap+=$'\n'"${step}. ${review_skill}
   Fix any issues you find. Stay in this session — do not start another agent."
  fi
  printf '%s\n' "Implement Trello card ${short} (${name}).
Card: ${url}
Read it with the Trello MCP tool trelloReadCard, action get, cardIdOrUrl set to that URL.
Do not pass the URL to a write tool. Use the card id (ARI) from that read.
If the description is empty, ask what to accomplish before coding, then update the card with trelloWriteCard action update.

Work in this worktree. Commit on branch ${branch_name} and push to origin regularly.

${wrap}"
}

_tri_config() {
  local list_id="" board_id="" add_list=""
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      --list)
        list_id="$2"
        shift 2
        ;;
      --board)
        board_id="$2"
        shift 2
        ;;
      --add-list)
        add_list="$2"
        shift 2
        ;;
      -h|--help)
        _tri_help
        return 0
        ;;
      *)
        echo "Unknown option: $1"
        return 1
        ;;
    esac
  done

  _ghsb_init_dirs
  local f
  f=$(_tri_config_file)
  if [[ -n "$list_id" || -n "$board_id" || -n "$add_list" ]]; then
    local current="{}"
    [[ -f "$f" ]] && current=$(cat "$f")
    jq -n \
      --argjson cur "$current" \
      --arg list "$list_id" \
      --arg board "$board_id" \
      --arg add "$add_list" \
      '
        $cur
        | if $list != "" then .list = $list else . end
        | if $board != "" then .board = $board else . end
        | if $add != "" then .lists = ((.lists // []) + [$add] | unique) else . end
      ' > "$f" || return 1
    echo "Wrote $f"
  fi
  if [[ ! -f "$f" ]]; then
    echo "No Trello config at $f"
    echo "  tri config --list <list-id> [--board <board-url>]"
    echo "  Extra inbox columns for tris: tri config --add-list <list-id>"
    return 0
  fi
  echo "Config: $f"
  jq . "$f"
}

_tri_help() {
  cat <<'EOF'
tri — start Trello card work from a Herdr pane

Run from the repo root space. Creates a worktree grouped under the repo,
switches you to it, and starts the agent there. Does not rename or cd
this space. A card URL names the branch. tri does not read the card.

  tri --card URL [-c] [-b BRANCH]
  tri cards […]            # same as tris
  tri branch […]           # same as ghb (no card)
  tri config --list ID [--board REF] [--add-list ID]

The URL https://trello.com/c/SHORT/196-slug becomes branch SHORT-slug.
A bare card number becomes branch <number>.

Flags:
  --card REF        URL, short link, or card number
  --card-json FILE  Card JSON, when a caller already has it
  -c, --current     Branch from current branch
  -b, --branch B    Use this branch
  --desc TEXT       Ignored. The description is on the card
  --list ID         Stored by tri config, for a new card
  --board REF       Stored by tri config
  --no-agent        Only create the branch and worktree
  --no-focus        Do not switch this pane (used by tris)
  --video           After the PR, record a Playwright walkthrough
  --review-fix      After the PR, self-review and fix in this same agent

The agent in the worktree reads the card. A new card still needs a list:
tri config --list <list-ari>
EOF
}
