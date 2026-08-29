# Changelog

## v0.2.0

**Desktop tooling brought up to date** — this is the release to take if you want the
virtual-desktop work.

- `desktop.sh` roughly doubles in size: tab listing and switching (`tabs`, `focus <n>`),
  per-desktop claims so two agents cannot interleave on one screen (`claim`, `release`,
  `claims`, `waiting`), `revive` for wedged renderers, an append-only usage log, reading
  inside same-origin iframes, and a refusal to emit click coordinates from a collapsed
  viewport.
- **Screen-coordinate fix.** The mapping added the window origin *unscaled* and then scaled
  the element rectangle. Identical at `devicePixelRatio == 1`, and wrong by the whole origin
  on any HiDPI display — where it presented as a Y-axis-only bug, because the X origin
  happens to be zero. Every click on such a screen was landing in the wrong place.
- **`read` and `find` no longer hang.** The reply loop had no timeout of any kind and held
  the shared desktop lock while it waited, so one slow page blocked every agent. Bounded now,
  with a message that says which page never answered.
- **New: `desktop-tabsweep.py` + `desktop-protected.conf`.** Closes idle and excess tabs, and
  will never close anything holding a login session. Skips claimed desktops entirely.
- **Routing is now by convention.** A desktop is chosen from the agent's own name, falling
  back to a shared one — no agent names are baked into the tool.
- **Scrub hardened.** It now also rejects agent names, source-fleet desktop names and private
  tracker keys. Verified by planting a leak and confirming it blocks; the first version of
  those patterns was over-escaped and passed the planted file silently.


All notable changes to tele-fleet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

The installer predates this file — the commits from initial extraction through
the Telefleet rename are not reconstructed here. This is the first tagged
version.

## [0.1.0] - once

First tagged release. Fixes five silent fail-open bugs found auditing a real
install, all filed as GitHub issues and closed against this release:

- The `agent-desktops` skill hardcoded the author's own agent name (`an agent name`) as
  the infrastructure owner. Skill templates now go through the same `{{...}}`
  placeholder substitution `CLAUDE.md` gets, with a new `{{MAIN}}` token.
- `start-agent.sh` silently fell back to expiring interactive-login
  credentials when no long-lived Claude token was set up. It now warns on
  stderr and points at `claude setup-token`.
- `work-guard.sh`'s tix stop-hook adapter was never installed anywhere the
  guard actually looked (`TIX_DIR` vs. tix's real install path), so ticket
  enforcement was silently a no-op. The installer now fetches the adapter
  from upstream tix.
- `~/.fleet/tests/acceptance.sh` — the suite `CLAUDE.main.md` tells agents to
  run — was never installed by `06-start.sh`, so it never existed on a real
  install. Now installed alongside `installer/lib.sh`.
- `work-guard.sh`'s two fail-open exits were silent. Both now say why on
  stderr before exiting 0, so a missing dependency reads as a warning instead
  of being indistinguishable from a working install.

Also fixed two stale `tix-cli` → `tinytools-cli` references left from the
GitHub org rename.
