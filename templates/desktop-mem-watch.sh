#!/usr/bin/env bash
# desktop-mem-watch.sh -- warn an agent BEFORE its desktop runs out of memory.
#
# WHY. Each desktop runs with a memory cap (docker --memory). The browser inside cannot see that
# cap, so it never discards tabs on its own: it grows until the kernel OOM-kills its renderers and
# tabs turn into "Aw, Snap". The agent finds out by failing. This tells it first, through the one
# channel it is guaranteed to read: desktop.sh prints $DESKTOP_ROOT/<name>/.mem-warn on every
# command, which is exactly when the agent is using the browser.
#
# Zero tokens, wakes no one, sends nothing anywhere. Reads the HOST cgroup -- no docker exec.
# Run it every minute from cron or a systemd timer:
#   * * * * * $HOME/.fleet/bin/desktop-mem-watch.sh >/dev/null 2>&1
#
#   >= WARN%  of the cap   -> write .mem-warn ("close tabs now")
#   <  CLEAR% of the cap   -> remove it
#   oom_kill count grew    -> .mem-warn says tabs WERE killed, and a line goes to mem-watch.log
#
# Env: DESKTOP_ROOT (default ~/.fleet/desktops), MEMWATCH_PCT (85), MEMWATCH_CLEAR (80)
set -uo pipefail
ROOT="${DESKTOP_ROOT:-$HOME/.fleet/desktops}"; LOG="$ROOT/mem-watch.log"
WARN="${MEMWATCH_PCT:-85}"; CLEAR="${MEMWATCH_CLEAR:-80}"
[ "$CLEAR" -gt "$WARN" ] && CLEAR="$WARN"
log(){ printf '%s\t%s\n' "$(date -Iseconds)" "$*" >> "$LOG"; }

for name in $(docker ps --format '{{.Names}}' | grep -E -- '-desktop$'); do
  a="${name%-desktop}"; D="$ROOT/$a"; [ -d "$D" ] || continue
  id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || continue
  # The cgroup path depends on docker's cgroup driver: systemd puts it under system.slice,
  # cgroupfs under docker/. Try both rather than assuming the machine this was written on.
  cg=""
  for c in "/sys/fs/cgroup/system.slice/docker-$id.scope" "/sys/fs/cgroup/docker/$id"; do
    [ -r "$c/memory.current" ] && { cg="$c"; break; }
  done
  [ -n "$cg" ] || { echo "$a: no cgroup v2 memory files found"; continue; }
  cur=$(<"$cg/memory.current"); max=$(<"$cg/memory.max")
  case "$max" in max|"") echo "$a: no memory limit set (docker --memory)"; continue ;; esac
  oom=$(awk '$1=="oom_kill"{print $2}' "$cg/memory.events"); oom=${oom:-0}
  pct=$(( cur * 100 / max )); gb=$(awk -v m="$max" 'BEGIN{printf "%g", m/1024/1024/1024}')
  ST="$D/.memstate"; last_oom=$oom; over=0
  [ -f "$ST" ] && . "$ST" 2>/dev/null   # sets last_oom over
  WF="$D/.mem-warn"
  if [ "$oom" -gt "$last_oom" ]; then
    killed=$(( oom - last_oom ))
    log "$a OOM: $killed kill(s) (total $oom), memory ${pct}% of ${gb}G"
    echo "WARNING: your desktop ran out of memory (${gb} GB limit) and $killed browser process(es) were KILLED -- tabs may show 'Aw, Snap'. Close tabs you are not using now." > "$WF"
    over=1
  elif [ "$pct" -ge "$WARN" ]; then
    echo "WARNING: your desktop is at ${pct}% of its ${gb} GB memory limit -- close tabs you are not using now, or browser tabs will be killed." > "$WF"
    [ "$over" = 1 ] || { log "$a crossed ${WARN}%: ${pct}% of ${gb}G"; over=1; }
  elif [ "$pct" -lt "$CLEAR" ]; then
    rm -f "$WF"; over=0
  fi
  printf 'last_oom=%s\nover=%s\n' "$oom" "$over" > "$ST"
  echo "$a: ${pct}% of ${gb}G, oom_kill=$oom"
done
