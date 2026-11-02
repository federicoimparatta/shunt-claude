#!/bin/bash
# Shared worker plumbing for shunt's delegation scripts.
#
# Modified from spotify/portal-ai-plugins plugins/shunt (Apache-2.0). Upstream
# this file was scripts/lib/aika.sh and delegated to Spotify Portal's AiKA
# through `portal-cli actions aika:invoke-chat`. This port delegates to a
# local Claude Code worker instead: `claude -p` pinned to a small model, run
# from an empty directory with no tools, plugins, hooks, MCP servers,
# CLAUDE.md, auto memory or skills.
#
# Every delegation is one shot: nothing carries over between calls. To ask a
# follow-up, ask again with the same files. They go to the worker, never into
# the calling session's context, so re-sending them costs the caller nothing.
#
# The prompt and the file corpus travel through the worker's stdin, never its
# argv, so a request is not bounded by ARG_MAX. It is bounded by the worker
# model's context window instead, which SHUNT_MAX_PAYLOAD_BYTES approximates.
#
# Written for the bash 3.2 that macOS ships as /bin/bash.

# "haiku" is the Claude Code alias for the latest Haiku model, so the worker
# moves to each new Haiku release without a change here. Pin a full model ID
# through SHUNT_WORKER_MODEL when a run must be reproducible.
SHUNT_WORKER_MODEL="${SHUNT_WORKER_MODEL:-haiku}"

# Ceiling for one worker run; large generations can take a while.
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-180}"
case "$SHUNT_TIMEOUT_SECONDS" in ''|*[!0-9]*|0) SHUNT_TIMEOUT_SECONDS=180 ;; esac

# Sized for a 200K-token context window, the smallest any Haiku model has
# shipped with. About 600 KB of code or prose fits with room left for the
# system prompt and the answer. Raise this when
# SHUNT_WORKER_MODEL names a model with a larger window; Claude Code itself
# caps piped stdin at 10 MB.
SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-600000}"
case "$SHUNT_MAX_PAYLOAD_BYTES" in ''|*[!0-9]*) SHUNT_MAX_PAYLOAD_BYTES=600000 ;; esac

# Worker instructions, one per mode. These are the bulk-reader and
# code-writer mode instructions from the upstream README, verbatim.
shunt_system_prompt() {
  case "$1" in
    bulk-reader)
      printf '%s' "You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
      ;;
    code-writer)
      printf '%s' "You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."
      ;;
    *)
      return 1
      ;;
  esac
}

shunt_flag_on() {
  case "$1" in 1|true|TRUE|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Refuses to delegate when delegation must not happen:
# - SHUNT_WORKER=1: we are inside a shunt worker. The worker has no tools, so
#   this should be unreachable; it is here so a misconfigured worker can never
#   spawn another one.
# - SHUNT_DISABLED=1: the user turned shunt off.
shunt_guard() {
  if shunt_flag_on "${SHUNT_WORKER:-}"; then
    echo "Error: refusing to delegate from inside a shunt worker (SHUNT_WORKER=1)." >&2
    return 1
  fi
  if shunt_flag_on "${SHUNT_DISABLED:-}"; then
    echo "Error: shunt is disabled (SHUNT_DISABLED=1). Read the file directly instead, with offset/limit for large files." >&2
    return 1
  fi
  return 0
}

shunt_preflight() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "Error: the claude CLI was not found on PATH." >&2
    echo "  shunt runs its worker with \`claude -p\`. Install Claude Code and log in, then retry." >&2
    return 1
  fi
  return 0
}

# Images, PDFs and other binary files. The Read tool renders those natively;
# the worker only gets text.
shunt_is_binary() {
  local f="$1" lower sample_bytes text_bytes
  lower=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp|*.ico|*.tif|*.tiff|*.heic|*.heif|*.avif|*.pdf)
      return 0 ;;
  esac
  [ "$(head -c 5 "$f" 2>/dev/null)" = "%PDF-" ] && return 0
  # A NUL byte in the first 8 KiB means binary.
  sample_bytes=$(head -c 8192 "$f" 2>/dev/null | wc -c | tr -d ' ')
  text_bytes=$(head -c 8192 "$f" 2>/dev/null | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')
  [ "$sample_bytes" != "$text_bytes" ] && return 0
  return 1
}

# Temp files and directories, removed on script exit.
# Usage: shunt_tmpfile <varname> / shunt_tmpdir <varname>
SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}
shunt_tmpdir() {
  local d
  d=$(mktemp -d) || return 1
  SHUNT_TMPFILES+=("$d")
  trap 'rm -rf "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$d"
}

# Runs a command with a time limit and explicit stdin, stdout and stderr.
#   shunt_run_with_timeout <seconds> <stdin-file> <stdout-file> <stderr-file> <cmd> [args...]
# Returns the command's exit status, or 124 when it ran out of time. Uses
# timeout(1) or Homebrew's gtimeout, else a plain bash watchdog.
shunt_run_with_timeout() {
  local secs="$1" in="$2" out="$3" err="$4" t rc pid watchdog marker
  shift 4

  for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then
      "$t" -k 10 "$secs" "$@" < "$in" > "$out" 2> "$err"
      rc=$?
      [ "$rc" -eq 137 ] && rc=124
      return "$rc"
    fi
  done

  marker="$out.timed-out"
  rm -f "$marker"
  "$@" < "$in" > "$out" 2> "$err" &
  pid=$!
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    : > "$marker"
    kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL "$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid"
  rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ -e "$marker" ]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

# Indents a file's first lines onto stderr, for error reports.
shunt_show() {
  [ -s "$1" ] || return 0
  head -n 20 "$1" | sed 's/^/  /' >&2
}

# Runs one worker turn under a mode's instructions and prints the answer.
#   $1 mode name (bulk-reader or code-writer)
#   $2 file holding the message
shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local system_prompt bytes workdir answer_file stderr_file rc

  if ! system_prompt=$(shunt_system_prompt "$mode_name"); then
    echo "Error: unknown shunt mode: $mode_name" >&2
    return 1
  fi

  bytes=$(wc -c < "$message_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SHUNT_MAX_PAYLOAD_BYTES byte limit." >&2
    echo "The worker model ($SHUNT_WORKER_MODEL) has to fit the whole request in its context window." >&2
    echo "Send fewer or smaller files, or raise SHUNT_MAX_PAYLOAD_BYTES for a model with a larger window." >&2
    return 1
  fi

  shunt_tmpdir workdir || return 1
  shunt_tmpfile answer_file || return 1
  shunt_tmpfile stderr_file || return 1

  # The worker runs from an empty directory, so no project CLAUDE.md,
  # .mcp.json or .claude/ settings can apply, and every isolation switch the
  # CLI offers is on:
  #   --tools ""                    no built-in tools
  #   --disallowedTools "mcp__*"    no MCP tools either
  #   --strict-mcp-config           no MCP servers (none are passed)
  #   --setting-sources user        user settings only (auth-related env),
  #                                 never project or local ones
  #   --safe-mode                   no CLAUDE.md, skills, plugins, hooks, MCP
  #                                 servers or auto memory; auth still works,
  #                                 unlike --bare, which needs an API key
  #   --disable-slash-commands      no skills or commands
  #   --no-session-persistence      nothing saved for --resume
  #   --system-prompt               only the mode's instructions
  # SHUNT_WORKER=1 makes shunt's own hooks and scripts stand down should they
  # ever load inside the worker anyway.
  (
    cd "$workdir" || exit 1
    export SHUNT_WORKER=1
    export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
    export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
    export ENABLE_CLAUDEAI_MCP_SERVERS=false
    shunt_run_with_timeout "$SHUNT_TIMEOUT_SECONDS" \
      "$message_file" "$answer_file" "$stderr_file" \
      claude -p \
        --model "$SHUNT_WORKER_MODEL" \
        --output-format text \
        --system-prompt "$system_prompt" \
        --tools "" \
        --disallowedTools "mcp__*" \
        --strict-mcp-config \
        --setting-sources user \
        --safe-mode \
        --disable-slash-commands \
        --no-session-persistence
  )
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: the worker did not answer within ${SHUNT_TIMEOUT_SECONDS}s." >&2
    echo "Raise SHUNT_TIMEOUT_SECONDS or split the work into smaller calls." >&2
    return 1
  fi

  if [ "$rc" -ne 0 ]; then
    echo "Error: the worker (claude -p --model $SHUNT_WORKER_MODEL) exited with status $rc." >&2
    # claude -p reports some failures on stdout, so show both streams.
    shunt_show "$stderr_file"
    shunt_show "$answer_file"
    return 1
  fi

  if ! grep -q '[^[:space:]]' "$answer_file"; then
    echo "Error: the worker returned no text." >&2
    shunt_show "$stderr_file"
    return 1
  fi

  cat "$answer_file"
}
