#!/usr/bin/env bash
# Drive bin/fm-main-prompt-alarm.sh check: an older prompt's delayed check fires
# while a newer prompt's record is current; the newer record must survive and
# its own check must still alert.
set -u
WT=/Users/johntran/.no-mistakes/worktrees/2355c3b107b7/01M5J2CGV2K32PMY9E958FDZ44
cd "$WT"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null
sleep 600 & LOCKPID=$!
trap 'kill $LOCKPID 2>/dev/null; rm -rf "$LAB"' EXIT
echo "$LOCKPID" > "$LAB/state/.lock"
: > "$LAB/transcript.jsonl"
MT=$(/usr/bin/stat -f %m "$LAB/transcript.jsonl")
cat > "$LAB/recorder" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> '$LAB/alerts'
SH
chmod +x "$LAB/recorder"
rec() {  # <token> <subject>
  printf 'token=%s\nepoch=%s\nlock=%s\ntranscript=%s\nmtime=%s\nbackend=\ntarget=\ntool=Bash\nsubject=%s\n' \
    "$1" "$(date +%s)" "$LOCKPID" "$LAB/transcript.jsonl" "$MT" "$2" > "$LAB/state/.main-permission-prompt"
}
run_check() {
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" FM_MAIN_PROMPT_ALARM_SECS="$2" FM_WEDGE_ALARM_EXEC="$LAB/recorder" \
    FM_WEDGE_ALARM_CHANNEL=command:unused bin/fm-main-prompt-alarm.sh check "$1"
}
echo "--- prompt A recorded, its check starts with a 2s delay"
rec tokA 'echo prompt-A'
run_check tokA 2 &
CK=$!
sleep 1
echo "--- prompt B's hook replaces the record while A's check sleeps"
rec tokB 'echo prompt-B'
wait $CK
echo "A check exit: done"
echo "record after A's check:"; sed -n 's/^\(token\|subject\)=/  &/p' "$LAB/state/.main-permission-prompt"
[ -s "$LAB/alerts" ] && echo "UNEXPECTED alert from A: $(cat "$LAB/alerts")" || echo "A raised no alert (correct, superseded)"
echo "--- B's check runs"
run_check tokB 0
echo "alerts:"; cat "$LAB/alerts" 2>/dev/null
echo "log:"; cat "$LAB/state/.main-permission-prompt.log"
echo "--- adversarial: transcript changed after prompt C -> resolved, no alert"
: > "$LAB/alerts"; rec tokC 'echo prompt-C'; sleep 1.1; echo '{"x":1}' >> "$LAB/transcript.jsonl"
run_check tokC 0
[ -s "$LAB/alerts" ] && echo "UNEXPECTED alert for C" || echo "C raised no alert"
tail -1 "$LAB/state/.main-permission-prompt.log"
