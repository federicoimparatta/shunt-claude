#!/bin/bash
# Transport evals for scripts/lib/worker.sh, bulk-read and code-write.
#
# Modified from spotify/portal-ai-plugins plugins/shunt (Apache-2.0), where
# this suite stubbed portal-cli.
#
# Runs against a stub `claude` placed first on PATH, so these make no real
# model calls and need no login. The stub records its argv, stdin, working
# directory and environment, then answers according to STUB_BEHAVIOR.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stub cannot leak into the
# benchmark suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BULK_READ="$PLUGIN_DIR/scripts/bulk-read"
CODE_WRITE="$PLUGIN_DIR/scripts/code-write"

WORKDIR="$(mktemp -d)"
STUB_BIN="$WORKDIR/bin"
export STUB_RECORD_DIR="$WORKDIR/record"
mkdir -p "$STUB_BIN" "$STUB_RECORD_DIR"

# Start from a clean configuration whatever the caller's shell exports.
unset SHUNT_DISABLED SHUNT_WORKER SHUNT_WORKER_MODEL SHUNT_TIMEOUT_SECONDS SHUNT_MAX_PAYLOAD_BYTES STUB_BEHAVIOR

cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/bash
# Stub claude: record how it was called, then answer per STUB_BEHAVIOR.
d="$STUB_RECORD_DIR"
: > "$d/argv"
for a in "$@"; do printf '%s\n' "$a" >> "$d/argv"; done
cat > "$d/stdin"
printf '%s\n' "${SHUNT_WORKER:-unset}" > "$d/env-shunt-worker"
pwd -P > "$d/cwd"
ls -A > "$d/cwd-listing"
case "${STUB_BEHAVIOR:-ok}" in
  ok)     printf -- '- first line\n- second line\n' ;;
  fenced) printf '```ts\nexport const x = 1;\n```\n' ;;
  fail)   echo "API Error: 401 authentication_error" >&2; exit 1 ;;
  empty)  printf '\n' ;;
  noise)  echo "warning: something noisy" >&2; printf 'answer\n' ;;
  hang)   exec sleep 30 ;;
esac
STUB
chmod +x "$STUB_BIN/claude"
export PATH="$STUB_BIN:$PATH"

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# check_yes <name> <description> <command...>: passes when the command succeeds
check_yes() {
  local name="$1" desc="$2"
  shift 2
  if "$@"; then check "$name" "y" "y" "$desc"; else check "$name" "y" "n" "$desc"; fi
}

reset_record() { rm -f "$STUB_RECORD_DIR"/*; }
stub_called() { [ -e "$STUB_RECORD_DIR/argv" ] && echo yes || echo no; }

# The value right after a flag in the recorded argv ("<absent>" if the flag is missing)
arg_after() {
  awk -v flag="$1" 'found { print; done = 1; exit } $0 == flag { found = 1 } END { if (!done) print "<absent>" }' \
    "$STUB_RECORD_DIR/argv"
}
has_arg() { grep -qxF -- "$1" "$STUB_RECORD_DIR/argv" && echo yes || echo no; }

# Runs a script, capturing stdout, stderr and the exit status.
OUT="$WORKDIR/out"
ERR="$WORKDIR/err"
run() {
  reset_record
  "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

# ── Fixtures ──

SRC="$WORKDIR/src"
mkdir -p "$SRC"
printf 'marker-alpha\nmarker-beta\n' > "$SRC/service.ts"
printf 'export function ref() {}\n' > "$SRC/reference.ts"
printf '\211PNG\r\n\032\n\000\000\000\015IHDR\n' > "$SRC/image.png"

BULK_PROMPT="You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
CODE_PROMPT="You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."

# ── bulk-read: invocation ──

run "$BULK_READ" --question "what is alpha?" --paths "$SRC/service.ts"
check "answer-returned" "- first line
- second line" "$(cat "$OUT")" "prints the worker's answer"
check "exit-zero" "0" "$RC" "a good answer exits 0"
check_yes "corpus-via-stdin" "files reach the worker on stdin, wrapped and line-numbered" \
  grep -qF "<file path=\"$SRC/service.ts\">" "$STUB_RECORD_DIR/stdin"
check "line-numbers-exact" "     2	marker-beta" "$(grep -F 'marker-beta' "$STUB_RECORD_DIR/stdin")" \
  "each line carries its number, like cat -n"
check_yes "question-via-stdin" "the question travels on stdin" \
  grep -qxF "Question: what is alpha?" "$STUB_RECORD_DIR/stdin"
check "nothing-in-argv" "0" "$(grep -cE 'marker-alpha|what is alpha' "$STUB_RECORD_DIR/argv")" \
  "neither corpus nor question is on the command line"
check "print-mode" "yes" "$(has_arg -p)" "worker runs claude -p"
check "model-latest-alias" "haiku" "$(arg_after --model)" "default worker model is the latest-Haiku alias"
check "text-output" "text" "$(arg_after --output-format)" "plain text output"
check "no-builtin-tools" "" "$(arg_after --tools)" "--tools \"\" disables every built-in tool"
check "no-mcp-tools" "mcp__*" "$(arg_after --disallowedTools)" "MCP tools denied too"
check "strict-mcp-config" "yes" "$(has_arg --strict-mcp-config)" "no MCP servers load"
check "user-settings-only" "user" "$(arg_after --setting-sources)" "no project or local settings"
check "safe-mode" "yes" "$(has_arg --safe-mode)" "no plugins, hooks, CLAUDE.md, skills, memory"
check "no-slash-commands" "yes" "$(has_arg --disable-slash-commands)" "no skills or commands"
check "no-session-persistence" "yes" "$(has_arg --no-session-persistence)" "worker sessions are not saved"
check "bulk-reader-prompt" "$BULK_PROMPT" "$(arg_after --system-prompt)" "upstream bulk-reader instructions, verbatim"
check "worker-env-marked" "1" "$(cat "$STUB_RECORD_DIR/env-shunt-worker")" "worker sees SHUNT_WORKER=1"
check_yes "worker-cwd-isolated" "worker starts in an empty temp dir" \
  test "$(cat "$STUB_RECORD_DIR/cwd")" != "$(pwd -P)" -a ! -s "$STUB_RECORD_DIR/cwd-listing"
check "caller-env-untouched" "unset" "${SHUNT_WORKER:-unset}" "SHUNT_WORKER never leaks into the caller"

SHUNT_WORKER_MODEL="claude-sonnet-test" run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "model-override" "claude-sonnet-test" "$(arg_after --model)" "SHUNT_WORKER_MODEL overrides the model"

# ── Guards ──

SHUNT_WORKER=1 run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "recursion-guard" "1:no" "$RC:$(stub_called)" "SHUNT_WORKER=1 refuses before spawning a worker"
check_yes "recursion-guard-explained" "error names SHUNT_WORKER" grep -qF "SHUNT_WORKER=1" "$ERR"

SHUNT_WORKER=1 run "$CODE_WRITE" --spec "s" --reference "$SRC/reference.ts"
check "recursion-guard-code-write" "1:no" "$RC:$(stub_called)" "code-write honors SHUNT_WORKER=1 too"

SHUNT_DISABLED=1 run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "disabled-guard" "1:no" "$RC:$(stub_called)" "SHUNT_DISABLED=1 refuses to delegate"
check_yes "disabled-guard-explained" "error names SHUNT_DISABLED" grep -qF "SHUNT_DISABLED=1" "$ERR"

run "$BULK_READ" --question "q" --paths "$SRC/missing.ts"
check "missing-file-refused" "1:no" "$RC:$(stub_called)" "a typo'd path fails loudly"

run "$BULK_READ" --question "q" --paths "$SRC/image.png"
check "binary-file-refused" "1:no" "$RC:$(stub_called)" "images and PDFs are not sent as text"

run "$BULK_READ" --paths "$SRC/service.ts"
check "question-required" "1:no" "$RC:$(stub_called)" "--question is required"

run "$BULK_READ" --question "q"
check "paths-required" "1:no" "$RC:$(stub_called)" "--paths is required"

# ── Payload size ──

# Over 1 MB: past macOS's 1 MiB ARG_MAX, so this only works if the corpus
# travels on stdin. Upstream refused anything over 400 KB for this reason.
BIG="$WORKDIR/big.txt"
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "line %06d of a large corpus\n", i }' > "$BIG"
SHUNT_MAX_PAYLOAD_BYTES=3000000 run "$BULK_READ" --question "q" --paths "$BIG"
check "large-payload-ok" "0" "$RC" "a >1 MB corpus goes through"
check_yes "large-payload-via-stdin" "the worker received all of it on stdin" \
  test "$(wc -c < "$STUB_RECORD_DIR/stdin" 2>/dev/null || echo 0)" -gt 1048576
check "no-e2big" "0" "$(grep -ciE 'argument list too long|E2BIG' "$ERR")" "no ARG_MAX failure"

run "$BULK_READ" --question "q" --paths "$BIG"
check "oversized-payload-refused" "1:no" "$RC:$(stub_called)" "default ceiling keeps requests inside Haiku's window"
check_yes "oversized-payload-explained" "error names the limit" grep -qF "over the 600000 byte limit" "$ERR"

# ── Worker failures ──

STUB_BEHAVIOR=fail run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "worker-failure-fails" "1" "$RC" "a failed worker run is an error"
check_yes "worker-failure-surfaced" "the worker's own message surfaces" grep -qF "authentication_error" "$ERR"

STUB_BEHAVIOR=empty run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "empty-answer-fails" "1" "$RC" "an answer with no text is an error"

STUB_BEHAVIOR=noise run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "stderr-noise-ignored" "answer" "$(cat "$OUT")" "worker stderr does not corrupt the answer"

# ── Timeout ──

start=$(date +%s)
SHUNT_TIMEOUT_SECONDS=1 STUB_BEHAVIOR=hang run "$BULK_READ" --question "q" --paths "$SRC/service.ts"
elapsed=$(( $(date +%s) - start ))
check "timeout-fails" "1" "$RC" "a hung worker is cut off"
check_yes "timeout-explained" "error names SHUNT_TIMEOUT_SECONDS" grep -qF "SHUNT_TIMEOUT_SECONDS" "$ERR"
check_yes "timeout-prompt" "cut off within seconds, not the stub's 30" test "$elapsed" -lt 15

# Same with no timeout(1) or gtimeout on PATH: the bash watchdog takes over.
start=$(date +%s)
PATH="$STUB_BIN:/usr/bin:/bin" SHUNT_TIMEOUT_SECONDS=1 STUB_BEHAVIOR=hang run /bin/bash "$BULK_READ" --question "q" --paths "$SRC/service.ts"
elapsed=$(( $(date +%s) - start ))
check "timeout-fallback-fails" "1" "$RC" "the bash watchdog cuts off a hung worker"
check_yes "timeout-fallback-prompt" "cut off within seconds, not the stub's 30" test "$elapsed" -lt 15

# ── Preflight ──

PATH="/usr/bin:/bin" run /bin/bash "$BULK_READ" --question "q" --paths "$SRC/service.ts"
check "claude-missing" "1" "$RC" "no claude CLI on PATH is an error"
check_yes "claude-missing-explained" "error says how to fix it" grep -qF "claude CLI was not found" "$ERR"

# ── code-write ──

run "$CODE_WRITE" --spec "write a stub"
check "missing-reference-refused" "1:no" "$RC:$(stub_called)" "--reference is required"
check_yes "missing-reference-explained" "error explains why" grep -qF -- "--reference is required" "$ERR"

run "$CODE_WRITE" --spec "write a stub" --reference "$SRC/nope.ts"
check "reference-not-found" "1:no" "$RC:$(stub_called)" "a missing reference fails loudly"

run "$CODE_WRITE" --reference "$SRC/reference.ts"
check "spec-required" "1:no" "$RC:$(stub_called)" "--spec is required"

STUB_BEHAVIOR=fenced run "$CODE_WRITE" --spec "write a stub" --reference "$SRC/reference.ts" --target "$WORKDIR/out.ts"
check "target-written" "export const x = 1;" "$(cat "$WORKDIR/out.ts" 2>/dev/null)" "--target writes the file, fences stripped"
check "code-writer-prompt" "$CODE_PROMPT" "$(arg_after --system-prompt)" "upstream code-writer instructions, verbatim"
check_yes "spec-via-stdin" "spec and reference travel on stdin, reference verbatim" \
  grep -qxF "export function ref() {}" "$STUB_RECORD_DIR/stdin"
check "spec-not-in-argv" "0" "$(grep -cF 'write a stub' "$STUB_RECORD_DIR/argv")" "the spec is not on the command line"

STUB_BEHAVIOR=fenced run "$CODE_WRITE" --spec "write a stub" --reference "$SRC/reference.ts"
check "stdout-fences-stripped" "export const x = 1;" "$(cat "$OUT")" "without --target, clean code on stdout"

rm -rf "$WORKDIR"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
