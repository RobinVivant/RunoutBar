# Work-week runway

Runout Bar projects when each **capacity lane** runs out against the end of the work week, and
shows the bottleneck in the menu bar and on the Usage tab.

## Capacity lanes and thresholds

Each fungible quota tank is projected as its own lane:

- **Claude (TeamClaude pool)**: combines every Claude account's weekly window. The pool runs out
  when every Claude account reaches TeamClaude's switch threshold (`98%` by default). A single
  account reaching `98%` while another Claude account has headroom is a routine rotation, not a
  hard stop.
- **Direct CLIs (`Codex`, `Gemini`, `Claude and GPT`)**: each independent quota bucket runs on its
  own lane and reaches a hard stop at `100%`.

The target is the end of the work week, Friday `19:00` by default; once it passes, the target is
next Friday.

## How the projection works

- **Pace**: points used per work hour over the last two workdays. Usage at night or at the weekend
  counts, spread over work hours, so it is neither ignored nor projected into the night. A
  one-point wobble in readings is ignored; a larger drop is treated as a reset.
  - When at least two work hours exist both today and in the prior workday, pace weights today at
    `65%` and the prior workday at `35%` so shifting load between models shows promptly.
  - When a lane was flat in the prior workday and starts burning today, pace uses today's active
    rate directly once at least two work hours have elapsed today.
  - Lanes with under `0.5` points burned in the window (or untouched `starts on first use`
    windows) appear as **idle**.
- **Budget and pace ratio**: the highest rate (`pts/work h` or `%/work h`) that still lasts until
  Friday `19:00`, plus the ratio (`pace / budget`) so lanes are directly comparable across
  providers.
- **Projection**: each lane burns at its pace during work hours only, drains the account whose week
  resets first (for pooled lanes), and adds each account's capacity back at its own reset.
- **Units**: a point is one percent of one account's weekly limit, so pooled accounts are treated
  as the same size. Per-model weekly windows and 5-hour windows are tracked separately.

**Menu bar run-out** in the settings menu chooses between **Earliest active lane** (default),
**Claude pool only**, and **Off**.
