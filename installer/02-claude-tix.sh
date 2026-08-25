#!/usr/bin/env bash
# Stage 2 — Claude Code and tix. You authenticate; this only installs.
. "$(dirname "$0")/lib.sh"

step "Claude Code"
if have claude; then ok "already installed ($(claude --version 2>/dev/null | head -1))"
else
  if have npm; then npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 && ok "installed via npm" || warn "npm install failed"
  else warn "npm not found — install Node, then: npm install -g @anthropic-ai/claude-code"; fi
fi
have claude && ok "claude on PATH" || warn "claude NOT on PATH — the fleet cannot start without it"

step "tix"
# A DEPENDENCY, NEVER A VENDORED COPY. tix is maintained separately and is
# already versioned and public; copying it in would fork it on day one and
# strand this install on whatever we happened to snapshot.
TIX_DIR="$HOME/.local/share/tix"
if have tix; then ok "already installed"
else
  if git clone -q --depth 1 https://github.com/tix-cli/tix "$TIX_DIR" 2>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$TIX_DIR/tix" "$HOME/.local/bin/tix" 2>/dev/null
    [ -f "$TIX_DIR/requirements.txt" ] && pip3 install -q -r "$TIX_DIR/requirements.txt" >/dev/null 2>&1
    ok "cloned to $TIX_DIR"
  else
    warn "could not clone tix — the ticket workflow will be unavailable"
  fi
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) warn "add \$HOME/.local/bin to PATH" ;; esac
