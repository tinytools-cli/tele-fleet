---
name: continuous-work
description: Keep work moving unattended (overnight, while the operator is away) until a stated end point — set the end point first, arm a heartbeat and a watcher for everything you wait on, advance every thread on each wake, never stall on a non-blocker, and stop cleanly with a report. Use whenever you say "I'll keep going", "overnight", "until you wake up", or start anything that finishes outside your session (background jobs, CI, deploys, other agents).
---

# Continuous work — keep going until the end point, then stop

Written after a lost night. A batch of background jobs finished early in the evening, nothing
woke the session, and it sat idle until the operator's "good morning" the next day. Nothing was
blocking. **The session simply was not running.** Everything below exists to make that
impossible.

For working a ticket backlog (claim → verify → note → close), use `autonomous-ticket-loop`
as well. This skill is the part that keeps you awake and tells you when to stop.

## The one fact that matters

**You only run when something wakes you.** There are exactly three wake sources:

1. A message from the operator (or a peer agent).
2. A task you started *in this session* finishing: `Bash` with `run_in_background`, an `Agent`.
3. A `CronCreate` job firing (only while the session is idle).

Anything that runs *outside* your session — a job on another runner, CI, a deploy you did not
start a waiter for, another agent's pull request — finishes **silently**. If you end a turn while
waiting on one of those with no wake armed, you are asleep until a human pokes you.

**Rule: never end a turn waiting on something unless a wake is armed for it.**

## 1. Before you start: write the end point

Say it, and write it into the loop's state file (below) and a tix note. Three parts:

- **Done when:** concrete, checkable. "Rounds 1–5 evaluated and the top 2 published", "the batch
  is live and smoke-tested", "backlog empty or everything left is blocked".
- **Stop early when:** a rule, not a feeling. "Gain < 2 points two rounds running", "the smoke
  test fails", "the same step fails twice", "a decision only the operator can make blocks
  *everything*".
- **Deadline / report time:** when they want results ("by 07:00 my time, when I wake up").

Then question it: is every part of this needed? Delete before you loop.

## 2. Arm the wakes (do this before saying "I'll keep going")

**a. Heartbeat — always.** One recurring `CronCreate`, off the :00/:30 marks:

    cron: "17,47 * * * *"   recurring: true
    prompt: "Heartbeat (<agent>, <loop name>): read <state file>; check every open thread;
             advance whatever can move; update the state file; tix note real progress;
             message the operator only at milestones; if the end point is met, stop (see §5).
             If nothing changed, do nothing visible."

- `CronList` must show it before you say "overnight". If it is empty, you have no loop.
- It is session-only and expires after a few days. After a restart or a context compaction, run
  `CronList` first and re-create it if it is missing.
- It only fires while you are idle — that is fine; idle is exactly when you need it.

**b. A watcher per external job — fast wake.** For each outside thing you wait on, start a
background command that exits when it finishes, so you wake within a minute instead of waiting
for the next heartbeat:

    # anything with a shell check (CI, a deploy, a job's status file, a report appearing)
    ~/.claude/skills/continuous-work/wait-for.sh until "test -f /path/to/REPORT.md"   # run_in_background
    # a process on this machine
    ~/.claude/skills/continuous-work/wait-for.sh pid 12345

Background commands can be cut off after several minutes — that is why the heartbeat is the
backstop, not the watcher.

**c. Agents report themselves.** A subagent you started with `Agent` wakes you when it finishes;
no watcher needed. Peer agents do not — their "ready" message wakes you, but also check for their
output on every heartbeat (e.g. `gh pr list --search head:<their-branch-prefix>`).

## 3. Keep a state file

One file per loop, e.g. `<your project folder>/loops/<loop-name>.md`, newest at top:

- end point (done / stop early / deadline)
- each open thread: what it waits on, the job/PR/deploy id, the next action when it lands
- strikes / counters for the stop rules
- what was reported to the operator and when

Context compaction loses detail; the state file does not. Each wake starts by reading it.

## 4. On every wake

1. `CronList` — heartbeat still there? Re-arm if not.
2. Read the state file.
3. Check every thread for real (job status, report files, deployed version, PR list). Never
   assume from memory that something is still running.
4. **Advance everything that can move**, in parallel where independent: read the result, verify
   it, start the next step, arm a watcher for anything new you start outside the session.
5. Update the state file; `tix note` real progress (not "checked, nothing new").
6. Message the operator only at milestones. During their night: no messages unless urgent
   (production broken, money, security). Queue the rest for the morning report.

## Rules for not stalling

- **A low-stakes call is yours.** Make it, write why in the note, keep going. Asking costs a
  night.
- **A real decision for the operator** (money, their taste on a final pick, something
  irreversible they own): park that one thread with the question and your recommendation, then
  **keep every other thread moving**. One parked thread never stops the loop.
- **Something failed:** retry once if it is clearly transient; otherwise fix it or file it and
  route around it. The same step failing twice is a stop-early condition for *that thread*.
- **Waiting on a peer agent:** send one message, then do other work. Do not chase.
- **Sequencing traps:** do not deploy to an environment while a test job is running against it;
  queue the deploy and do it when the watcher fires.
- **Never close the turn with "will do X when Y finishes"** unless a watcher or the heartbeat
  covers Y.
- Safety rails and approval gates do not relax because nobody is watching. They tighten.

## 5. The end point — stop cleanly

When **done**, **stop early**, or the **deadline** arrives:

1. `CronDelete` the heartbeat (and `TaskStop` any watcher still running).
2. Final tix notes; close what is done, mark blocked what is blocked, with the reason.
3. One report to the operator (at their wake time if it is night): what got done, what is live,
   what stopped and why, what needs them — as numbered options, one question.
4. Update the state file with "closed <date>, reason".

A loop with no end point burns tokens forever; a loop that stops without a report looks like it
never ran.

## Checklist (copy into the state file)

- [ ] End point written: done / stop early / deadline
- [ ] Heartbeat created and visible in `CronList`
- [ ] Watcher running for every external job
- [ ] State file exists and lists every thread
- [ ] Told the operator the plan *and* when the report comes
- [ ] At the end: heartbeat deleted, tix closed/blocked, report sent
