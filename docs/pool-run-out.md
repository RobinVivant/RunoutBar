# Pool run-out

Runout Bar projects when the whole Claude pool runs out, and shows that time in the menu bar and
on the Usage tab. This page describes how the projection is made.

The pool runs out when every Claude account's weekly window is at TeamClaude's switch threshold.
The target is the end of the work week, Friday 19:00 by default; once it passes, the target is
next Friday. Codex and Google AI are not part of the pool.

- **Pace**: points used per work hour, measured from History over the last two workdays. Usage at
  night or at the weekend counts, spread over the work hours, so it is neither ignored nor
  projected into the night. A one-point wobble in the readings is not usage; a larger drop is a
  reset. Under two hours of measured work time gives no projection.
- **Projection**: the pool burns at that pace during work hours only. It drains the account whose
  week resets first, and each account gets its capacity back at its own reset, so a reset before
  Friday adds to the pool.
- **Units**: a point is one percent of one account's weekly limit, so the projection treats the
  accounts as the same size. Per-model weekly windows and 5-hour windows are not modeled.

**Pool Run-Out Time** in the settings menu hides it from the menu bar.
