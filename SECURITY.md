# Security policy

Runout Bar runs next to tools that hold subscription tokens, so reports about how it handles them
are taken seriously.

## Report a vulnerability

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/RobinVivant/runout-bar/security/advisories/new).
Do not open a public issue, and do not paste tokens, `~/.config/teamclaude.json` or an unredacted
`teamclaude status --json` output anywhere.

Include the commit you run, your macOS version, what you did and what happened. This is a
personal project, so answers come as time allows. Fixes land on `main`, the only supported
version; there are no release branches.

## What is in scope

- A token, account name or other secret that the app writes, logs, shows or sends where it should
  not.
- A way to make the app spend a banked reset, switch routing, restart the proxy or install a
  package without the user confirming it.
- A way for a file or a server response to make the app run a command it was not built to run.

A report about TeamClaude, Codex, Antigravity or the services behind them belongs to those projects.

## How the app handles secrets

- The app never reads TeamClaude's config or credentials itself and never imports its internal
  `src/` modules. It runs the `teamrouter` / `teamclaude` CLI, and lists or spends banked Claude
  resets through the running proxy's control routes (`GET /teamclaude/resets`,
  `POST /teamclaude/resets/read`, `POST /teamclaude/resets/redeem`, or their `/teamrouter/...`
  aliases), sending `proxyApiKey` as `x-api-key` only if configured.
- Anthropic tokens stay inside TeamClaude and never enter Runout Bar.
- `codex` and `agy` keep their own logins in their CLI and macOS Keychain stores; Runout Bar runs
  those CLIs directly and never reads or touches their credentials. For Antigravity session
  counts, it opens local `conversation_summaries.db` stores read-only for run status and timestamps
  only — never credentials, OAuth tokens or message contents.
- The app's own network calls are an npm registry version lookup for `teamrouter` or
  `@karpeleslab/teamclaude`, and local HTTP control requests to the running proxy when you list or
  spend a Claude reset or reload after a proxy Codex login. There is no telemetry.

[docs/banked-resets.md](docs/banked-resets.md) describes the reset flow in detail.
