#!/usr/bin/env bash
# PUBLISH GATE. Refuses to pass if anything personal is in the tracked files.
#
# A PROGRAM, NOT A PROMISE. The judgement "I looked and it seemed fine" is
# exactly what fails here: this is ~900 lines across 17 files, and a review that
# is 99% accurate still leaks. Worse, the leak is silent — nothing goes wrong at
# publish time, it just sits in a public repo.
#
# CHECKS WHAT GIT WOULD PUBLISH (git ls-files), NOT the working directory. Those
# differ on purpose: INVENTORY.md is a real working document that NAMES the
# values to strip, so it must exist on disk and must never be tracked. Scanning
# the directory would fail forever; scanning the tree would have missed a file
# that was accidentally added.
#
# TWO LAYERS OF PATTERNS.
#   1. Generic shapes, below, in this file: paths, ids, tokens, keys, tailnet
#      addresses, email addresses. True for anyone's machine, safe to publish.
#   2. A PRIVATE blocklist of the specific names, companies, agent names and
#      hostnames from the machine this was extracted from. Those words ARE the
#      leak, so a public list of them would publish exactly what the gate exists
#      to stop. They live outside the repo, one extended regex per line, in
#        $SCRUB_PRIVATE_PATTERNS   (default ~/.config/tele-fleet/scrub-private.txt)
#      Blank lines and lines starting with # are ignored.
#
# A missing private file is NOT a pass: only half the gate ran. It warns and
# fails, unless SCRUB_ALLOW_GENERIC_ONLY=1 says that is deliberate (for example
# a contributor who has no private list of their own).
#
#   scripts/scrub.sh          -> exit 0 clean, 1 dirty, 2 private list missing
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Patterns are deliberately about SHAPE, not one person: any installer built
# from someone's live machine leaks the same categories.
# EXTENDED regex syntax, because grep is called with -E. The first version of
# this list was written in BASIC-regex style (\{9,\}), which -E reads as a
# LITERAL brace — so six of these eight patterns silently matched nothing and
# the gate passed everything. It only surfaced because the planted-leak test
# caught the home path and NOT the chat id sitting on the line above it.
# A guard that cannot fail is worse than no guard: it produces confidence.
PATTERNS=(
  '/home/[a-z][a-z0-9_-]*'                      # a real home path from the source machine
  '[0-9]{9,}'                                   # chat ids, user ids, long numeric handles
  '[0-9]{8,10}:[A-Za-z0-9_-]{30,}'              # telegram bot tokens
  'sk-[A-Za-z0-9]{20,}'                         # api keys
  'ghp_[A-Za-z0-9]{20,}'                        # github tokens
  '100\.(6[4-9]|[7-9][0-9]|1[0-2][0-9])\.[0-9]{1,3}\.[0-9]{1,3}'  # tailnet CGNAT range
  '[a-z0-9-]+\.ts\.net'                        # tailnet hostnames
  '\btail[0-9a-f]{5,}\b'                       # a bare tailnet name, no .ts.net after it
  '@[a-z0-9_]{3,}_bot'                          # bot usernames
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'          # private key material
)
LABELS=( "source home path" "long numeric id (chat/user id)" "telegram bot token"
         "api key" "github token" "tailnet ip" "tailnet hostname" "tailnet name" "bot username"
         "private key" )

# Email addresses are checked separately: placeholders and noreply addresses
# are legitimate in docs and commit trailers, a real inbox is not.
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
EMAIL_OK='@(example\.(com|org|net)|anthropic\.com|users\.noreply\.github\.com)\b|noreply@'

fail=0
files=$(git ls-files 2>/dev/null)
[ -n "$files" ] || { echo "scrub: no tracked files — nothing to check" >&2; exit 1; }

block() {  # block <label> <hits>
  printf '  BLOCKED — %s:\n' "$1" >&2
  printf '%s\n' "$2" | sed 's/^/      /' >&2
  fail=1
}

for i in "${!PATTERNS[@]}"; do
  hits=$(printf '%s\n' "$files" | xargs grep -nE -e "${PATTERNS[$i]}" 2>/dev/null \
         | grep -v '^scripts/scrub.sh:' | head -5)
  [ -n "$hits" ] && block "${LABELS[$i]}" "$hits"
done

hits=$(printf '%s\n' "$files" | xargs grep -noE "$EMAIL_RE" 2>/dev/null \
       | grep -vE "$EMAIL_OK" | grep -v '^scripts/scrub.sh:' | head -5)
[ -n "$hits" ] && block "an email address" "$hits"

# The private blocklist. Applied to EVERY tracked file, this one included: the
# point of moving the names out is that this file no longer carries them.
private="${SCRUB_PRIVATE_PATTERNS:-$HOME/.config/tele-fleet/scrub-private.txt}"
private_ran=0
if [ -r "$private" ]; then
  n=0
  while IFS= read -r pat || [ -n "$pat" ]; do
    n=$((n + 1))
    case "$pat" in ''|'#'*) continue ;; esac
    private_ran=$((private_ran + 1))
    hits=$(printf '%s\n' "$files" | xargs grep -nE -e "$pat" 2>/dev/null | head -5)
    [ -n "$hits" ] && block "private blocklist, line $n" "$hits"
  done < "$private"
  [ "$private_ran" -gt 0 ] || {
    echo "scrub: WARNING — private blocklist $private has no patterns" >&2; private_ran=0; }
fi

# Files that must never be tracked at all, whatever is in them.
for forbidden in INVENTORY.md fleet.conf scrub-private.txt; do
  printf '%s\n' "$files" | grep -qE "(^|/)$forbidden\$" && {
    printf '  BLOCKED — %s is tracked and must never be published\n' "$forbidden" >&2; fail=1; }
done
printf '%s\n' "$files" | grep -qE '\.env$|^secrets/' && {
  printf '  BLOCKED — a secrets file or .env is tracked\n' >&2; fail=1; }

if [ "$fail" != 0 ]; then
  echo "scrub: DIRTY — fix the above before publishing" >&2
  exit 1
fi

if [ "$private_ran" = 0 ]; then
  echo "scrub: WARNING — no private blocklist at $private" >&2
  echo "       Only the GENERIC checks ran (paths, ids, tokens, keys, tailnet, email)." >&2
  echo "       Names, companies and hostnames from your machine were NOT checked." >&2
  if [ "${SCRUB_ALLOW_GENERIC_ONLY:-0}" = 1 ]; then
    echo "scrub: generic checks clean; SCRUB_ALLOW_GENERIC_ONLY=1, so passing" >&2
    exit 0
  fi
  echo "       Create that file (see README), or set SCRUB_ALLOW_GENERIC_ONLY=1 to accept this." >&2
  exit 2
fi

echo "scrub: clean — $(printf '%s\n' "$files" | wc -l) tracked files carry nothing personal ($private_ran private patterns)"
exit 0
