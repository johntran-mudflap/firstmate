#!/usr/bin/env bash
# Live worker-pane scenarios: a real Claude Code TUI sits on a PreToolUse-hook
# "ask" permission prompt in an isolated tmux server; the real fm-watch.sh and
# the real typed-submit path are pointed at that pane.
set -u
ROOT=$1   # run worktree
EVD=$2    # evidence dir
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$LAB/tmux" "$LAB/proj" "$LAB/state"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
MARKER=fm-live-worker-marker
git -C "$LAB/proj" init -q
cat > "$LAB/ask-hook" <<SH
#!/usr/bin/env bash
case "\$(cat)" in *$MARKER*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"live lab asks"}}' ;; esac
exit 0
SH
chmod +x "$LAB/ask-hook"
printf '{"feedbackDrafts":"off","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s"}]}]}}\n' "$LAB/ask-hook" > "$LAB/settings.json"
UNSET=$(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ')
T new-session -d -s fmlab -n worker -x 160 -y 44 -c "$LAB/proj" \
  "env $UNSET CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model haiku --dangerously-skip-permissions --settings '$LAB/settings.json'; sleep 30"
shot() { T capture-pane -p -t fmlab:worker -S -40; }
wait_for() { local i=0; while [ $i -lt 480 ]; do s=$(shot)
  case "$s" in *'Yes, I trust this folder'*)
    case "$(printf '%s\n' "$s" | grep -F '❯' | head -1)" in *'Yes, I trust'*) T send-keys -t fmlab:worker Enter ;; *) T send-keys -t fmlab:worker Down ;; esac ;;
  *"$1"*) return 0 ;; esac; sleep 0.25; i=$((i+1)); done; shot; echo "TIMEOUT waiting for $1"; exit 1; }
wait_for 'bypass permissions on'
T send-keys -t fmlab:worker -l "Use the Bash tool to run exactly this one command and nothing else: echo $MARKER && echo second-line"
sleep 0.5; T send-keys -t fmlab:worker Enter
wait_for 'Do you want to proceed?'
sleep 1
shot > "$EVD/worker-pane-on-prompt.txt"
echo "=== real Claude pane is on a permission prompt (saved worker-pane-on-prompt.txt)"

SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
export TMUX="$SOCK,1,0"

echo "=== Scenario: typed steer into the prompt pane"
before=$(shot)
rc=0
bash -c '. "$1/bin/fm-backend.sh"; fm_backend_send_text_submit tmux fmlab:worker "please continue" 3 0 0' _ "$ROOT" >"$LAB/send.out" 2>"$LAB/send.err" || rc=$?
sleep 2
after=$(shot)
echo "send rc=$rc"; echo "send stderr: $(cat "$LAB/send.err")"
if [ "$before" = "$after" ] && printf '%s' "$after" | grep -q 'Do you want to proceed?'; then echo "pane unchanged, prompt still open: PASS"; else echo "pane changed: FAIL"; printf '%s\n' "$after"; fi
printf '%s' "$after" | grep -q 'please continue' && echo "steer text typed: FAIL" || echo "no steer text typed: PASS"

echo "=== Scenario: real fm-watch.sh poll loop raises the permission-prompt wake"
printf 'window=fmlab:worker\nkind=ship\nharness=claude\nbackend=tmux\n' > "$LAB/state/worker.meta"
printf 'working: running the marker command\n' > "$LAB/state/worker.status"
ack() { local err seq gen; err="$LAB/drain.err"
  FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || return 0
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true; }
start=$(date +%s); found=
for run in 1 2 3 4 5 6 7 8; do
  env -u NO_MISTAKES_GATE FM_STATE_OVERRIDE="$LAB/state" FM_PERMISSION_PROMPT_SECS=8 FM_POLL=2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=999 FM_BUSY_TURN_MAX_SECS=9999 \
    "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>> "$LAB/watch.err" &
  wpid=$!; i=0; while [ $i -lt 40 ] && kill -0 $wpid 2>/dev/null; do sleep 1; i=$((i+1)); done
  kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
  echo "run $run (+$(( $(date +%s) - start ))s) wake: $(cat "$LAB/watch.out")"
  if grep -q 'permission prompt pending' "$LAB/watch.out"; then found=1; cp "$LAB/state/.wake-queue" "$EVD/wake-queue-after-prompt.tsv" 2>/dev/null; ack; break; fi
  ack
done
[ -n "$found" ] && echo "permission-prompt wake raised: PASS" || echo "no permission-prompt wake: FAIL"
echo "record: $(cat "$LAB/state"/.permission-prompt-* 2>/dev/null)"
shot | grep -q 'Do you want to proceed?' && echo "prompt still unanswered after watcher: PASS" || echo "prompt gone: FAIL"
echo "=== Scenario: same prompt does not wake twice"
env -u NO_MISTAKES_GATE FM_STATE_OVERRIDE="$LAB/state" FM_PERMISSION_PROMPT_SECS=8 FM_POLL=2 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=999 FM_BUSY_TURN_MAX_SECS=9999 \
  "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>/dev/null &
wpid=$!; sleep 15; kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
echo "repeat run wake: $(cat "$LAB/watch.out")"
grep -q 'permission prompt pending' "$LAB/watch.out" && echo "woke again: FAIL" || echo "no second prompt wake: PASS"
ack
echo "=== Scenario: prompt cancelled, next poll clears the record"
T send-keys -t fmlab:worker Escape; sleep 3
echo "record before clearing poll: $(ls -a "$LAB/state" | grep permission-prompt)"
env -u NO_MISTAKES_GATE FM_STATE_OVERRIDE="$LAB/state" FM_PERMISSION_PROMPT_SECS=6 FM_POLL=2 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=999 FM_BUSY_TURN_MAX_SECS=9999 \
  "$ROOT/bin/fm-watch.sh" > "$LAB/watch2.out" 2>/dev/null &
wpid=$!; sleep 12; kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
echo "second watcher stdout: $(cat "$LAB/watch2.out")"
ls -a "$LAB/state" | grep -q '^\.permission-prompt-' && echo "record kept: FAIL" || echo "record cleared: PASS"
shot | tail -12 > "$EVD/worker-pane-after-escape.txt"
