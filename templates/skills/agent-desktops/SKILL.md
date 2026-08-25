---
name: agent-desktops
description: How to use the browser desktops on this server to do real work on the web — sign-up forms, dashboards, consoles, portals, anything with no API. Covers which desktop is yours (one per agent, named in your config), the CLI-only rule (screenshots are BLOCKED — use read for what a page says and find for where to click), the one-agent-at-a-time lock, and the ONE boundary that matters: you do the work, the operator only does payments and authentication. Use when a task needs a browser, when an API or CLI does not exist for something, when you hit a login/paywall, or when you are about to tell the operator "you'll need to do this yourself".
---

# The desktops — you drive, he authenticates

There are real Linux desktops on this box with a real Chrome in them. They exist so you can
**do the work yourself** instead of writing the operator instructions and waiting.

## The rule, in his words

> "They do most things unless it's payments or authentication... The agents are better than me
> for filling out stuff. Also if they are not sure they can ask about info they don't have."

**Read that as a job description.** Filling in a 40-field vendor form, clicking through a console,
finding the setting three menus deep, copying a value out of a dashboard — that is your work, not
his. He is a COO on a phone. Handing him a checklist of things you could have done is the failure
mode this exists to remove.

| | |
|---|---|
| **You do** | forms, sign-ups, configuration, navigation, reading dashboards, downloading, copying values, filling in everything you have |
| **He does** | **payments** — entering card or bank details, confirming a charge<br>**authentication** — passwords, 2FA codes, OAuth consent, CAPTCHA, anything that proves he is him |
| **You ask** | any fact you do not have — his address, a phone number, which plan, which of two options |

**Drive right up to the boundary before you stop.** Fill the entire form, then stop at the card
field and tell him it is ready. Do not stop at the first sight of a signup page. "I got as far as
payment, everything else is filled in, one tap from you" is the shape he wants — not "this needs
your account, please do it."

**Never enter a credential yourself, even if you can see one.** That is his to type, every time.

## Which desktop is yours

**It is automatic — just run the command.** `desktop.sh` routes on `TIX_AGENT`:

- **A desktop named after you** if your operator created one (`<yourname>-desktop`).
- **A shared one** otherwise.

`desktop.sh` works it out from your agent identity. It does **not** guess: if it
cannot tell who is asking, it refuses and lists what exists, because guessing
once put an agent onto a colleague's signed-in browser.

Override only when you mean it: `DESKTOP=<name> ~/.fleet/bin/desktop.sh ...`

⚠️ **Do not work on a desktop that is not yours.** Other people's desktops have
their accounts signed in — mail, chat, consoles. Logging into your own things on
someone else's screen mixes identities and can sign them out of something they
need.

## The loop: read, act, verify

    ~/.fleet/bin/desktop.sh url https://example.com/signup
    ~/.fleet/bin/desktop.sh read                    # what does the page SAY?
    ~/.fleet/bin/desktop.sh find "#email"           # WHERE is it? -> screen x,y
    ~/.fleet/bin/desktop.sh click 640 420
    ~/.fleet/bin/desktop.sh type "the operator"
    ~/.fleet/bin/desktop.sh key Tab
    ~/.fleet/bin/desktop.sh read                    # did it take?

### Screenshots are OFF. You read, control and execute through the CLI.

`desktop.sh shot` **refuses by default.** Set on the operator's instruction, 2026-08-25, and it is a
block rather than advice because advice did not work — agents kept photographing pages in order to
*read* them.

**You do not need it.** Everything an ordinary task requires has a text answer:

| Question | Command |
|---|---|
| What does the page say? | `read` |
| **Where do I click?** | **`find "<css selector>"`** or `find --text "Send"` |
| Did anything change? | `pagetitle` |

`find` returns **exact screen coordinates straight from the DOM** — ready to pass to `click`, with
no image involved:

    $ desktop.sh find "input[aria-label*=Search]"
    input#topSearchInput     532,136    (409x21)  Search
    -> click with: desktop.sh click <x> <y>

**Coordinates from `find` cannot drift from what is rendered. Coordinates from a picture can** — on
2026-08-25 a half-scale screenshot aimed every click on every desktop at the wrong place for hours,
which opened reply drafts on real customer mail. The screen also **resizes with whoever is viewing
it**, so a saved image is stale by nature.

**The escape hatch, for when there is genuinely nothing to read:** a native XFCE dialog, a window
that will not paint, a rendering fault. CDP only sees Chrome pages, so those have no text interface:

    SHOT_OK=1 ~/.fleet/bin/desktop.sh shot

Use it on purpose, not as a habit. If you are reaching for it to find out what a page *says* or
*where a control is*, the answer is `read` or `find`.

### The old rule, kept because the reasoning still applies

`read` pulls the page text over CDP. `shot` returns an image you must Read, and images are
**the single largest cost on the plan** — one session hit 190 MB, roughly half of it screenshots
(an internal ticket). `read` is about **1% of the cost** of a screenshot.

- **"What does it say / did it work / what is the error?"** → `read`
- **"Did anything change at all?"** → `pagetitle`, cheaper still
- **"Where do I click?"** → `shot`. That is what it is for. Take it, get your coordinates, act.

Do not photograph a page to check a value you could have read. `shot` prints this reminder every
time it runs; that is deliberate.

### Always look immediately before you click

Coordinates from a stale screenshot click the wrong thing, and **you will not notice until
something odd has already happened**. Look, then act, then verify. Every time.

## One agent at a time

Each desktop takes an exclusive lock per command. If someone else is driving:

    desktop '<name>' is busy — another agent is driving it.
    USE THIS ONE INSTEAD:  DESKTOP=<other> ... <same command>

**Believe it and wait, or take the suggestion only if the work genuinely suits that screen.** Two
agents on one screen has already happened: a click meant for a dialog landed on the WhatsApp tab
because the other session moved focus mid-action. Do not invent a way around the lock.

## Commands

| | |
|---|---|
| `read` | page text over CDP — **your default** |
| `pagetitle` | title of the focused window — cheapest possible check |
| `find` | **screen coordinates of an element, from the DOM — no image** |
| `shot` | PNG path to Read — **refused unless `SHOT_OK=1`** |
| `url <address>` | open an address in the running Chrome |
| `tab` | new tab |
| `click` / `rclick` / `dblclick` `<x> <y>` | mouse |
| `move <x> <y>` · `where` | pointer |
| `type "text"` | type at the focus |
| `key <keyspec>` | `Return`, `ctrl+l`, `alt+Tab` |
| `scroll up\|down [n]` | wheel |

Input goes through **xdotool — real X events**, indistinguishable from a hand on a mouse. That is
why sites do not flag it the way they flag CDP-synthesised clicks.

## When you need something from him

**Never a bare open question.** Give numbered options he can tap, put them last, recommend one:

    1. Use the home address (recommended) — it's on file for billing
    2. Use the other address
    3. Something else — tell me

Over Telegram use `ask_user` for real tappable buttons, and **number the buttons to match the
list**. In a terminal, `AskUserQuestion`. Printed text reaches him nowhere.

**Batch it.** Read the whole form first and ask for everything missing in one message. Asking
three times for three fields is three interruptions for one task.

**Then hand it back properly.** Say what is done, what is left, and exactly what he has to tap:
*"Vendor form filled — name, address, tax ID, contacts. Stops at the card field. One tap: enter
card, hit Submit."*

## Do not

- **Do not enter a password, 2FA code, or card number.** Ever. His, every time.
- **Do not sign anything out**, or "clean up" a session you did not create.
- **Do not accept terms or place an order** that costs money without asking first.
- **Do not screenshot to read text or to find a control.** Use `read` and `find`. `shot` is off
  unless you set `SHOT_OK=1`, and that is for things with no text interface at all.
- **Do not work on a desktop that is not yours** unless the lock message sent you there.
- **Do not report success you have not verified.** `read` the page after you act — a click that
  silently did nothing looks exactly like a click that worked.

## When it is broken

Infrastructure belongs to **the infrastructure agent**. A dead container, no route out, a browser that will not load —
tell him rather than restarting things:

    hq desktop list                 # which desktops exist, are they up, where do they egress
    hq bug "<what broke>" --from <you>
