#!/usr/bin/env zsh
# Self-check for ghreap's candidate filter: which live agents are even eligible.
source "${0:A:h}/../functions/ghreap.zsh"
fail() { echo "FAIL $1"; exit 1 }

fixture=$(cat <<JSON
{"result":{"agents":[
 {"name":"ghi-1","agent":"claude","agent_status":"idle","cwd":"$HOME/.herdr/worktrees/ai/1-a","workspace_id":"w1","pane_id":"w1:p1"},
 {"name":"ghi-2","agent":"grok","agent_status":"working","cwd":"$HOME/.herdr/worktrees/ai/2-b","workspace_id":"w2","pane_id":"w2:p1"},
 {"name":"ghi-3","agent":"opencode","agent_status":"idle","cwd":"$HOME/code/dotfiles","workspace_id":"w3","pane_id":"w3:p1"},
 {"name":"ghi-4","agent":"claude","agent_status":"idle","cwd":"$HOME/.claude/worktrees/ai-4","workspace_id":"w4","pane_id":"w4:p1"},
 {"agent":"grok","agent_status":"done","cwd":"$HOME/.herdr/worktrees/ai/5-e","workspace_id":"w5","pane_id":"w5:p1"}
]}}
JSON
)
got=$(_ghsb_reap_candidates "w1:p1" <<< "$fixture")

# Current pane is never reaped, even when otherwise eligible
[[ "$got" != *"ghi-1"* ]] || fail current-pane
# A busy agent is never reaped
[[ "$got" != *"ghi-2"* ]] || fail working
# An agent in a real checkout (not a worktree) is never reaped
[[ "$got" != *"ghi-3"* ]] || fail non-worktree
# Idle agents in either worktree root are candidates
[[ "$got" == *"ghi-4"* ]] || fail claude-worktree
# An unnamed agent falls back to its kind rather than dropping out
[[ "$got" == *"grok"$'\t'* ]] || fail unnamed
[[ $(echo "$got" | grep -c .) == 2 ]] || fail count
# Output is name<TAB>cwd<TAB>workspace, the shape the read loop expects
[[ "$got" == *$'\t'"$HOME/.claude/worktrees/ai-4"$'\t'"w4"* ]] || fail shape

echo OK
