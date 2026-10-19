#!/usr/bin/env zsh
# Decision tests for tri / tris. No network.
export GHSB_HOME=$(mktemp -d)
export HERDR_WORKTREES_DIR=$(mktemp -d)
source "${0:A:h}/../functions/_ghsb_common.zsh"
source "${0:A:h}/../functions/_tri_common.zsh"
source "${0:A:h}/../functions/tri.zsh"
source "${0:A:h}/../functions/tris.zsh"

fail() { echo "FAIL $1"; exit 1 }

[[ $(_tri_card_ref "https://trello.com/c/AbC123xY/add-dark-mode") == AbC123xY ]] || fail url
[[ $(_tri_card_ref "https://trello.com/c/AbC123xY") == AbC123xY ]] || fail url-bare
[[ $(_tri_card_ref "abcdef0123456789abcdef01") == abcdef0123456789abcdef01 ]] || fail id
[[ $(_tri_card_ref "AbC123xY") == AbC123xY ]] || fail short
[[ $(_tri_card_ref "196") == 196 ]] || fail number
[[ $(_tri_card_ref "#196") == 196 ]] || fail hash-number
[[ $(_tri_card_number "https://trello.com/c/4QHZ15LN/196-auth-password") == 196 ]] || fail url-number
urlcard=$(_tri_card_json_from_ref "https://trello.com/c/ebbOKFhy/1-security-deployed-functions-with-no-auth-updateuser-updateprofileimage-allow-account-takeover")
[[ $(jq -r '.shortLink' <<< "$urlcard") == ebbOKFhy ]] || fail url-short
[[ $(jq -r '.idShort' <<< "$urlcard") == 1 ]] || fail url-idshort
[[ $(jq -r '.name' <<< "$urlcard") == security-deployed-functions-with-no-auth-updateu ]] || fail url-slug
_tri_card_number "https://trello.com/c/AbC123xY/add-dark-mode" && fail slug-not-number
_tri_card_ref "deadline" && fail word
_tri_card_ref "abcdefgh" && fail no-digit
[[ $(_tri_slug "Add Dark Mode!") == add-dark-mode ]] || fail slug

seed=$(_tri_ai_seed "Ab")
[[ "$seed" == $(( $(printf '%d' "'A") + $(printf '%d' "'b") )) ]] || fail seed

rest=$(printf '%s\n' '{"ok":true,"data":{"cards":[
  {"id":"1","shortLink":"AbC123xY","name":"mine","desc":"do it","shortUrl":"https://trello.com/c/AbC123xY","closed":false,"idShort":2,"idMembers":["me1"]},
  {"id":"2","shortLink":"Zz9zzzzz","name":"other","desc":"do it","closed":false,"idShort":9,"idMembers":["nope"]},
  {"id":"3","shortLink":"Emp7yxxx","name":"empty","desc":"  ","closed":false,"idShort":4,"idMembers":["me1"]},
  {"id":"4","shortLink":"Clo5edxx","name":"closed","desc":"do it","closed":true,"idShort":1,"idMembers":["me1"]},
  {"id":"5","name":"needs get","url":"https://trello.com/c/Unk0wn00/x","closed":false,"idShort":8}
]}}' | _tri_normalize_cards | _tri_rows_for_me me1)

line() { printf '%s\n' "$rest" | grep -F "$1"; }
mine=$(line AbC123xY)
[[ "$mine" == "2	AbC123xY	mine	https://trello.com/c/AbC123xY	yes	no	yes	1" ]] || fail mine-ready
other=$(line Zz9zzzzz)
[[ "$other" == "9	Zz9zzzzz	other		yes	no	no	2" ]] || fail other-member
parts=$(_tris_parts "$(line Emp7yxxx)")
[[ "$parts" == "4	Emp7yxxx	empty		no	no	yes" ]] || fail empty-desc
parts=$(_tris_parts "$(line Unk0wn00)")
[[ "$parts" == *$'\t'unknown ]] || fail unknown-members
parts=$(_tris_parts "$(line Clo5edxx)")
[[ "$parts" == "1	Clo5edxx	closed		yes	yes	yes" ]] || fail closed

gql=$(printf '%s\n' '{"data":{"nodes":[{"id":"abc","name":"G","description":{"text":"do it"},"url":"https://trello.com/c/AbC123xY/g","closed":false,"members":{"edges":[{"node":{"id":"me1"}}]}}]}}' | _tri_normalize_cards)
[[ $(jq -r '.short' <<< "$gql") == AbC123xY ]] || fail gql-short
[[ $(jq -r '.desc' <<< "$gql") == "do it" ]] || fail gql-desc
[[ $(jq -r '.members[0]' <<< "$gql") == me1 ]] || fail gql-member
[[ $(jq -r '.has_members' <<< "$gql") == true ]] || fail gql-has

mcp=$(printf '%s\n' '{"id":"ari:cloud:trello::card/workspace/w/c","name":"Auth","description":"do it","url":"https://trello.com/c/4QHZ15LN/196-auth","shortUrl":"https://trello.com/c/4QHZ15LN","closed":false,"members":[{"id":"ari:cloud:trello::user/me"}]}' | _tri_normalize_cards)
[[ $(jq -r '.short' <<< "$mcp") == 4QHZ15LN ]] || fail mcp-short
[[ $(jq -r '.id_short' <<< "$mcp") == 196 ]] || fail mcp-number
[[ $(jq -r '.desc' <<< "$mcp") == "do it" ]] || fail mcp-desc
[[ $(jq -r '.members[0]' <<< "$mcp") == ari:cloud:trello::user/me ]] || fail mcp-member
board=$(printf '%s\n' '{"lists":[{"name":"Now","cards":[{"id":"ari:1","name":"N","description":"x","url":"https://trello.com/c/AbC123xY/12-n","closed":false,"members":[]}]}]}' | _tri_normalize_cards)
[[ $(jq -r '.id_short' <<< "$board") == 12 ]] || fail mcp-lists

[[ $(_tri_choose_branch AbC123xY "" only-one) == only-one ]] || fail one-branch
[[ $(_tri_choose_branch AbC123xY forced a b) == forced ]] || fail explicit
got=$(GHSB_YES=1 _tri_choose_branch AbC123xY "" a-one b-two 2>/dev/null)
[[ $? -eq 2 && -z "$got" ]] || fail ambiguous
[[ $(_tri_choose_branch AbC123xY "") == NEW ]] || fail none

page=$(printf '%s\n' '{"data":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR"}}}' | _tri_page_after)
[[ "$page" == CUR ]] || fail cursor
page=$(printf '%s\n' '{"data":{"cards":[]}}' | _tri_page_after)
[[ -z "$page" ]] || fail no-cursor
page=$(printf '%s\n' '{"hasNextPage":true,"nextCursor":"NEXT"}' | _tri_page_after)
[[ "$page" == NEXT ]] || fail mcp-cursor

_tri_config --list list1 --board https://trello.com/b/board --add-list list2 >/dev/null || fail config-write
[[ $(jq -r '.list' "$GHSB_HOME/trello.json") == list1 ]] || fail config-list
_tri_config_load
[[ "$GHSB_TRELLO_LIST_ID" == list1 ]] || fail load-list
[[ "$GHSB_TRELLO_BOARD_ID" == *board ]] || fail load-board
lists=$(_tri_inbox_lists)
[[ "$lists" == *$'\n'*list2* || "$lists" == *list2* ]] || fail inbox
GHSB_TRELLO_LIST=from-env _tri_config_load
[[ "$GHSB_TRELLO_LIST_ID" == from-env ]] || fail env-wins
unset GHSB_TRELLO_LIST

repo=$(mktemp -d)
name=$(basename "$repo")
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.com -c user.name=t commit --allow-empty -m init -q
cd "$repo" || exit 1
_ghsb_init_dirs

write_session() {
  local id="$1" card="$2" ws="$3" wt="$4"
  jq -n --arg id "$id" --arg card "$card" --arg ws "$ws" --arg wt "$wt" \
    '{id:$id, issue:null, pr:null, trello_card:$card, herdr_workspace:$ws, worktree:$wt}' \
    > "$GHSB_SESSIONS_DIR/${id}.json"
}

act() { _tri_card_start_action "$1" "$2" "$3"; }

write_session "${name}-c-AbC123xY" AbC123xY wLIVE ""
[[ $(act AbC123xY $'wLIVE\nwOTHER' "") == skip ]] || fail live-session

write_session "${name}-c-Zz9zzzzz" Zz9zzzzz wDEAD ""
[[ $(act Zz9zzzzz wLIVE "") == new ]] || fail dead-new

wt=$(mktemp -d)
write_session "${name}-c-Emp7yxxx" Emp7yxxx wDEAD "$wt"
[[ $(act Emp7yxxx wLIVE "") == reopen ]] || fail session-dir

[[ $(act No0sessn "" "") == new ]] || fail no-session

git branch AbC123xY-feat
git_wt="$HERDR_WORKTREES_DIR/$name/AbC123xY-feat"
mkdir -p "$(dirname "$git_wt")"
git worktree add -q "$git_wt" AbC123xY-feat
[[ $(act AbC123xY "" "") == reopen ]] || fail dead-session-worktree
# A different card whose only trace is a git worktree.
git branch Qw3rt123-feat
git_wt2="$HERDR_WORKTREES_DIR/$name/Qw3rt123-feat"
git worktree add -q "$git_wt2" Qw3rt123-feat
[[ $(act Qw3rt123 "" "") == reopen ]] || fail git-wt

echo OK
