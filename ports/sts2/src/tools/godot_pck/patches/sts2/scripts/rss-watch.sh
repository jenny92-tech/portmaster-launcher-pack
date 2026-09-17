#!/bin/sh
# INPUT:  /proc 中 godot.mono 进程信息、dmesg、date/awk
# OUTPUT: /tmp/rss.csv 的每秒内存和 OOM 采样
# POS:    记录设备端 STS2 进程存活与 Mali 内存压力
# Watch the godot.mono game process (by /proc/<pid>/comm), sample every second.
OUT=/tmp/rss.csv
echo "epoch,pid,vm_kb,rss_kb,mali_notifier_kb,note" > "$OUT"
last_oom=""
last_mali=""

find_godot() {
  for p in /proc/[0-9]*; do
    comm=$(cat "$p/comm" 2>/dev/null)
    [ "$comm" = "godot.mono" ] && { echo "${p#/proc/}"; return; }
  done
}

while :; do
  pid=$(find_godot)
  if [ -z "$pid" ]; then
    echo "$(date +%s),,,,godot-gone" >> "$OUT"
    sleep 1
    continue
  fi
  vm_kb=$(awk '/^VmSize:/{print $2}'  /proc/$pid/status 2>/dev/null)
  rss_kb=$(awk '/^VmRSS:/{print $2}' /proc/$pid/status 2>/dev/null)
  mali_kb=$(dmesg 2>/dev/null | grep -E "mali .* OOM notifier: tsk godot.mono" | tail -1 | grep -oE "[0-9]+ kB" | head -1 | awk '{print $1}')
  note=""
  oom=$(dmesg 2>/dev/null | grep "Killed process" | tail -1)
  if [ -n "$oom" ] && [ "$oom" != "$last_oom" ]; then
    note="OOM"
    last_oom="$oom"
  fi
  echo "$(date +%s),$pid,$vm_kb,$rss_kb,$mali_kb,$note" >> "$OUT"
  sleep 1
done
