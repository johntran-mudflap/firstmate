#!/usr/bin/env bash
# Live scenarios against a real Claude Code TUI parked on a permission prompt,
# on a private tmux server inside a disposable lab home.
set -u
WT=/Users/johntran/.no-mistakes/worktrees/2355c3b107b7/01M5J2CGV2K32PMY9E958FDZ44
EV=/Users/johntran/.no-mistakes/evidence/01M5J2CGV2K32PMY9E958FDZ44
cd "$WT"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/proj"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
T() { tmux "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
git init -q "$LAB/proj"
MARKER=fm-live-ask-marker
cat > "$LAB/ask-hook" <<SH
#!/usr/bin/env bash
case "\$(cat)" in
  *$MARKER*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"live guard asks"}}' ;;
esac
exit 0
SH
chmod +x "$LAB/ask-hook"
jq -n --arg ask "$LAB/ask-hook" '{feedbackDrafts:"off",hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$ask}]}]}}' > "$LAB/settings.json"
UNSET=$(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|NO_MISTAKES_GATE|FM_[A-Z_]+_OVERRIDE|FM_GATE_REFUSE_BYPASS)=' | cut -d= -f1 | sed 's/^/-u /' | tr '\n' ' ')
T new-session -d -s fmlab -n worker -x 160 -y 44 -c "$LAB/proj" \
  "env $UNSET CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model haiku --dangerously-skip-permissions --settings '$LAB/settings.json'; sleep 30"
screen() { T capture-pane -p -t fmlab:worker -S -40 2>/dev/null; }
wait_for() {
  local i=0 s
  while [ $i -lt 480 ]; do
    s=$(screen)
    case "$s" in *'Yes, I trust this folder'*)
      case "$(printf '%s\n' "$s" | grep -F '❯' | head -1)" in *'Yes, I trust'*) T send-keys -t fmlab:worker Enter ;; *) T send-keys -t fmlab:worker Down ;; esac
      sleep 0.3; i=$((i+1)); continue ;; esac
    case "$s" in *"$1"*) return 0 ;; esac
    sleep 0.25; i=$((i+1))
  done
  screen; echo "TIMEOUT waiting for $1"; return 1
}
wait_for 'bypass permissions on' || exit 1
T send-keys -t fmlab:worker -l "Use the Bash tool to run exactly this one command and nothing else: echo $MARKER && echo second-line"
sleep 0.5; T send-keys -t fmlab:worker Enter
wait_for 'Do you want to proceed?' || exit 1
sleep 1
screen > "$EV/worker-pane-on-prompt.txt"
echo "=== pane on prompt saved"

echo "=== SCENARIO A: steer typed into a real prompt"
set +e
FM_HOME="$LAB" bin/fm-send.sh fmlab:worker 'please continue' > "$LAB/send.out" 2> "$LAB/send.err"
echo "fm-send rc=$?"; cat "$LAB/send.out" "$LAB/send.err"
bash -c '. bin/fm-backend.sh; fm_backend_send_text_submit tmux fmlab:worker "please continue" 3 0 0' > "$LAB/sub.out" 2> "$LAB/sub.err"
echo "fm_backend_send_text_submit rc=$?"; cat "$LAB/sub.out" "$LAB/sub.err"
set -e; set +e
sleep 3
screen > "$EV/worker-pane-after-steer.txt"
if grep -q 'Do you want to proceed?' "$EV/worker-pane-after-steer.txt" && ! grep -q 'please continue' "$EV/worker-pane-after-steer.txt" && ! grep -qx '  ⎿  second-line\|second-line' "$EV/worker-pane-after-steer.txt"; then
  echo "A: PASS prompt still open, nothing typed, command not approved"
else echo "A: FAIL"; cat "$EV/worker-pane-after-steer.txt"; fi

echo "=== SCENARIO B: watcher wake on a worker parked on the prompt"
printf 'window=fmlab:worker\nkind=ship\nharness=claude\nbackend=tmux\n' > "$LAB/state/w1.meta"
printf 'working: running the marker command\n' > "$LAB/state/w1.status"
for round in 1 2 3 4 5; do
FM_HOME="$LAB" FM_PERMISSION_PROMPT_SECS=6 FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_STALE_ESCALATE_SECS=999 FM_BUSY_TURN_MAX_SECS=9999 timeout 90 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err"
echo "round $round watch rc=$?"
echo "--- watch stdout"; cat "$LAB/watch.out"
grep -q 'permission prompt pending' "$LAB/watch.out" && break
FM_HOME="$LAB" bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$LAB/drain.err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$LAB/drain.err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LAB/drain.err")
echo "drained: $(tr '\n' ' ' < "$LAB/drain.out") ack=$seq gen=$gen"
[ -z "$seq" ] || FM_HOME="$LAB" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
done
echo "--- watch stderr (tail)"; tail -5 "$LAB/watch.err"
echo "--- triage log (prompt lines)"; grep -h 'permission prompt' "$LAB/state/"*triage* 2>/dev/null | tail -5
echo "--- wake queue"; grep -h 'permission-prompt' "$LAB/state/.wake-queue" 2>/dev/null
screen | grep -q 'Do you want to proceed?' && echo "prompt still unanswered after the watcher"

T send-keys -t fmlab:worker Escape
sleep 2
screen > "$EV/worker-pane-after-escape.txt"
echo "=== cleared prompt with Escape"
