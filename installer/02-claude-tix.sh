#!/usr/bin/env bash
# Stage 2 — Claude Code and tix. You authenticate; this only installs.
. "$(dirname "$0")/lib.sh"

step "Claude Code"
# INSTALL WITHOUT sudo. `npm install -g` as a normal user fails outright
# ("run the command again as root"), and asking people to sudo-install a global
# npm package is both unnecessary and a bad habit. A per-user prefix keeps the
# whole install inside $HOME, which is also what makes the fleet re-installable
# without touching the system.
if have claude; then ok "already installed"
elif have npm; then
  NPM_PREFIX="$HOME/.npm-global"; mkdir -p "$NPM_PREFIX"
  npm config set prefix "$NPM_PREFIX" >/dev/null 2>&1
  export PATH="$NPM_PREFIX/bin:$PATH"
  for rc in "$HOME/.profile" "$HOME/.bashrc"; do
    [ -f "$rc" ] || continue
    grep -q 'npm-global/bin' "$rc" 2>/dev/null && continue
    printf '\n# added by the fleet installer\nexport PATH="$HOME/.npm-global/bin:$PATH"\n' >> "$rc"
  done
  npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 \
    && ok "installed to $NPM_PREFIX (no sudo needed)" \
    || warn "npm install failed — run: npm install -g @anthropic-ai/claude-code"
else
  warn "npm not found — stage 1 installs it; run: sudo ./install.sh"
fi
have claude && ok "claude on PATH" || warn "claude NOT on PATH — the fleet cannot start without it"

step "tix"
# A DEPENDENCY, NEVER A VENDORED COPY -- it is versioned and maintained
# separately, and copying it would fork it on day one.
#
# INSTALLED AS THE PYTHON PACKAGE IT IS. The first version cloned the repo and
# symlinked $repo/tix, which is how it happens to sit in its author's working
# copy. In the PUBLISHED package `tix` is the python package DIRECTORY and the
# command comes from [project.scripts]. So the symlink pointed at a directory
# and every tix call died with "Is a directory". Only a clean-machine run found
# it (an internal ticket) -- this box already had a working tix on PATH.
#
# Into its own venv on purpose: Ubuntu 24.04 refuses `pip install --user`
# (PEP 668, externally-managed), and a venv sidesteps that argument entirely
# rather than passing --break-system-packages and hoping.
TIX_VENV="$HOME/.local/share/tix-venv"
if have tix; then ok "already installed"
else
  mkdir -p "$HOME/.local/bin"
  if python3 -m venv "$TIX_VENV" >/dev/null 2>&1 \
     && "$TIX_VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 \
     && "$TIX_VENV/bin/pip" install -q "git+https://github.com/tix-cli/tix" >/dev/null 2>&1 \
     && [ -x "$TIX_VENV/bin/tix" ]; then
    ln -sf "$TIX_VENV/bin/tix" "$HOME/.local/bin/tix"
    ok "installed into its own venv"
  else
    warn "tix install failed — the ticket workflow will be unavailable"
  fi
fi
# PROVE IT RUNS. `command -v` only proves a name resolves; it resolved happily
# to a directory before this was fixed.
if tix --help >/dev/null 2>&1; then ok "tix runs"
else warn "tix does not run — check $TIX_VENV"; fi
