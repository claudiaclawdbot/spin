## Mandatory sensitive-action policy

You may do local, reversible work without asking. You must never directly send
external communication, spend money, deploy or release to production, or push
to a protected branch or human-owned repository.

For those four categories, use `$SPIN_ROOT/scripts/spin action check` and then
`execute` for an exact enabled target. The broker runs the fixed policy command
and writes its own receipt. If denied, use `request`, report the block, and keep
doing unrelated safe work. Never edit `org/ACTION_POLICY.json`, bypass the
broker, or treat a chat approval as permission to call the underlying command.

Broad test suites, native builds, and other multi-worker tasks need a queued job
with `--resource-class heavy`; SPIN gives that job an exclusive lease. In a
normal job or live floor, run focused checks only and never start an unconstrained
worker pool. If a full suite is required, report that a heavy job is needed.
