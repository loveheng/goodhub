#!/usr/bin/env bash
set -u
DEV="3B161700Y0600000"
LOG=/tmp/residency-samples.log
N=${1:-20}
LOCK=/tmp/residency-harness.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then echo "instance-alive (pid $(cat "$LOCK"))"; exit 1; fi
echo $$ > "$LOCK"
> "$LOG"
adb -s "$DEV" shell am force-stop com.zzh.goodhub
sleep 2
adb -s "$DEV" logcat -c
adb -s "$DEV" shell am start -n com.zzh.goodhub/.MainActivity
sleep 10
echo "=== harness start $(date +%H:%M:%S) cycles=$N ===" >> "$LOG"
done_evict=$(adb -s "$DEV" logcat -d 2>/dev/null | grep -c "ttl-elapsed"; true)
done_gen=$(adb -s "$DEV" logcat -d 2>/dev/null | grep -c "genie query done"; true)
for i in $(seq 1 "$N"); do
  echo "--- cycle $i $(date +%H:%M:%S) ---" >> "$LOG"
  adb -s "$DEV" shell input keyevent 224 >/dev/null 2>&1
  sleep 1
  curl -s -m 90 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"action\":\"query_on_device\",\"args\":{\"prompt\":\"cycle ${i} residency sample: report battery and time in one sentence.\"}}" \
    "$BASE/debug/action" | head -c 120 >> "$LOG" 2>&1
  ok=0
  for w in $(seq 1 45); do
    now=$(adb -s "$DEV" logcat -d 2>/dev/null | grep -c "genie query done"; true)
    if [ "$now" -gt "$done_gen" ]; then ok=1; done_gen=$now; break; fi
    sleep 2
  done
  echo "gen-done=$ok" >> "$LOG"
  sleep 2
  if [ $((i % 2)) -eq 0 ]; then
    adb -s "$DEV" shell input keyevent 26 >/dev/null 2>&1
    echo "screen-off for TTL window" >> "$LOG"
  fi
  ok=0
  for w in $(seq 1 25); do
    now=$(adb -s "$DEV" logcat -d 2>/dev/null | grep -c "ttl-elapsed"; true)
    if [ "$now" -gt "$done_evict" ]; then ok=1; done_evict=$now; break; fi
    sleep 3
  done
  echo "evict-done=$ok" >> "$LOG"
  adb -s "$DEV" logcat -d 2>/dev/null | grep -E "\[RESIDENCY\] (evict|rss-sample)" | tail -3 >> "$LOG"
  sleep 2
done
echo "=== harness end $(date +%H:%M:%S) ===" >> "$LOG"
echo "=== 样本分布 ===" >> "$LOG"
grep -oE "reason=[a-z-]+" "$LOG" | sort | uniq -c >> "$LOG"
grep -oE "screen=(true|false)" "$LOG" | sort | uniq -c >> "$LOG"
grep -oE "batt=[0-9]+" "$LOG" | sort | uniq -c >> "$LOG"
grep -c "evict-done=1" "$LOG" >> "$LOG"
