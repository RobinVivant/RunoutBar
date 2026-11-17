# Banked resets

A banked reset clears an account's limits before their own reset. The Usage tab counts them per
account with the earliest expiry, and each account's detail view shows what it holds.

- **Codex**: the detail view lists each reset with its expiry. **Use a Reset…** asks for
  confirmation, then spends the one that expires first through the Codex app server
  (`account/rateLimitResetCredit/consume`). A spend cannot be undone. When no limit is reached,
  Codex answers that there is nothing to reset and spends nothing. When no answer arrives, the
  next try repeats the same request under the same idempotency key, so it cannot spend a second
  reset.
- **Claude**: the detail view shows the count, how many clear only the Fable weekly limit, and the
  earliest expiry, as TeamClaude reports them. **List Resets** reads the account's resets from
  Anthropic: the kind of each one, the limits it clears, how many are left and when it expires.
  **Use…** on a reset asks for confirmation, lists the reasons the spend may be wasted (for
  example, no weekly limit is exhausted), then asks Anthropic to spend it. A spend cannot be
  undone. A listing older than 15 minutes must be read again before a spend. When no verdict
  arrives, the next try on that reset repeats the same request id, so it cannot spend a second
  reset.

## How a Claude reset is spent

TeamClaude has no command or endpoint that spends a Claude reset: it does so on its own when
`autoRedeemResets` is on in its config and no account can serve a request, or by hand in the
dashboard of a server started in a terminal (`r`). The app therefore runs a short Node script
that loads TeamClaude's own modules from `teamclaudeInstallDir` and calls the functions that
dashboard uses (`fetchClaudeResetStatus`, `claimClaudeReset`), with the token TeamClaude stores.

## Limits and safeguards

- The token stays in that Node process. The script prints reset details and the verdict, and
  never refreshes a token: when the stored one has expired it stops, and TeamClaude renews it
  with the account's next request.
- Every call the app makes to Anthropic goes through one queue: one call at a time, a second
  apart. When Anthropic answers HTTP 429, the queue holds that account's reads, or its spends,
  until the time Anthropic names, then sends the call again. Without a named time it waits one
  minute, doubling up to five. A spend goes out again under the same request id. Calls for other
  accounts keep moving.
- While a call waits, its card shows when it goes out, a countdown and **Stop Waiting**, and the
  popover footer counts the calls waiting. A call that would wait more than 10 minutes gives up
  and shows when to try again.
- The queue covers this app's calls only. TeamClaude's usage check reads the same endpoint on
  its own schedule and can use up the limit.
- TeamClaude learns of a spent reset at its next successful usage check. Until then it can keep
  an account it had set aside as full out of rotation.
- The script depends on TeamClaude internals, as of 1.1.30. When an update renames them, the app
  reports it and spends nothing.
