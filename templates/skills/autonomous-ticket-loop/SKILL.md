---
name: autonomous-ticket-loop
description: Work a project's ticket backlog end-to-end without a human driving every step — pick the next unit of work, do it (or delegate it) for real, verify it live, log it, park anything that needs a human decision, and move on. Written against the `tix` tracker's CLI, but the method generalizes to any tracker.
---

# Autonomous ticket loop

You are being set loose on a backlog of work — a list of tickets, tasks, or
issues in some tracker — with instructions to get through as much of it as
possible without stopping to ask permission at every step. This document is
how to do that well. It was written after a real day of doing exactly this:
working roughly 150 tickets across ten epics on a production app, mostly
unattended, including recovering cleanly from a real incident along the way.
Nothing here is theoretical.

The point of this skill is trust. The human gave you a loose leash because
they believe you'll use it responsibly. Every section below exists because
of a specific way that trust can be won or lost.

**The tracker used throughout this doc is `tix`** — an agent-native CLI
tracker. `tix --help` is the spec and it changes, so read it rather than
guess flags. The commands that matter for this loop:

    tix list --assignee <you> --status todo      # what's next
    tix show <KEY>                                 # full ticket + prior notes
    tix update <KEY> --status in_progress           # claim it
    tix note add <KEY> "<what happened>"            # the record (see below)
    tix update <KEY> --status done                  # close it out
    tix update <KEY> --status blocked --desc "..."  # park it, see below
    tix add "<title>" --project <p> --assignee <you> \
        --type task --status in_progress --model <tier>   # file NEW work you found

If you're on a different tracker, the shape carries over directly: claim →
note → close, and a real "blocked" state that's distinct from "done" and
distinct from silently dropped.

## The core loop

1. **Read the backlog.** List open units of work. Understand what's already
   done, what's blocked, what's next. Don't start work blind — read enough
   context (a spec doc, prior tickets' notes, the actual current state of
   whatever you're changing) to know what "done" means for the next item.
   Mirror it into Claude Code's own todo list too — see **Mirror the
   backlog into Claude Code's own todo list** below — so the human watching
   this session can see the plan without leaving the conversation.
2. **Pick the next unit and mark it started.** One unit at a time, in a
   sensible order — respect real dependencies (don't build on top of
   something that isn't finished yet), but don't invent dependencies that
   aren't there just to justify sequencing you'd prefer.
3. **Do the work** — yourself, or by delegating to a sub-agent scoped
   tightly to that one unit (see **Delegation** below). Either way, the
   standard is the same: real, verified, working — not "looks right."
4. **Verify for real before calling it done.** See **The verification bar**.
   A build that compiles is not evidence it works.
5. **Log what happened, then close it out.** See **Recording what you did**.
   The note is the deliverable as much as the work is — someone with zero
   context (a human, or the next agent) has to be able to trust it without
   re-deriving it.
6. **If you hit a blocker or a real decision, park it and move on.** See
   **Handling blockers without stalling**. A closed loop that stops dead on
   the first hard question is worse than useless — it wastes the very
   unattended time it was granted.
7. **Repeat** until the backlog is exhausted or everything left is blocked
   on something only a human can resolve.
8. **Check in at real milestones**, not every micro-step. See
   **Communicating with the human**.

## Mirror the backlog into Claude Code's own todo list

`tix` is the record of truth, but it is not what the human watching this
session sees by default. Claude Code has its own built-in todo-list
mechanism (the `TodoWrite` tool) that renders as a live checklist in the
session UI — and that's the thing actually visible in real time, without
anyone having to go open the tracker.

**At the start of a loop, and again whenever the plan changes, load the
project's relevant open tix tickets into that todo list** (`tix list
--project <p> --status todo` / `--status in_progress`, one todo item per
ticket, its tix key in the item text so the two stay traceable to each
other). Keep it current the same moments you'd touch tix: mark an item
`in_progress` when you `tix update <KEY> --status in_progress`, mark it
completed when you `tix update <KEY> --status done`. Add new items when you
`tix add` something you found along the way. The two lists should never
visibly disagree — if they drift, the todo list is wrong, not tix.

This is a mirror, not a second source of truth: tix stays authoritative
(it's what survives between sessions and what other agents/humans read),
and the todo list exists purely so THIS session's human doesn't have to
leave the conversation to see what's actually happening right now.

## Sizing a unit of work

Don't work ticket-by-ticket if the tracker's tickets are too small to be a
sensible unit of delegation, and don't work the whole backlog as one giant
undifferentiated blob either. The right size is usually "one coherent
feature or fix that can be verified as a whole" — often a group of related
tickets (an epic, a milestone, a themed cluster), each with its own child
tasks. Read the whole group before starting any one piece of it; the parts
often share context (a shared data model, a shared design decision) that's
wasteful to re-derive per ticket.

## Delegation

If you delegate a unit of work to a sub-agent, the sub-agent needs enough
standing context to work independently for a long time without checking
back — that means:

* **What the unit of work is**, with the exact acceptance criteria, not a
  paraphrase.
* **What's already been decided** that it must not re-litigate (prior
  design decisions, corrections to earlier wrong analysis, explicit
  human decisions already made — cite them, don't make the sub-agent
  rediscover them).
* **What "verified" means for this unit** (see below) and how to actually
  do that verification in this environment.
* **The safety rails below, explicitly stated**, not assumed. A sub-agent
  that wasn't told not to do something will sometimes do it.

**A hard rule, learned expensively: do not let a delegated agent delegate
further on its own.** If a sub-agent decides a task is big enough to spawn
its own "research-only" helpers, and those helpers aren't bound by the same
rules you gave the first agent, you can end up with unsupervised writes,
unreviewed changes, and multiple agents racing on the same shared state
with no one checking. State this constraint explicitly, every time: *do
all your own reading and research directly yourself; do not spawn
sub-agents of your own for this, for any reason.* If a task genuinely needs
to fan out, that fan-out decision belongs to you, the one holding context
on the whole backlog — not to something several layers down that can't see
what else is running concurrently against the same resources.

**A second hard rule, also learned expensively: a delegated agent that
backgrounds a long-running command and then waits for a notification that
it finished may wait forever.** Notification/wakeup mechanisms are often
scoped to the top-level session, not to every nested agent. Tell any
sub-agent explicitly: if you background something, poll for its real
result yourself — don't assume you'll be told when it's done.

## Safety rails for anything risky or stateful

Some units of work will need to touch something with a blast radius bigger
than a local file edit — a shared database, a production system, a real
external account, anything another process or person could also be using
at the same time. The rule for all of it is the same:

**Open only what you need, use it immediately, close it the moment you're
done, and verify it's actually closed before moving on.** Never leave a
door open "just in case you need it again in a minute" — reopening a fresh
one when you actually need it costs nothing; leaving one open costs real
risk for as long as it sits there. If you're not sure whether you'll need
it again in the next minute or two, close it now and reopen later.

If you're delegating this kind of work to a sub-agent, don't just tell it
the mechanism once and trust it — **independently re-check** that anything
risky it opened actually got closed, on your own initiative, without
waiting to be asked. A sub-agent's self-report that it cleaned up is a
claim, not a fact, until you've verified it yourself.

## The verification bar

"It compiles" and "the tests pass" are necessary, not sufficient. Before
marking a unit of work done:

* **Run it for real.** Deploy it, start it, load it — whatever "running"
  means in this environment — and actually exercise the behavior you just
  built, not just read your own diff back.
* **Prefer measuring over eyeballing.** If a machine can check the thing
  (a real HTTP request, a real rendered page's actual DOM, a real
  computed number compared against a hand-checked expected value), have
  it check the thing, rather than trusting that the code *should* produce
  the right result.
* **When the unit of work involves anything users will trust with money,
  safety, or their own data, verify the specific numbers or the specific
  isolation guarantee explicitly** — don't let "looks plausible" stand in
  for "matches a known-correct value" or "definitely can't see someone
  else's data."
* **State plainly what you did NOT verify**, and why. A gap you disclosed
  is fine. A gap you implied was covered when it wasn't is what erodes
  trust the fastest.

## Handling blockers without stalling

The whole value of an autonomous loop is that it doesn't stop dead the
first time something is ambiguous. So:

* **Genuine open questions that only a human can answer** (a product
  decision, a judgment call with real consequences, anything where being
  wrong is expensive and reversible-with-effort at best) — write the
  question down clearly, with your own recommendation if you have one,
  attach it to the relevant unit of work (`tix note add <KEY> "..."` with
  the question and your recommendation, then `tix update <KEY> --status
  blocked`), and **move on to the next unit.** Don't wait idle for an
  answer that might not come for hours.
* **Everything else** — a design ambiguity with no real stakes, a small
  judgment call, a place where two reasonable people might choose
  differently but it doesn't matter much — just make the call, record
  *why* you made it (so it can be revisited if it turns out to matter),
  and keep going. Constantly asking permission for low-stakes calls is
  its own failure mode; it burns the human's attention on things they
  didn't need to be involved in.
* **When new information arrives that unblocks something you parked**,
  come back to it. A blocked item isn't abandoned, it's paused.

## Recording what you did

Every finished unit of work needs a record that lets someone with none of
your context trust it without re-deriving it. At minimum:

1. **What you actually did** — not what the ticket originally asked for,
   if those differ (they sometimes will, once you actually got into it).
2. **Where the output is** — file paths, the actual deployed location,
   whatever lets someone go look at it directly.
3. **What you found** — this is usually the most valuable part and the
   part people skip. A wrong assumption you corrected, a constraint you
   discovered, a place the spec didn't match reality. Say it plainly.
4. **What you deliberately did NOT do**, and why — scope you left out,
   things you assumed rather than confirmed, verification you skipped
   and why that was an acceptable tradeoff.
5. **Open questions for the human**, if any remain.

In `tix`, this is one `tix note add <KEY> "..."` call covering all five,
written for someone with zero context, followed by `tix update <KEY>
--status done`. The note is not optional and flipping status without one
is exactly the failure mode this section exists to prevent — a ticket that
just changed to `done` tells the next reader nothing.

State outcomes plainly. A record that reads as a clean success when the
work was actually partial, or when something broke and got fixed, is
worse than no record — because it gets trusted.

If you found real work along the way that wasn't already tracked — a bug,
a gap, a follow-up — file it as its own ticket (`tix add`, right type: a
bug that behaved differently than claimed is `--type bug` even if you
fixed it in the same breath; a bug buried as a note on an unrelated ticket
is invisible to anyone who didn't already know to look for it) rather than
only mentioning it in prose. A tracker only reflects reality if everything
real gets filed in it.

## Communicating with the human

* **Batch it.** Report at real milestones — a meaningful chunk of work
  finished, a real blocker, an incident — not after every small step.
  A stream of tiny updates is as useless to a busy human as silence.
* **Lead with substance, not process.** "Here's what changed and what it
  means for you" beats "here's what I did internally."
* **When you need a decision, give concrete options with a
  recommendation** — never a bare open question. Make it easy to answer
  in one word.
* **If something goes wrong, say so plainly and immediately**, with what
  you've independently verified about the actual impact — not a
  reassuring gloss, and not an alarming guess. Contain first if you can
  do so safely, then report what happened, what you checked yourself
  (not just what a sub-agent claimed), and what you're doing about it.

## Choosing how much reasoning power to spend

Not every unit of work deserves the same weight. Match effort to stakes:

* **Routine, well-specified, low-consequence work** — use a cheaper/faster
  mode. Most implementation and cleanup work is this.
* **Design decisions, anything genuinely ambiguous, or anything where
  being wrong is expensive** (money math, security boundaries, data
  integrity, irreversible actions) — spend more here. Getting it wrong is
  far costlier than the extra time/cost of getting it right the first
  time.
* Recurring or long-running loops multiply this choice — decide it once
  per unit of work, deliberately, rather than defaulting to whatever tier
  you happened to start in.

## The one-sentence version

Work the backlog one verified unit at a time, keep dangerous things open
for the shortest possible window and check they actually closed, never let
delegation go more than one layer deep without the same rules following it
down, park real decisions for the human instead of stalling on them, and
leave a paper trail honest enough that nobody has to take your word for
anything.
