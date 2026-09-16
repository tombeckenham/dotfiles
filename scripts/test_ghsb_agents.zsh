#!/usr/bin/env zsh
# Self-check for the agent pool (ghagents) and per-agent command mapping.
export GHSB_HOME=$(mktemp -d)
source "${0:A:h}/../functions/_ghsb_common.zsh"

fail() { echo "FAIL $1"; exit 1 }

# Default pool is an even three-way split
[[ $(_ghsb_pick_ai 3) == grok   ]] || fail default-0
[[ $(_ghsb_pick_ai 4) == claude ]] || fail default-1
[[ $(_ghsb_pick_ai 5) == codex  ]] || fail default-2

# A persisted pool pins everything to it
ghagents claude >/dev/null
for n in 1 2 3 99; do [[ $(_ghsb_pick_ai $n) == claude ]] || fail pinned; done
ghagents grok codex >/dev/null
[[ $(_ghsb_pick_ai 2) == grok ]] || fail two-pool-0
[[ $(_ghsb_pick_ai 3) == codex ]] || fail two-pool-1

# Env var wins over the file
[[ $(GHSB_AGENTS=codex _ghsb_pick_ai 7) == codex ]] || fail env

# Unknown name rejected, file untouched
ghagents gpt 2>/dev/null && fail validate
[[ $(_ghsb_pick_ai 2) == grok ]] || fail after-bad

# Whitespace-only file falls back instead of dividing by zero
print -r -- "  " > "$GHSB_HOME/agents"
[[ $(_ghsb_pick_ai 3) == grok ]] || fail blank-file

# Every agent maps to a real herdr kind, its own flags, and a review command
for a in grok claude codex; do
  [[ $(_ghsb_herdr_kind $a) == $a ]] || fail "kind-$a"
  [[ -n $(_ghsb_ai_flags $a) ]]      || fail "flags-$a"
  [[ $(_ghsb_review_cmd $a 42) == *42* ]] || fail "review-$a"
done
# Codex has no review skill installed — it must not be handed a slash command
[[ $(_ghsb_review_cmd codex 42) != /* ]]  || fail codex-slash
[[ $(_ghsb_review_cmd claude 42 "all parallel") == "/pr-review-toolkit:review-pr 42 all parallel" ]] || fail claude-args
[[ $(_ghsb_ai_flags codex) != *permission-mode* ]] || fail codex-flags

echo OK
