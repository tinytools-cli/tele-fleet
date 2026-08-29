#!/usr/bin/env python3
"""Make the Telegram plugin's state dir configurable per bot.

Upstream hardcodes STATE_DIR to ~/.claude/channels/telegram. That is fine for
one bot and fatal for two: they would share access.json, the .env holding the
token, messages.db, and -- worst -- data/telegram.lock. Two instances on one
lock is exactly the single-instance race that silently killed inbound polling
on once; with two real bots it would be permanent rather than a race.

Honouring TELEGRAM_STATE_DIR lets each agent own its own directory while the
default path is byte-identical for anyone who does not set it.

Idempotent. Hard-exits if the anchor stops matching, so an upstream refactor
surfaces loudly instead of silently reintroducing the collision.
"""
import sys, pathlib

p = (
    pathlib.Path(sys.argv[1])
    if len(sys.argv) > 1
    else pathlib.Path.home() / ".claude/plugins/cache/claude-plugins-official/telegram/0.0.7/server.ts"
)
src = p.read_text()

MARK = "TELEGRAM_STATE_DIR"
if MARK in src:
    print("already present")
    sys.exit(0)

ANCHOR = 'const STATE_DIR = join(homedir(), ".claude", "channels", "telegram");'
if ANCHOR not in src:
    print("ANCHOR NOT FOUND — upstream changed STATE_DIR; refusing to patch", file=sys.stderr)
    sys.exit(1)

REPLACEMENT = (
    '// Per-bot state. Each Telegram bot needs its own access.json, .env,\n'
    '// messages.db and — critically — its own data/telegram.lock: two bots\n'
    '// sharing one lock means only one ever polls, and the other looks alive\n'
    '// while dropping every inbound message.\n'
    'const STATE_DIR = process.env.TELEGRAM_STATE_DIR\n'
    '  ? resolve(process.env.TELEGRAM_STATE_DIR)\n'
    '  : join(homedir(), ".claude", "channels", "telegram");'
)
src = src.replace(ANCHOR, REPLACEMENT, 1)

# `resolve` may not be imported yet.
if "resolve" not in src.split("const STATE_DIR")[0].split("from \"node:path\"")[0][-200:]:
    import re
    m = re.search(r'import \{([^}]*)\} from "node:path";', src)
    if m and "resolve" not in m.group(1):
        src = src[:m.start(1)] + m.group(1).rstrip() + ", resolve" + src[m.end(1):]

p.write_text(src)
print("patched")
