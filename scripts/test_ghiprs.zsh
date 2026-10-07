#!/usr/bin/env zsh
# Decision tests for ghiprs: skip only when the Herdr workspace is open.
export GHSB_HOME=$(mktemp -d)
export HERDR_WORKTREES_DIR=$(mktemp -d)
source "${0:A:h}/../functions/_ghsb_common.zsh"

fail() { echo "FAIL $1"; exit 1 }

repo=$(mktemp -d)
name=$(basename "$repo")
git -C "$repo" init -q
git -C "$repo" -c user.email=t@example.com -c user.name=t commit --allow-empty -m init -q
cd "$repo" || exit 1
_ghsb_init_dirs

write_session() {
  local id="$1" pr="$2" ws="$3" wt="$4"
  jq -n --arg id "$id" --argjson pr "$pr" --arg ws "$ws" --arg wt "$wt" \
    '{id:$id, pr:$pr, herdr_workspace:$ws, worktree:$wt}' \
    > "$GHSB_SESSIONS_DIR/${id}.json"
}

act() { _ghsb_pr_review_action "$1" "$2" "$3" "$4"; }

# Live session workspace → skip
write_session "${name}-pr-1" 1 wLIVE ""
[[ $(act 1 feat/one $'wLIVE\nwOTHER' "") == skip ]] || fail live-session
_ghsb_pr_session_exists 1 || fail exists-1

# Dead workspace, nothing on disk → new worktree
write_session "${name}-pr-2" 2 wDEAD ""
[[ $(act 2 feat/two wLIVE "") == new ]] || fail dead-new

# Dead workspace, session worktree directory still there → reopen
wt=$(mktemp -d)
write_session "${name}-pr-3" 3 wDEAD "$wt"
[[ $(act 3 feat/three wLIVE "") == reopen ]] || fail session-dir

# No session → new
[[ $(act 9 feat/missing "" "") == new ]] || fail no-session
_ghsb_pr_session_exists 9 && fail exists-9

# Git worktree for the branch, no session → reopen
git branch feat/present
git_wt="$HERDR_WORKTREES_DIR/$name/feat-present"
mkdir -p "$(dirname "$git_wt")"
git worktree add -q "$git_wt" feat/present
[[ $(act 8 feat/present "" "") == reopen ]] || fail git-wt

# Conventional Herdr path, no git link yet → reopen
slug_dir="$HERDR_WORKTREES_DIR/$name/feat-ondisk"
mkdir -p "$slug_dir"
[[ $(act 7 feat/ondisk "" "") == reopen ]] || fail herdr-path

# Branch already open in a live workspace, session workspace stale → skip
write_session "${name}-pr-4" 4 wSTALE ""
[[ $(act 4 feat/four wOPEN $'feat/four\t/tmp/wt\twOPEN') == skip ]] || fail open-wt

# Listed open workspace id is not actually live → new
[[ $(act 5 feat/five "" $'feat/five\t/tmp/wt\twSTALE') == new ]] || fail stale-open

# Another repo's session does not count
write_session "other-pr-6" 6 wLIVE ""
[[ $(act 6 feat/six wLIVE "") == new ]] || fail other-repo

# Non-canonical session whose id starts with this repo and whose pr matches
write_session "${name}-note" 10 wLIVE ""
[[ $(act 10 feat/ten wLIVE "") == skip ]] || fail prefixed-session
_ghsb_pr_session_exists 10 || fail exists-10

echo OK
