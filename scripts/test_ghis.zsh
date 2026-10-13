#!/usr/bin/env zsh
# Decision tests for ghis: which assigned issues start, and skip only when
# the Herdr workspace is open.
export GHSB_HOME=$(mktemp -d)
export HERDR_WORKTREES_DIR=$(mktemp -d)
source "${0:A:h}/../functions/_ghsb_common.zsh"
source "${0:A:h}/../functions/ghis.zsh"

fail() { echo "FAIL $1"; exit 1 }

issues=$(cat <<'JSON'
[
  {"number":1,"title":"has pr","url":"https://example/1","body":"do it","closedByPullRequestsReferences":[{"number":9}]},
  {"number":2,"title":"ready","url":"https://example/2","body":"do it","closedByPullRequestsReferences":[]},
  {"number":3,"title":"empty","url":"https://example/3","body":"  \n","closedByPullRequestsReferences":[]}
]
JSON
)
got=$(_ghis_select "$issues")
[[ "$got" != *$'\t'"has pr"$'\t'* ]] || fail dropped-linked
[[ "$got" == *2$'\t'"ready"$'\t'*"yes"* ]] || fail kept-ready
[[ "$got" == *3$'\t'"empty"$'\t'*"no"* ]] || fail empty-flag

repo=$(mktemp -d)
name=$(basename "$repo")
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.com -c user.name=t commit --allow-empty -m init -q
cd "$repo" || exit 1
_ghsb_init_dirs

write_session() {
  local id="$1" issue="$2" ws="$3" wt="$4"
  jq -n --arg id "$id" --argjson issue "$issue" --arg ws "$ws" --arg wt "$wt" \
    '{id:$id, issue:$issue, pr:null, herdr_workspace:$ws, worktree:$wt}' \
    > "$GHSB_SESSIONS_DIR/${id}.json"
}

act() { _ghsb_issue_start_action "$1" "$2" "$3"; }

write_session "${name}-1" 1 wLIVE ""
[[ $(act 1 $'wLIVE\nwOTHER' "") == skip ]] || fail live-session

write_session "${name}-2" 2 wDEAD ""
[[ $(act 2 wLIVE "") == new ]] || fail dead-new

wt=$(mktemp -d)
write_session "${name}-3" 3 wDEAD "$wt"
[[ $(act 3 wLIVE "") == reopen ]] || fail session-dir

[[ $(act 9 "" "") == new ]] || fail no-session

git branch 4-feat
git_wt="$HERDR_WORKTREES_DIR/$name/4-feat"
mkdir -p "$(dirname "$git_wt")"
git worktree add -q "$git_wt" 4-feat
[[ $(act 4 "" "") == reopen ]] || fail git-wt

write_session "${name}-5" 5 wSTALE ""
[[ $(act 5 wOPEN $'5-feat\t/tmp/wt\twOPEN') == skip ]] || fail open-wt

write_session "${name}-pr-6" 6 wLIVE ""
jq '.pr = 60' "$GHSB_SESSIONS_DIR/${name}-pr-6.json" > "$GHSB_SESSIONS_DIR/${name}-pr-6.json.tmp"
mv "$GHSB_SESSIONS_DIR/${name}-pr-6.json.tmp" "$GHSB_SESSIONS_DIR/${name}-pr-6.json"
[[ $(act 6 wLIVE "") == new ]] || fail pr-session-ignored

echo OK
