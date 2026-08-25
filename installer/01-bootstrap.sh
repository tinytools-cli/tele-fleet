#!/usr/bin/env bash
# Stage 1 — bare VPS to a base system that can host agents.
. "$(dirname "$0")/lib.sh"

need_root() { [ "$(id -u)" = 0 ] || { warn "not root — skipping package install; re-run with sudo for a full bootstrap"; return 1; }; }

# nodejs/npm are NOT optional -- Claude Code is installed with npm, and a
# clean-machine run (an internal ticket) got as far as "npm not found ... the fleet cannot
# start without it" because this list omitted them. The development machine had
# Node already, so the gap was invisible until the container test.
PKGS="tmux git curl jq python3 python3-venv python3-pip nodejs npm ufw fail2ban ca-certificates"

if need_root; then
  step "packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || warn "apt update failed — continuing"
  # shellcheck disable=SC2086
  apt-get install -y -qq $PKGS >/dev/null 2>&1 && ok "installed: $PKGS" || warn "some packages failed"

  step "firewall"
  # DENY INCOMING BY DEFAULT, and allow SSH before enabling. Enabling ufw
  # without an ssh rule is the classic way to lock yourself out of a VPS you
  # are currently ssh'd into, and it happens on the very first run.
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1
  ufw --force default deny incoming >/dev/null 2>&1
  ufw --force default allow outgoing >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1 && ok "ufw enabled (ssh allowed first)" || warn "ufw not enabled"
  systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban running" || warn "fail2ban not started"
fi

# ~/.local/bin MUST BE ON PATH, and creating it is not enough. Debian's default
# ~/.profile adds it only if the directory EXISTS when the login shell starts --
# so installing tix into a directory created moments earlier leaves a working
# binary the user cannot run. The clean-machine test printed "cloned to
# ~/.local/share/tix" and "add $HOME/.local/bin to PATH" in the same breath,
# which is a fancy way of saying it did not work.
step "PATH"
mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "~/.local/bin already on PATH" ;;
  *)
    for rc in "$HOME/.profile" "$HOME/.bashrc"; do
      [ -f "$rc" ] || continue
      grep -q 'HOME/.local/bin' "$rc" 2>/dev/null && continue
      printf '\n# added by the fleet installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    done
    export PATH="$HOME/.local/bin:$PATH"
    ok "~/.local/bin added to PATH (new shells pick it up; this run already has it)" ;;
esac

step "verify"
# ONE ACTIONABLE MESSAGE, not a warning followed by an unrelated death.
# Found by running this on a clean machine (an internal ticket): a non-root run warned
# "skipping package install", then died with "tmux is required and missing" --
# two messages that are the SAME problem, presented as though they were not.
# The reader is left thinking a dependency is broken rather than realising they
# simply needed sudo. It never surfaced in development because the development
# machine already had every one of these installed.
missing=""
for b in tmux git curl python3; do
  have "$b" && ok "$b present" || missing="$missing $b"
done
if [ -n "$missing" ]; then
  if [ "$(id -u)" != 0 ]; then
    die "missing:$missing

     These are installed by this stage, but it needs root to do it. Re-run:
         sudo ./install.sh
     (the rest of the install runs as you, not as root)"
  fi
  die "missing after install attempt:$missing
     Install them by hand and re-run: ./install.sh --resume"
fi
# Lingering matters: without it, user services die when the install session
# ends and the fleet quietly disappears the moment you log out.
if have loginctl; then
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
    && ok "linger enabled (agents survive logout)" \
    || warn "could not enable linger — agents may stop when you log out"
fi
