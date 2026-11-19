# TeamClaude install and updates

## First install

Every minute the app looks for the TeamClaude CLI: at the `teamclaude` path of the config, in
`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`, and at the script that the LaunchAgent
`com.karpeleslab.teamclaude` runs. When it finds one, it uses it and installs nothing.

It installs TeamClaude without asking only on a Mac that shows no sign of it: no CLI, no
LaunchAgent, no `~/.config/teamclaude.json` or `teamrouter.json`, and nothing listening on the
proxy's port. It does this once. After a removal, a failed attempt or with traces of another
copy, the popover shows an **Install** button instead. Demo mode and `--snapshot` install nothing.

The install needs npm and Node.js 20 or later, taken from the `npm` and `node` paths of the config
or from `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. Without them the popover says
so, and the install starts by itself once they are there. It runs:

```bash
npm install --prefix ~/.local/share/teamclaude --no-audit --no-fund @karpeleslab/teamclaude@1.1.30
ln -s ~/.local/share/teamclaude/node_modules/.bin/teamclaude ~/.local/bin/teamclaude
~/.local/bin/teamclaude service install
```

The version is the registry's latest release. A file that already sits at the link's path is
left alone, and the install stops there. `teamclaude service install` is TeamClaude's own command:
it writes the LaunchAgent and loads it, which starts the proxy now and at every login. The app
then waits up to 30 seconds for the proxy to answer.

A new proxy has no account. **Add Account** runs `teamclaude login --oauth`, which opens claude.ai
in the browser and adds the account signed in there.

When TeamClaude is installed but has no LaunchAgent and does not answer, the popover offers
**Start at Login**, which runs `teamclaude service install`.

## Updates

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
