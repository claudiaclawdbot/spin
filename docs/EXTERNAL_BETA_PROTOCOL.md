# External Beta Test

This test answers one question: can a new user trust SPIN to run real work and
come back to it the next day?

Do not call this product-market fit until people outside the project use it.
Run the test with 5 to 10 people who already use coding agents on real repos.

## What Each Tester Does

1. Install SPIN on a Mac without maintainer help.
2. Connect three real repositories.
3. Give each project one useful task.
4. Watch one task in a visible project floor.
5. Let two tasks run in the background.
6. Queue one `heavy` test job, confirm it runs alone, then force one job to fail
   and find the reason in SPIN.
7. Try a sensitive action with no enabled rule. It must be denied and queued.
8. Enable one test-only broker rule and run it. A receipt must appear.
9. Restart the Mac while work is idle, then confirm the board tells the truth.
10. Use SPIN for seven days without a maintainer sitting beside them.

Use test accounts and disposable targets. Do not use real customer data,
production credentials, or meaningful spend in this test.

## What To Record

- Time from download to first working project.
- Places where the tester needed help.
- Jobs started, completed, failed, or abandoned.
- Whether running, queued, failed, and stale states matched reality.
- Whether any sensitive action ran without an exact enabled rule.
- Peak memory and process counts during normal work.
- Which screen the tester checked first each day.
- Whether they returned on days 2, 4, and 7.
- What they expected SPIN to do but could not make it do.
- What they would pay per month and why.

## Pass Bar

- At least 4 of 5 testers install and start a project without live help.
- No false green state after restart or process death.
- No sensitive action bypass through the supported SPIN workflow.
- At least 90% of completed or failed jobs have a useful receipt or reason.
- Normal work stays inside configured job resource limits.
- At least 3 testers return during the week without being reminded.
- At least 2 ask to keep using it or say they would pay for the next version.

Missing this bar is not a launch failure. It tells the team which product loop
to fix before spending on promotion.

## End Questions

Ask each tester:

1. What did you trust SPIN to do by itself?
2. What did you still check manually?
3. When did the interface feel unclear or invisible?
4. What would make you use it every week?
5. Would you pay for it today? How much?
6. Who else has this problem?

Recruiting testers, sending invitations, or paying incentives are external
actions. Route those steps through the configured action broker.
