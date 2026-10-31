---
name: agent-desktops
description: How to use the browser desktops on this server to do real work on the web — sign-up forms, dashboards, consoles, portals, anything with no API. Covers which desktop is yours (your own if one is named after you, else a shared default — routed automatically), the CLI-only rule (screenshots are BLOCKED — use read for what a page says, activate/fill/choose to act on it by name), the one-agent-at-a-time lock, and the ONE boundary that matters: you do the work, the operator only does payments and authentication. Use when a task needs a browser, when an API or CLI does not exist for something, when you hit a login/paywall, or when you are about to tell the operator "you'll need to do this yourself".
---

# The desktops — you drive, the operator authenticates

There are real Linux desktops on this box with a real Chrome in them. They exist so you can
**do the work yourself** instead of writing the operator instructions and waiting.

## The rule

**Read this as a job description.** Filling in a 40-field vendor form, clicking through a console,
finding the setting three menus deep, copying a value out of a dashboard — that is your work, not
the operator's. They are usually on a phone, between other things. Handing them a checklist of
things you could have done is the failure mode this exists to remove.

| | |
|---|---|
| **You do** | forms, sign-ups, configuration, navigation, reading dashboards, downloading, copying values, filling in everything you have |
| **The operator does** | **payments** — entering card or bank details, confirming a charge<br>**authentication** — passwords, 2FA codes, OAuth consent, CAPTCHA, anything that proves they are them |
| **You ask** | any fact you do not have — an address, a phone number, which plan, which of two options |

**Drive right up to the boundary before you stop.** Fill the entire form, then stop at the card
field and say it is ready. Do not stop at the first sight of a signup page. "I got as far as
payment, everything else is filled in, one tap from you" is the shape that works — not "this needs
your account, please do it."

**Never enter a credential yourself, even if you can see one.** That is the operator's to type,
every time.

## Which desktop is yours

**It is automatic — just run the command.** `desktop.sh` routes on your `TIX_AGENT`:

1. **Your own**, if one exists for you (`~/.fleet/desktops/<yourname>/` → `<yourname>-desktop`).
2. **The shared default** otherwise (the name in `~/.fleet/desktops/.default`).
3. **Neither → it refuses** and lists what exists. It never guesses, because a guess once put an
   agent onto a colleague's signed-in browser.

Override only when you mean it: `DESKTOP=<name> ~/.fleet/bin/desktop.sh ...`

**A stopped desktop wakes on use.** Idle desktops may be stopped to give memory back; the first
command starts yours again and waits ~20 s for it. That pause is normal, not a fault.

**If a command prints a memory warning, act on it** — close tabs you are not using (`tabs`, then
`close-tab <n>`). Each desktop has a memory cap and the browser cannot see it; past the cap, tabs
get killed.

⚠️ **Do not work on a desktop that is not yours.** Other desktops have other accounts signed in —
mail, chat, consoles. Logging into your own things on someone else's screen mixes identities and
can sign them out of something they need.

## The loop: say, read, act by name, verify

    ~/.fleet/bin/desktop.sh goal "fill in the vendor signup"   # once per task
    ~/.fleet/bin/desktop.sh url https://example.com/signup
    ~/.fleet/bin/desktop.sh read                               # what does the page SAY?
    ~/.fleet/bin/desktop.sh fill --label "Company" "Acme Ltd"  # focus BY NAME, type, verify
    ~/.fleet/bin/desktop.sh choose "Country" "Spain"           # custom listbox, by text
    ~/.fleet/bin/desktop.sh activate --text "Continue"         # click BY NAME, verify
    ~/.fleet/bin/desktop.sh read                               # did it take?
    ~/.fleet/bin/desktop.sh goal --clear

**Prefer `activate` / `fill` / `choose` over `click x y` + `type`.** They find the element in the
DOM, act on it, and then check with the browser whether anything changed — and they say so
plainly when nothing did, when more than one element matched, or when the page could not be read
at all. Those are three different answers and they never collapse into "done".

`click <x> <y>` with coordinates from `find` is still there for things with no usable name.

### Screenshots are OFF. You read, control and execute through the CLI.

`desktop.sh shot` **refuses by default.** It is a block rather than advice because advice did not
work — agents kept photographing pages in order to *read* them, and images are the single largest
cost an agent has. `read` is about 1% of the cost of a screenshot.

| Question | Command |
|---|---|
| What does the page say? | `read` |
| Click the "Send" button | `activate --text "Send"` |
| Put text in the "Email" field | `fill --label "Email" "x@example.com"` |
| Pick from a JS dropdown | `choose "<combobox>" "<option>"`, or `dropdown list` / `dropdown pick` |
| Where is it on screen? | `find "<css selector>"` or `find --text "Send"` |
| Did anything change at all? | `pagetitle` — cheapest possible check |

**Coordinates from the DOM cannot drift from what is rendered. Coordinates from a picture can** —
a half-scale screenshot once aimed every click on every desktop at the wrong place for hours, and
opened reply drafts on real customer mail. The screen also **resizes with whoever is viewing it**,
so a saved image is stale by nature.

**The escape hatch, for when there is genuinely nothing to read:** a native XFCE dialog, a window
that will not paint, a rendering fault. CDP only sees Chrome pages, so those have no text interface:

    SHOT_OK=1 ~/.fleet/bin/desktop.sh shot

Use it on purpose, not as a habit. If you are reaching for it to find out what a page *says* or
*where a control is*, the answer is `read`, `find` or `activate`.

## One agent at a time

Each desktop takes an exclusive lock per command, and you can hold it across a multi-step task
with `claim [minutes]` / `release`. If someone else is driving:

    desktop '<name>' is busy — another agent is driving it.

**Believe it and wait.** Two agents on one screen has already happened: a click meant for a dialog
landed on another tab because the other session moved focus mid-action. Do not invent a way around
the lock.

## Commands

| | |
|---|---|
| `goal "<task>"` · `goal --clear` | say what you are doing — every log row carries it |
| `read` | page text over CDP — **your default** |
| `find` | screen coordinates of an element, from the DOM — no image |
| `activate --text "<name>"` / `activate "<css>"` | click an element by name, then verify |
| `fill --label "<name>" "<text>"` / `fill "<css>" "<text>"` | type into a field by name, then verify |
| `choose "<combobox>" "<option>"` | pick from a custom listbox by text |
| `dropdown list [n]` · `dropdown pick <n> <index>` | JS comboboxes (react-select and friends) |
| `pagetitle` | title of the focused window |
| `url <address>` | open an address in the running Chrome |
| `tabs` · `focus <n>` · `close-tab <n\|url-part>` | list, switch, close tabs |
| `revive` | a tab that has stopped responding — closes it through the browser, not the page |
| `fit` | the window has collapsed and coordinates look wrong |
| `claim [min]` · `release` · `claims` · `waiting` | hold the desktop across a task |
| `click` / `rclick` / `dblclick` `<x> <y>` · `move` · `where` | mouse |
| `type "text"` · `key <keyspec>` · `scroll up\|down [n]` | keyboard and wheel |
| `shot` | PNG path to Read — **refused unless `SHOT_OK=1`** |

Input goes through **xdotool — real X events**, indistinguishable from a hand on a mouse. That is
why sites do not flag it the way they flag CDP-synthesised clicks.

## When you need something from the operator

**Never a bare open question.** Give numbered options, put them last, recommend one:

    1. Use the billing address on file (recommended)
    2. Use the office address
    3. Something else — tell me

**Batch it.** Read the whole form first and ask for everything missing in one message. Asking
three times for three fields is three interruptions for one task.

**Then hand it back properly.** Say what is done, what is left, and exactly what they have to tap:
*"Vendor form filled — name, address, tax ID, contacts. Stops at the card field. One tap: enter
card, hit Submit."*

## Do not

- **Do not enter a password, 2FA code, or card number.** Ever.
- **Do not sign anything out**, or "clean up" a session you did not create.
- **Do not accept terms or place an order** that costs money without asking first.
- **Do not screenshot to read text or to find a control.** `shot` is off unless you set
  `SHOT_OK=1`, and that is for things with no text interface at all.
- **Do not work on a desktop that is not yours.**
- **Do not report success you have not verified.** A click that silently did nothing looks exactly
  like a click that worked — that is why `activate` and `fill` verify, and why you `read` after.

## When it is broken

Infrastructure belongs to **{{MAIN}}**. A dead container, no route out, a browser that will not
load — tell them rather than restarting things. Useful facts to include:

    docker ps -a --filter name=-desktop          # which desktops exist and whether they are up
    docker logs --tail 50 <name>-desktop         # why one will not start
    ~/.fleet/bin/desktop-report.py               # what the desktops have been doing, and failing at
