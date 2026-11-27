# TeamClaude install and updates

## First install

Every minute the app looks for the TeamClaude / TeamRouter CLI, in this order: a custom `teamclaude`
path in the config, `teamrouter` and `teamclaude` across `~/.local/bin`, `/opt/homebrew/bin` and
`/usr/local/bin`, the script that the LaunchAgent (`com.karpeleslab.teamrouter` or
`com.karpeleslab.teamclaude`) runs, then the Volta, Bun, pnpm, npm and nvm folders. When it finds
one, it uses it and installs nothing.

It installs TeamClaude without asking only on a Mac that shows no sign of it: no CLI, no
LaunchAgent, no TeamClaude config and nothing listening on the proxy's port. The config is
`teamrouter.json` or `teamclaude.json` in `~/.config` or `$XDG_CONFIG_HOME`, or the file that
`TEAMROUTER_CONFIG` or `TEAMCLAUDE_CONFIG` names; the app checks that it exists and does not open
it. The automatic install happens once per Mac: the app remembers that it has seen or installed a
TeamClaude, so removing TeamClaude later does not bring it back. After a removal or with traces
of another copy the popover shows an **Install** button, and after a failed attempt **Try Again**.
Demo mode and `--snapshot` install nothing.

When the `dashboard` of the config points at another machine, or something answers on the
proxy's port while no CLI is found, the app installs nothing and asks for the `teamclaude` path
in its config.

The install needs npm and Node.js 20 or later, taken from the `npm` and `node` paths of the config
or from `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. Without them the popover says
so, and the install starts by itself once they are there. It runs:

```bash
npm install --prefix ~/.local/share/teamclaude --no-audit --no-fund @karpeleslab/teamclaude@1.1.31
ln -s ~/.local/share/teamclaude/node_modules/.bin/teamclaude ~/.local/bin/teamclaude
```

The version is the registry's latest release. A file that already sits at the link's path is
left alone, and the install stops there.

A new TeamClaude has no account, and its proxy exits as it starts while it has none, so the app
does not start it yet. **Add Account** runs `teamclaude login --oauth` (or `teamrouter login --oauth`
once installed under `teamrouter`), which opens claude.ai in the browser and adds the account signed
in there. The app then runs:

```bash
~/.local/bin/teamclaude service install
```

This is TeamClaude's own command: it writes the LaunchAgent and loads it, which starts the proxy
now and at every login. The app waits up to 45 seconds for the proxy to answer. When a
LaunchAgent is already there, the app skips the command and waits for the proxy, which launchd
starts again by itself.

While the proxy does not answer and no config file (`teamrouter.json` / `teamclaude.json`) exists yet,
the app prompts **Add Account** instead of restarting an empty proxy. It never reads or parses the
config file.

When TeamClaude is installed with a config file but has no LaunchAgent and does not answer, the
popover offers **Start at Login**, which runs `teamclaude service install`. The app never runs
that command while the proxy answers, because it would restart it.

The app runs every proxy CLI command with the folder of its Node first on the `PATH`: the `node`
of the config, the Node beside the CLI, and the one the LaunchAgent runs.

## Updates

The app inspects the installed `package.json` (`teamrouter` or `@karpeleslab/teamclaude`, following a
2.0 shim to `teamrouter`) and asks the npm registry for that package's latest release every 6 hours,
and again after 15 minutes when a check fails. It does not rely on the proxy's `updateAvailable` flag,
which can be stale, or on `teamclaude update`, which does not update a prefix install like the one
the LaunchAgent runs.

**Update…** in the Sources tab asks for confirmation, since restarting the proxy interrupts active
sessions, then runs:

```bash
npm install --prefix ~/.local/share/teamclaude --no-audit --no-fund <package>@<version>
launchctl kickstart -k gui/$(id -u)/<active-service-label>
```

It refreshes the CLI symlink if needed and waits up to 30 seconds for the proxy to report the new
version. Only plain `x.y.z` release versions and the two supported package names (`teamrouter`,
`@karpeleslab/teamclaude`) are ever passed to npm.

A copy that is not in `teamclaudeInstallDir` is updated where it lives: the card shows **Copy
command**, which copies `teamrouter update` or `teamclaude update` to match the installed binary.

After a Codex login (`teamclaude login --codex` / `teamrouter login --codex`), the app calls
`POST /teamclaude/reload` (or `/teamrouter/reload`) on the running proxy so it picks up the new
sign-in immediately. A Claude login reloads automatically.
