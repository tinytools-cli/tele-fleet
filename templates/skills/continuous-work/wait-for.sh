#!/bin/bash
# Wake helper for the continuous-work skill. Run it with run_in_background; it exits when the
# thing you wait on is finished, which wakes the session.
#   wait-for.sh until "<shell cmd>"   the command succeeds (checked every WAIT_EVERY s, default 60)
#   wait-for.sh pid N [N...]          every listed process on this machine has exited
set -u
EVERY="${WAIT_EVERY:-60}"
case "${1:-}" in
  until)
    shift
    [ -n "${1:-}" ] || { echo "usage: wait-for.sh until '<cmd>'"; exit 2; }
    until bash -c "$1" >/dev/null 2>&1; do sleep "$EVERY"; done
    echo "condition met: $1" ;;
  pid)
    shift
    for p in "$@"; do
      while kill -0 "$p" 2>/dev/null; do sleep "$EVERY"; done
      echo "process $p has exited"
    done ;;
  *) echo "usage: wait-for.sh until '<cmd>' | pid N..."; exit 2 ;;
esac
