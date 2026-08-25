#!/usr/bin/env bash
# Snapshot the fleet's state into a git repo. Do not back it up — VERSION it.
#
# Everything worth keeping is markdown already or a small SQLite file, and
# `.dump` turns SQLite into text. Text in git gives you a restore point AND a
# line-by-line history of who changed what — one mechanism, both jobs.
#
# THREE DELIBERATE CHOICES, each the thing that usually goes wrong:
#
#  1. ALLOWLIST, NEVER .gitignore. A denylist fails OPEN: the day somebody drops
#     a new secret into a directory nobody thought to exclude, it ships. Here
#     nothing is copied unless it is named below, so the failure mode of a new
#     file is "missing", not "leaked".
#
#  2. RESTORE IS VERIFIED EVERY RUN. A backup nobody has restored is a rumour.
#     Each run rebuilds the database from its own dump and counts the rows; if
#     that fails, the run fails loudly rather than committing a corpse.
#
#  3. SECRETS ARE NOT BACKED UP, ON PURPOSE. Bot tokens and auth are RE-ISSUABLE
#     — a new one takes a minute. Copying them creates a second place to leak
#     from and buys nothing. What is preserved is the PROCEDURE for reissuing
#     them, which lives in the docs and IS backed up here.
set -uo pipefail
FLEET_CONF="${FLEET_CONF:-$HOME/fleet.conf}"
REPO="$HOME/.fleet/state"
TIX_DB="$(ls "$HOME/.local/share/tix"/*.db 2>/dev/null | head -1)"
[ -n "${TIX_DB:-}" ] || TIX_DB="$HOME/.tix/tix.db"

mkdir -p "$REPO"
[ -d "$REPO/.git" ] || { git -C "$REPO" init -q; git -C "$REPO" commit -q --allow-empty -m "fleet state" 2>/dev/null; }

copy() { [ -e "$1" ] || return 0; mkdir -p "$REPO/$(dirname "$2")"; cp -a "$1" "$REPO/$2" 2>/dev/null; }

# ── the allowlist ───────────────────────────────────────────────────────────
copy "$HOME/AGENTS.md"        "rules/AGENTS.md"
copy "$HOME/OPERATOR.md"      "rules/OPERATOR.md"
copy "$FLEET_CONF"            "rules/fleet.conf"          # names and roles; NO tokens
copy "$HOME/.claude/settings.json" "rules/settings.json"
for d in "$HOME"/Projects/*/; do
  a=$(basename "$d")
  for f in CLAUDE.md RUNBOOK.md RUNLOG.md; do copy "$d$f" "agents/$a/$f"; done
done
copy "$HOME/.fleet/bin"       "scripts"
for u in "$HOME"/.config/systemd/user/*.service "$HOME"/.config/systemd/user/*.timer; do
  [ -e "$u" ] && copy "$u" "systemd/$(basename "$u")"
done

# ── the database, as text, then PROVE it restores ───────────────────────────
if [ -f "$TIX_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "$REPO/tix"
  sqlite3 "$TIX_DB" .dump > "$REPO/tix/tix.sql" 2>/dev/null || { echo "dump failed" >&2; exit 1; }
  tmp=$(mktemp -d)
  if sqlite3 "$tmp/verify.db" < "$REPO/tix/tix.sql" 2>/dev/null; then
    n=$(sqlite3 "$tmp/verify.db" "select count(*) from tickets;" 2>/dev/null)
    rm -rf "$tmp"
    case "$n" in ''|*[!0-9]*) echo "restore produced no readable tickets — refusing to commit" >&2; exit 1 ;; esac
    echo "  restore verified: $n tickets rebuilt from the dump"
  else
    rm -rf "$tmp"; echo "the dump does NOT restore — refusing to commit" >&2; exit 1
  fi
fi

cd "$REPO" || exit 1
git add -A >/dev/null 2>&1
git diff --cached --quiet 2>/dev/null && { echo "  no changes"; exit 0; }
git -c user.name=fleet -c user.email=fleet@localhost commit -q -m "state $(date -u +%Y-%m-%dT%H:%MZ)" \
  && echo "  committed to $REPO"
