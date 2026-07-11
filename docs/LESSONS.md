# Lessons — how v1–v3 broke and what v4 (SPIN) does instead

SPIN is the fourth architecture. The earlier ones failed in instructive ways.
Everything below was paid for in burned quota and silent no-ops.

## 1. Never execute work by typing into terminal panes

**v1/v2:** the dispatcher delivered jobs by `cmux send`-ing commands into each
project's pane. Panes wrapped, prompts swallowed keystrokes, REPLs interpreted
shell commands as chat — the result was a wall of "Controller process exited"
failures (15+ consecutive at the worst) while the queue looked perfectly healthy.

**v3:** jobs spawn as **detached background processes** with their own PID file
and log. cmux only *displays* (log tails, status chips, markdown boards).
Completion is detected by PID liveness, not by scraping pane text.

**Current nuance:** an explicit `spin delegate --wait <project> "<task>"` handoff
may type into a live project floor when the human wants to watch that coordinator.
That path is stamped with a request id and waits for an `org inbox` report; it is
not the autonomous queue dispatcher.

## 2. Duplicate loops are the silent quota killer

One stale loop from a day earlier + a launchd copy + an old supervisor all
firing agents every ~5 minutes burned a full weekly codex quota in a weekend.
Nothing crashed; everything just "ran".

**v3:** every long-runner **refuses to run twice**. At startup it writes its
PID into a lock file using bash's noclobber mode — an atomic "create only if
absent", so two simultaneous launches can't both win — and if the lock already
exists with a still-alive PID inside, the new copy exits immediately. (This
pattern is sometimes called a singleton lock.) Pair it with a process census
when debugging: `pgrep -fl tick`.

## 3. Bench rate-limited providers — and ignore overrides while benched

When a CLI hits its usage limit, retrying it every tick wastes the window and
hides the problem. Worse: an explicit `PROVIDER=x` override somewhere upstream
kept resurrecting the rate-limited provider.

**v3:** on any usage-limit error a direct CLI provider gets a **lockout file with
an expiry epoch**; the outer fallback skips it — *even when explicitly requested* —
until the lockout expires on its own. OMP keeps its own provider/account cooldowns
inside the harness, so SPIN does not bench the whole OMP lane for one backend's
429.

## 4. An LLM loop that runs on a timer is a money printer (for your provider)

Early loops invoked the brain every tick regardless of whether anything changed.

**v3:** the brain is **change-gated on a content hash** of the real inputs
(approvals, inbox, project state) with volatile timestamp fields stripped, plus
a low-frequency forced heartbeat. An idle org costs a couple of brain runs a day.

## 5. "Exit 0" does not mean "did something"

Some CLIs exit cleanly after producing nothing (auth hiccup, empty completion).
The queue marks them complete; work silently stalls.

**v3:** after each job the agent script **diffs the project's STATE/RECEIPTS
hashes**; an unchanged exit-0 run is retried once on claude and labeled a
silent exit in the log.

## 6. A kill switch you can forget is an outage

A `STOP` file paused the org for three days; nothing surfaced it. The fix that
*found* it was an audit, not an alert.

**v3:** the (LLM-free) status daemon doubles as a **watchdog**: red chip +
desktop notification when the driver is down without a STOP file, and the
status doc always carries the driver state. `ceo` shows ●/○ at the top.

## 7. Don't run agents inside your monorepo

Running the CEO agent with cwd inside a giant dirty repo injected hundreds of
dirty-file contexts into every request until the API rejected them.

**v3:** the CEO floor runs from a **clean empty directory** and touches org
files by absolute path. Project agents run inside their own project repo only.

## 8. Paths drift — registries must be fed, not trusted

Project code moved; prompts, crons, and registry entries kept pointing at the
old paths. Jobs blocked on `Unknown project_id`; a cron failed every 5 minutes
for days.

**v3 practice:** one registry (`org/OMP_HARNESS.json`) owns the project map;
`bootstrap-project.sh` creates the metadata a dispatchable project needs; and
anything that moves directories must grep prompts/crons/registry in the same
change. (A `workspace` maintenance lane exists precisely to absorb this class
of chore.)

## 9. Gate by consequence, not by effort

Approval fatigue kills autonomy; zero gates kill trust. The stable point we
found: agents act freely on anything **local and reversible**, and stop for
exactly four things — external sends, money, production deploys, protected
pushes. Big irreversible deletions ride the same gate.

## 10. Don't let an LLM hand-edit your shared state (the v4 change)

For three architectures the brain wrote `state.json` and `AGENT_QUEUE.json`
directly, kept in line only by prompt discipline ("append, don't replace").
It mostly held — until it didn't: a wrong-direction doc edit, a node crash
mid-write, a job blocked because the model invented a `project_id`. An LLM
editing shared JSON is the least robust joint in a file-based org.

**v4:** all mutations go through the `org` CLI (`scripts/org`). Each verb
**validates** (unknown project / disallowed job type → rejected before any
write), takes an **exclusive lock**, writes **atomically** (temp + rename), and
is **append-only** where history matters. The brain's prompt now forbids direct
JSON edits; its only freeform writes are receipts and project-prompt drafts. The
LLM still decides *what* to do — it just can no longer corrupt the ledger doing
it. Bonus: every mutation is now a shell command you can test, log, and replay.

## 11. Supervise the whole visible truth, not only the expensive loop

A reboot restored cmux windows while only the driver LaunchAgent returned. The
status document still showed the pre-reboot PID as green because the process that
would refresh it was down. A running backend with a stale cockpit is not healthy.

**v4 hardening:** `spin service` owns the driver, status roll-up, and wiki watcher
as separate supervised services. Health requires a live PID with the expected
command, the driver refreshes the board immediately on startup, and the status
service reconciles missing cmux floors. Detached jobs also carry RSS/process
budgets so a test runner cannot consume the workstation without leaving a clear
failure receipt.
