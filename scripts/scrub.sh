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
#   scripts/scrub.sh          -> exit 0 clean, 1 dirty
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
  '@[a-z0-9_]{3,}_bot'                          # bot usernames
  # PERSONAL NAMES from the machine this was extracted from. Added after the
  # pattern list above passed a file that still said "the owner" three times:
  # the other patterns look for paths, ids and hostnames, and a first name is
  # none of those. A leak does not have to look technical to be a leak.
  'EXAMPLE_OWNER_NAME'
  # AGENT NAMES from the source fleet. Added after a sweep found 'an agent name' and
  # 'agent-desktop' still sitting in shipped comments, having sailed past every
  # check above: the existing patterns hunt paths, ids, hostnames and ONE
  # person's name, and a colleague's first name is none of those. The war
  # stories in these files are the most valuable part of them and must survive
  # -- but with anonymous actors.
  'EXAMPLE_AGENT_NAME'
  'example-agent-desktop'
  # PRIVATE TRACKER KEYS. Ticket keys like these mean nothing to anyone outside
  # the source fleet and quietly advertise its internals.
  '\bEXAMPLE-[0-9]+\b'
)
LABELS=( "source home path" "long numeric id (chat/user id)" "telegram bot token"
         "api key" "github token" "tailnet ip" "tailnet hostname" "bot username"
         "a person's name from the source machine"
         "an agent name from the source fleet"
         "a desktop name from the source fleet"
         "a private tracker key" )

fail=0
files=$(git ls-files 2>/dev/null)
[ -n "$files" ] || { echo "scrub: no tracked files — nothing to check" >&2; exit 1; }

for i in "${!PATTERNS[@]}"; do
  hits=$(printf '%s\n' "$files" | xargs grep -nE "${PATTERNS[$i]}" 2>/dev/null \
         | grep -v '^scripts/scrub.sh:' | head -5)
  if [ -n "$hits" ]; then
    printf '  BLOCKED — %s:\n' "${LABELS[$i]}" >&2
    printf '%s\n' "$hits" | sed 's/^/      /' >&2
    fail=1
  fi
done

# Files that must never be tracked at all, whatever is in them.
for forbidden in INVENTORY.md fleet.conf; do
  printf '%s\n' "$files" | grep -qx "$forbidden" && {
    printf '  BLOCKED — %s is tracked and must never be published\n' "$forbidden" >&2; fail=1; }
done
printf '%s\n' "$files" | grep -qE '\.env$|^secrets/' && {
  printf '  BLOCKED — a secrets file or .env is tracked\n' >&2; fail=1; }

if [ "$fail" = 0 ]; then
  echo "scrub: clean — $(printf '%s\n' "$files" | wc -l) tracked files carry nothing personal"
  exit 0
fi
echo "scrub: DIRTY — fix the above before publishing" >&2
exit 1
