# Changelog

All notable changes to tele-fleet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

The installer predates this file — the commits from initial extraction through
the Telefleet rename are not reconstructed here. This is the first tagged
version.

## [0.1.0] - 2026-08-27

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
