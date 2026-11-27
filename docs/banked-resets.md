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
  earliest expiry, as TeamClaude reports them. Opening an eligible account's detail view loads any
  cached listing held in memory by the running proxy (`GET /teamclaude/resets`), sending no request
  upstream. **List Resets** / **Read Again** asks the proxy (`POST /teamclaude/resets/read`) for the
  account's resets: the kind of each one, the limits it clears, how many are left and when it
  expires. **Use…** on a reset asks for confirmation, displays the proxy's warnings (for example,
  no weekly limit is exhausted), then sends `POST /teamclaude/resets/redeem`. A spend cannot be
  undone. A listing older than 15 minutes must be read again before a spend.

## How a Claude reset is spent

Runout Bar uses TeamClaude's control-plane HTTP routes (`/teamclaude/resets`,
`/teamclaude/resets/read`, `/teamclaude/resets/redeem`, or `/teamrouter/resets*` when configured):

- Runout Bar never reads TeamClaude's config, never handles OAuth tokens, and never imports
  internal modules from TeamClaude's `src/` directory.
- Loopback requests use TeamClaude's local exemption by default; if your proxy sets
  `proxy.trustLoopback: false` or runs on another host, the reset card and Sources tab prompt
  inline for `proxy.apiKey` on `401` and save it locally with `0600` permissions in
  `~/.config/runout-bar/proxy-key` (or you can set `"proxyApiKey"` in `~/.config/runout-bar/config.json`).
  Runout Bar sends it in the `x-api-key` header.

## Limits and safeguards

- Upstream calls to Anthropic are serialized and rate-limit guarded inside TeamClaude (including its
  2-minute read floor, 1-hour post-claim safety hold on the HTTP route, and idempotent replay
  protection); Runout Bar also queues its reset calls per account and honors `retryAt` on HTTP 429.
- While a call waits in Runout Bar's queue, its card shows when it goes out, a countdown and
  **Stop Waiting**, and the popover footer counts the calls waiting.
- If a spend request times out or receives HTTP 502 without a verdict, Runout Bar marks the attempt
  uncertain and prompts you to read again before retrying (the proxy also refuses a duplicate spend
  for one hour with HTTP 409).
- TeamClaude learns of a spent reset during its claim and updates the account's limits on its next
  usage check.
