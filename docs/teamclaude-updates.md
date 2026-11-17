# TeamClaude updates

The app asks the npm registry for the latest `@karpeleslab/teamclaude` release every 6 hours,
and again after 15 minutes when a check fails. It does not rely on the proxy's
`updateAvailable` flag, which can be stale, or on `teamclaude update`, which does not update a
prefix install like the one the LaunchAgent runs.

**Update…** in the Proxy tab asks for confirmation, since restarting the proxy interrupts active
sessions, then runs:

```bash
npm install --prefix ~/.local/share/teamclaude --no-audit --no-fund @karpeleslab/teamclaude@1.1.29
launchctl kickstart -k gui/$(id -u)/com.karpeleslab.teamclaude
```

It then waits up to 30 seconds for the proxy to report the new version. Only plain `x.y.z`
release versions are installed.
