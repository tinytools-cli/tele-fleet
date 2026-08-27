<img src="docs/logo.jpg" alt="Telefleet — agents, sessions, tickets, connected" width="320">

# Telefleet

*Agents. Sessions. Tickets. Connected.*

Sets up a fleet of [Claude Code](https://claude.com/claude-code) agents on a
Linux server. Each agent gets its own working directory, its own Telegram bot,
its own identity, and comes back after a reboot.

    git clone <this repo> && cd agent-fleet-installer
    ./install.sh

It interviews you — how many agents, what they are called, what each one does —
then installs everything and starts them.

**`install.sh` is a plain shell script. A human runs it, and no agent is
needed** — which is the only thing that can work, because on a bare server there
is no agent yet. Bash, coreutils, curl and python3 are the whole dependency list.

### Two ways to run it

**Interactive (a person, first time).** Just `./install.sh`. It asks the
questions and explains each one.

**Unattended (an agent, or a rebuild).** Write `~/fleet.conf` and drop the bot
tokens in yourself, then nothing prompts:

    cat > ~/fleet.conf <<'EOF'
    OPERATOR=Sam
    TIMEZONE=UTC
    AGENTS=nova,lyra
    MAIN=nova
    ROLE_nova=engineering
    ROLE_lyra=research
    EOF
    mkdir -p ~/.fleet/secrets && chmod 700 ~/.fleet/secrets
    printf 'TELEGRAM_BOT_TOKEN=...\n' > ~/.fleet/secrets/telegram-nova.env

    ./install.sh --resume

Every stage skips what is already done, so this is safe to re-run and safe to
resume after a failure. Tokens are still checked against Telegram — a
pre-seeded token that has been revoked is reported, not assumed good.

## What you do vs what it does

**You authenticate.** Your Claude login, and one Telegram bot per agent from
BotFather (it walks you through this and checks each token actually works).

**It does the rest.** Packages, firewall, Claude Code, [tix](https://github.com/tinytools-cli/tix)
for shared ticket tracking, agent directories and identities, systemd units,
the ticket-enforcement hook, and starting everything.

## Read this before you run it

**Cost.** Each agent is a full Claude Code session. Ten agents on a single plan
hit the usage limit on the machine this was extracted from — four agents were
blocked for over an hour. **Start with two or three.** You can add more later;
you cannot un-spend a plan.

**Hardware.** 4 vCPU and 15 GiB is the shape this was built on, and 4 cores was
already the binding constraint on how many agents could work at once. Agents are
cheap when idle and expensive when busy.

**It changes your machine.** It installs packages, enables a firewall (allowing
SSH first), and adds a `Stop` hook to `~/.claude/settings.json` — merged, never
overwritten. Read `installer/*.sh` first if that matters to you; they are short
and commented.

## After it finishes

Talk to your **main agent** on Telegram. It is the engineering agent for the
server: it introduces itself, asks who you are and what you want the fleet to
do, writes that down, and then asks permission to finish its own installation.
Some setup is deliberately left for it to complete with you.

Then run the checks:

    tests/acceptance.sh

These ask whether things **work**, not whether they started — every one is
written against a failure that actually happened, each of which looked healthy
at the time: a dead agent reported as `active`, an agent running with its
messaging silently dead, a saved bot token the service had never accepted.

## Layout

    install.sh              interview, then run the stages in order
    installer/01-bootstrap  packages, firewall, survive-logout
    installer/02-claude-tix Claude Code; tix cloned from its own repo
    installer/03-fleet      directories, identities, systemd units
    installer/04-telegram   guided bot setup, tokens verified before storing
    installer/05-rules      shared operating rules, operator profile, guard
    installer/06-start      start the agents, then check they came up
    templates/              what gets written into your fleet
    tests/acceptance.sh     does this actually work
    scripts/scrub.sh        publish gate: refuses to ship anything personal

## Notes

**Agent names are permanent.** The name is the identity — it is also the
directory, the tmux session, the service instance and the ticket assignee.
Renaming is not supported: delete the agent and create a new one.

**tix is a dependency, not a copy.** It is cloned from its own repository so it
stays current and stays maintained by its owner.

**Nothing personal ships.** `scripts/scrub.sh` is a publish gate that refuses if
tracked files contain home paths, chat ids, tokens, keys or hostnames. It runs
against what git would publish, not the working directory.
