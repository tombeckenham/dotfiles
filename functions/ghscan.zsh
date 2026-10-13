# Fetch an untrusted GitHub repo or pull request without checking it out,
# scan the Git objects for malware-shaped content, and optionally hand the
# same objects to a coding agent inside a Docker Sandbox (sbx).
#
# The host never checks out a working tree, so repo hooks and symlinks do not
# land in $HOME. The agent runs only after the scan reports no blockers, and
# only inside a sandbox created with --skills off.
#
# Usage: ghscan [--agent claude|opencode] [--allow-host HOST] <owner/repo|url> [<pr>]

_ghscan_parse_target() {
  local raw="$1" pr_arg="${2:-}"
  local pr="" owner="" repo="" url="" slug="" path=""

  if [[ -n "$pr_arg" && "$pr_arg" != <-> ]]; then
    print -u2 "ghscan: pull request must be a number"
    return 1
  fi
  pr="$pr_arg"

  if [[ "$raw" == git@github.com:* ]]; then
    path="${raw#git@github.com:}"
    path="${path%.git}"
    owner="${path%%/*}"
    repo="${path#*/}"
    url="https://github.com/${owner}/${repo}.git"
  elif [[ "$raw" == https://github.com/* ]]; then
    path="${raw#https://github.com/}"
    path="${path%%\?*}"
    path="${path%/}"
    if [[ "$path" =~ '^([^/]+)/([^/]+)(\.git)?(/pull/([0-9]+)(/.*)?)?$' ]]; then
      owner="${match[1]}"
      repo="${match[2]%.git}"
      if [[ -n "${match[5]}" ]]; then
        if [[ -n "$pr" && "$pr" != "${match[5]}" ]]; then
          print -u2 "ghscan: URL says pull/${match[5]}, argument says ${pr}"
          return 1
        fi
        pr="${match[5]}"
      fi
    else
      print -u2 "ghscan: could not parse ${raw}"
      return 1
    fi
    url="https://github.com/${owner}/${repo}.git"
  elif [[ "$raw" =~ '^([^/[:space:]]+)/([^/[:space:]]+)$' ]]; then
    owner="${match[1]}"
    repo="${match[2]}"
    url="https://github.com/${owner}/${repo}.git"
  else
    print -u2 "ghscan: pass owner/repo or a github.com URL"
    return 1
  fi

  if [[ -z "$owner" || -z "$repo" || "$owner" == *..* || "$repo" == *..* ]]; then
    print -u2 "ghscan: bad repository name"
    return 1
  fi
  slug="${owner}-${repo}"
  print -r -- "${url}"$'\t'"${slug}"$'\t'"${pr}"
}

_ghscan_sandbox_name() {
  local slug="$1" pr="$2" name
  name="scan-${slug}"
  [[ -n "$pr" ]] && name="${name}-pr-${pr}"
  name="${(L)name}"
  name="${name//[^a-z0-9.-]/-}"
  while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
  print -r -- "${name[1,48]}"
}

# A Windows script is a payload when it downloads code and runs it, or opens a
# reverse shell. A URL in an echo, a local npm/pip install, or a curl of
# localhost is not a payload. Returns 0 when stdin matches.
_ghscan_script_is_payload() {
  grep -E -i -q \
    -e '(curl|wget|fetch|iwr|invoke-webrequest)[^|]{0,240}\|[[:space:]]*(iex|invoke-expression|powershell|pwsh|cmd|(ba)?sh)([^[:alnum:]]|$)' \
    -e 'powershell(.{0,80})-enc(odedcommand)?' \
    -e '(^|[^[:alnum:]])iex[[:space:]]*\(' \
    -e 'invoke-expression' \
    -e 'download(string|file)' \
    -e 'certutil(.{0,80})-urlcache' \
    -e 'bitsadmin(.{0,80})/transfer' \
    -e 'mshta[[:space:]]+https?://' \
    -e '/dev/tcp/'
}

# Print one verdict: uninit, allow, deny, or unknown.
_ghscan_check_verdict() {
  local text="$1" decision=""
  if [[ "$text" == *"has not been initialized"* ]]; then
    print -r -- uninit
    return
  fi
  if [[ "$text" == \{* ]]; then
    decision=$(print -r -- "$text" | jq -r '
      if (.allowed | type) == "boolean" then
        if .allowed then "allow" else "deny" end
      else .decision // .Decision // empty end
    ' 2>/dev/null) || decision=""
  fi
  case "${(L)decision}" in
    allow|allowed) print -r -- allow; return ;;
    deny|denied) print -r -- deny; return ;;
  esac
  local lower="${(L)text}"
  if [[ "$lower" == *"\"decision\": \"allow\""* || "$lower" == *"\"decision\":\"allow\""* ]]; then
    print -r -- allow
  elif [[ "$lower" == *"\"decision\": \"deny\""* || "$lower" == *"\"decision\":\"deny\""* ]]; then
    print -r -- deny
  else
    print -r -- unknown
  fi
}

# Scan a local clone at rev. Prints BLOCK and NOTE lines. Returns 1 when any
# BLOCK line was printed, or when the Git object listing fails.
_ghscan_audit() {
  local dir="$1" rev="$2"
  local blocked=0 meta rel mode hits=0 line file scripts key value body
  local -a rows

  if ! git -C "$dir" cat-file -e "${rev}^{commit}" 2>/dev/null; then
    print -r -- "BLOCK"$'\t'"cannot read ${rev}"
    return 1
  fi

  rows=("${(@f)$(git -C "$dir" -c core.quotepath=false ls-tree -r "$rev")}") || {
    print -r -- "BLOCK"$'\t'"git ls-tree failed"
    return 1
  }

  for line in "${rows[@]}"; do
    [[ -n "$line" ]] || continue
    meta="${line%%$'\t'*}"
    rel="${line#*$'\t'}"
    mode="${meta%% *}"
    case "$mode" in
      100644) ;;
      100755) print -r -- "NOTE"$'\t'"executable: ${rel}" ;;
      120000) print -r -- "BLOCK"$'\t'"symlink: ${rel}"; blocked=1 ;;
      160000) print -r -- "BLOCK"$'\t'"submodule: ${rel}"; blocked=1 ;;
      *) print -r -- "BLOCK"$'\t'"unsafe git mode ${mode}: ${rel}"; blocked=1 ;;
    esac
    case "$rel" in
      *.exe|*.dll|*.so|*.dylib|*.scr)
        print -r -- "BLOCK"$'\t'"binary payload: ${rel}"; blocked=1 ;;
    esac
    case "$rel" in
      .github/workflows/*|.github/workflows/*/*|*/.github/workflows/*)
        print -r -- "NOTE"$'\t'"workflow: ${rel}" ;;
      .husky/*|*/.husky/*|action.yml|action.yaml|*/action.yml|*/action.yaml)
        print -r -- "NOTE"$'\t'"hook or action: ${rel}" ;;
      AGENTS.md|CLAUDE.md|GEMINI.md|*/AGENTS.md|*/CLAUDE.md|*/GEMINI.md|.gitmodules|*/.gitmodules|.mcp.json|*/.mcp.json|mcp.json)
        print -r -- "NOTE"$'\t'"agent or credential instructions: ${rel}" ;;
    esac
  done

  local pattern='(curl|wget|fetch)[^|]{0,200}\|[[:space:]]*([^[:space:]]*/)?(ba)?sh|powershell(.{0,80})-enc(odedcommand)?|/dev/tcp/|bash[[:space:]]+-i[[:space:]]+>&[[:space:]]*/dev/tcp|pull_request_target'
  local grep_out
  grep_out=$(git -C "$dir" grep -n -I -E -e "$pattern" "$rev" 2>/dev/null) || true
  if [[ -n "$grep_out" ]]; then
    while IFS= read -r line; do
      hits=$((hits + 1))
      if (( hits <= 40 )); then
        print -r -- "BLOCK"$'\t'"shell download, reverse shell, or pull_request_target: ${line}"
      fi
      blocked=1
    done <<< "$grep_out"
    if (( hits > 40 )); then
      print -r -- "BLOCK"$'\t'"$((hits - 40)) more shell-download matches omitted"
    fi
  fi

  for line in "${rows[@]}"; do
    rel="${line#*$'\t'}"
    case "$rel" in
      *.bat|*.cmd|*.ps1) ;;
      *) continue ;;
    esac
    body=$(git -C "$dir" show "${rev}:${rel}" 2>/dev/null) || {
      print -r -- "BLOCK"$'\t'"${rel}: could not read script"
      blocked=1
      continue
    }
    if print -r -- "$body" | _ghscan_script_is_payload; then
      print -r -- "BLOCK"$'\t'"${rel}: downloads or executes a remote payload"
      blocked=1
    else
      print -r -- "NOTE"$'\t'"windows script: ${rel}"
    fi
  done

  for line in "${rows[@]}"; do
    rel="${line#*$'\t'}"
    [[ "$rel" == "package.json" || "$rel" == */package.json ]] || continue
    scripts=$(git -C "$dir" show "${rev}:${rel}" 2>/dev/null | jq -r '
      (.scripts // {}) | to_entries[]
      | select(.key == "preinstall" or .key == "install" or .key == "postinstall" or .key == "prepare" or .key == "prepublishOnly")
      | "\(.key)\t\(.value)"
    ' 2>/dev/null) || {
      print -r -- "BLOCK"$'\t'"${rel}: could not read scripts"
      blocked=1
      continue
    }
    while IFS=$'\t' read -r key value; do
      [[ -n "$key" ]] || continue
      if print -r -- "$value" | grep -E -i -q 'https?://|curl|wget|invoke-webrequest|node[[:space:]]+-e|git[[:space:]]+clone'; then
        print -r -- "BLOCK"$'\t'"${rel}: ${key} fetches the network: ${value}"
        blocked=1
      else
        print -r -- "NOTE"$'\t'"${rel}: ${key}: ${value}"
      fi
    done <<< "$scripts"
  done

  return "$blocked"
}

_ghscan_help() {
  cat <<'EOF'
Usage: ghscan [--agent claude|opencode] [--allow-host HOST] <owner/repo|url> [<pr>]

Download a GitHub repo or pull request into ~/sandboxes/ghscan without a
working tree, then scan the Git objects. A blocking finding stops the command
before any agent starts.

  --agent claude|opencode   After a clean scan, clone the repo inside a new
                            sbx sandbox and start that agent. Requires
                            `sbx policy init deny-all` first.
  --allow-host HOST         Let that sandbox reach HOST. claude defaults to
                            api.anthropic.com. opencode needs this flag.
                            The allow rule is scoped to this sandbox.

The scratch clone stays on disk. Read a file with git show. Delete it with
rm -rf ~/sandboxes/ghscan/<name>. sbx rm <sandbox> removes the agent VM.
EOF
}

ghscan() {
  local agent="" host=""
  local -a hosts
  while (( $# )); do
    case "$1" in
      -h|--help) _ghscan_help; return 0 ;;
      --agent)
        shift
        agent="${1:-}"
        [[ "$agent" == claude || "$agent" == opencode ]] || {
          print -u2 "ghscan: --agent must be claude or opencode"
          return 1
        }
        ;;
      --allow-host)
        shift
        host="${1:-}"
        [[ -n "$host" && "$host" != */* && "$host" != *\** && "$host" != *..* ]] || {
          print -u2 "ghscan: --allow-host needs one hostname"
          return 1
        }
        hosts+=("$host")
        ;;
      --) shift; break ;;
      -*) print -u2 "ghscan: unknown flag $1 (see --help)"; return 1 ;;
      *) break ;;
    esac
    shift
  done

  local raw="${1:-}" pr_arg="${2:-}"
  [[ -n "$raw" && $# -le 2 ]] || { _ghscan_help >&2; return 1; }
  [[ -z "${3:-}" ]] || { _ghscan_help >&2; return 1; }

  local parsed url slug pr
  parsed=$(_ghscan_parse_target "$raw" "$pr_arg") || return 1
  url="${parsed%%$'\t'*}"
  pr="${parsed##*$'\t'}"
  slug="${parsed#*$'\t'}"
  slug="${slug%$'\t'*}"

  if [[ -n "$agent" ]]; then
    command -v sbx >/dev/null 2>&1 || { print -u2 "ghscan: sbx not found"; return 1; }
    if [[ "$agent" == "claude" && ${#hosts} -eq 0 ]]; then
      hosts=(api.anthropic.com)
    fi
    if [[ "$agent" == "opencode" && ${#hosts} -eq 0 ]]; then
      print -u2 "ghscan: opencode needs --allow-host for its model API"
      return 1
    fi
    local probe verdict
    probe=$(sbx policy check network --json https://example.com 2>&1) || true
    verdict=$(_ghscan_check_verdict "$probe")
    case "$verdict" in
      deny) ;;
      uninit)
        print -u2 "ghscan: run \`sbx policy init deny-all\` first. That blocks outbound traffic from every sandbox."
        return 1 ;;
      *)
        print -u2 "ghscan: refusing to start an agent. example.com is not denied by the global network policy."
        print -u2 "$probe"
        return 1 ;;
    esac
  fi

  local name dir
  name="${slug}"
  [[ -n "$pr" ]] && name="${name}-pr-${pr}"
  dir="${HOME}/sandboxes/ghscan/${name}"
  if [[ -e "$dir" ]]; then
    print -u2 "ghscan: ${dir} already exists. Read it or remove it, then run this again."
    return 1
  fi
  mkdir -p "${dir:h}" || return 1

  print -r -- "ghscan: cloning ${url} with no checkout into ${dir}"
  if ! GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null clone --no-checkout --depth 1 -- "$url" "$dir"; then
    rm -rf "$dir"
    print -u2 "ghscan: clone failed"
    return 1
  fi
  git -C "$dir" config core.hooksPath /dev/null || true

  local rev="HEAD"
  if [[ -n "$pr" ]]; then
    print -r -- "ghscan: fetching pull/${pr}/head"
    if ! GIT_LFS_SKIP_SMUDGE=1 git -C "$dir" fetch --depth 1 origin "pull/${pr}/head:refs/scan/pr-${pr}"; then
      print -u2 "ghscan: fetch of pull/${pr} failed. Scratch clone left at ${dir}"
      return 1
    fi
    git -C "$dir" symbolic-ref HEAD "refs/scan/pr-${pr}" || return 1
    rev="refs/scan/pr-${pr}"
  fi

  local sha out
  sha=$(git -C "$dir" rev-parse "$rev") || return 1
  print -r -- "ghscan: scanning ${sha}"
  if ! out=$(_ghscan_audit "$dir" "$rev"); then
    print -r -- "$out"
    print -r -- "ghscan: blocked. No sandbox was created."
    print -r -- "Read a file with: git -C ${dir} show ${rev}:package.json"
    print -r -- "Delete the scratch clone with: rm -rf ${dir}"
    return 2
  fi
  if [[ -n "$out" ]]; then
    print -r -- "$out"
  else
    print -r -- "ghscan: no findings"
  fi
  print -r -- "ghscan: scratch clone has no working tree at ${dir}"

  [[ -n "$agent" ]] || return 0

  local sbx_name="$(_ghscan_sandbox_name "$slug" "$pr")"
  if sbx ls -q 2>/dev/null | grep -qx "$sbx_name"; then
    print -u2 "ghscan: sandbox ${sbx_name} already exists. Run: sbx rm ${sbx_name}"
    return 1
  fi

  print -r -- "ghscan: creating sbx sandbox ${sbx_name} (${agent}, skills off)"
  if ! sbx create --name "$sbx_name" --skills off --clone "$agent" "$dir"; then
    print -u2 "ghscan: sbx create failed. Scratch clone left at ${dir}"
    return 1
  fi

  local one
  for one in "${hosts[@]}"; do
    print -r -- "ghscan: allowing ${one} for sandbox ${sbx_name} only"
    sbx policy allow network --sandbox "$sbx_name" "$one" || {
      print -u2 "ghscan: could not allow ${one}. Sandbox left running: sbx rm ${sbx_name}"
      return 1
    }
  done

  probe=$(sbx policy check network --sandbox "$sbx_name" --json https://example.com 2>&1) || true
  verdict=$(_ghscan_check_verdict "$probe")
  if [[ "$verdict" != deny ]]; then
    print -u2 "ghscan: sandbox ${sbx_name} can still reach example.com. Not starting the agent."
    print -u2 "Remove it with: sbx rm ${sbx_name}"
    print -u2 "$probe"
    return 1
  fi

  print -r -- "ghscan: kit network rules for ${sbx_name} (the agent can reach these too):"
  sbx policy ls "$sbx_name" --source kit --type network || true

  local prompt="Read this repository for malware. Do not install dependencies, do not run project scripts, and do not make network calls. Report install scripts, GitHub workflows, git hooks, MCP config, obfuscated shell, and unexpected binaries. Write the report to /tmp/malware-report.md"
  print -r -- "ghscan: starting ${agent}. Detach with Ctrl-\\ if you need to leave the session running."
  sbx run --name "$sbx_name" -- "$prompt"
  local run_status=$?
  print -r -- "ghscan: report copy: sbx cp ${sbx_name}:/tmp/malware-report.md ~/sandboxes/ghscan/${name}-report.md"
  print -r -- "ghscan: remove the sandbox with: sbx rm ${sbx_name}"
  print -r -- "ghscan: remove the scratch clone with: rm -rf ${dir}"
  return "$run_status"
}
