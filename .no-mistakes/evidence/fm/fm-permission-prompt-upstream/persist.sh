set -u
cd /Users/johntran/.no-mistakes/worktrees/2355c3b107b7/01M5J2CGV2K32PMY9E958FDZ44
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$LAB" >/dev/null
sleep 600 & L=$!; trap 'kill $L 2>/dev/null; rm -rf "$LAB"' EXIT
echo $L > "$LAB/state/.lock"; : > "$LAB/t"; MT=$(/usr/bin/stat -f %m "$LAB/t")
printf 'token=tokA\nepoch=%s\nlock=%s\ntranscript=%s\nmtime=%s\nbackend=\ntarget=\ntool=Bash\nsubject=echo A\n' "$(date +%s)" $L "$LAB/t" "$MT" > "$LAB/state/.main-permission-prompt"
env -u NO_MISTAKES_GATE FM_HOME="$LAB" FM_MAIN_PROMPT_ALARM_SECS=0 FM_WEDGE_ALARM_EXEC=/usr/bin/true FM_WEDGE_ALARM_CHANNEL=command:x bin/fm-main-prompt-alarm.sh check tokA
echo "after A's own matched check, record exists: $([ -e "$LAB/state/.main-permission-prompt" ] && echo yes || echo no)"
grep -E '^(token|subject)=' "$LAB/state/.main-permission-prompt"
echo "a newer hook write (mv over it) replaces it, nothing in check removes it"
