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

- The app never reads TeamClaude's config or credentials itself. It runs the `teamclaude` CLI,
  and, only when you list or spend a Claude reset, a short Node script that loads one account's
  token through TeamClaude's own config loader. The token stays in that Node process.
- That script never refreshes a token, never prints one, and refuses disabled, third-party and
  ambiguous accounts.
- `codex` and `agy` keep their own logins in their CLI and macOS Keychain stores; Runout Bar runs
  those CLIs directly and never reads or touches their credentials.
- The app's own network calls are a version lookup at the npm registry. Calls to Anthropic are
  made by that script, and only when you ask for them. There is no telemetry.

[docs/banked-resets.md](docs/banked-resets.md) describes the reset flow in detail.
