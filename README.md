# DaVinci Resolve Discord Rich Presence

Shows what you're doing in DaVinci Resolve on your Discord profile, for example:

```
Playing DaVinci Resolve
My Project
Editing a video
0:27 elapsed
```

While a render is running, the state line changes to `Rendering · 45%`.

It runs as a small background agent that starts at login. It does nothing
while Resolve is closed, shows your presence as soon as Resolve opens, and
clears it when Resolve quits. It only uses tools that come with macOS and
Resolve, so there's nothing else to install.

## Requirements

- macOS
- DaVinci Resolve Studio, with **Preferences > System > General > External
  scripting using** set to **Local**
- The Discord desktop app

## Install

```sh
./install.sh
```

To remove it, run `./uninstall.sh` (add `--purge` to also delete your settings).

## Settings

Edit `~/Library/Application Support/resolve-discord-rpc/config.json`. Changes
apply within a few seconds.

| Key | Default | |
|---|---|---|
| `showProject` | `true` | Show the project name |
| `showTimeline` | `false` | Show the timeline name |
| `clientId` | built in | Use your own Discord application; its name is what appears after "Playing" |
| `largeImage` | built in | Image URL (or uploaded asset name) for the large image |

## How it works

Resolve has no way to run a script automatically at launch, so
`resolve-rpc.pl` runs as a launch agent and watches for the Resolve process.
When Resolve opens, it starts `collector.lua` under `fuscript` (Resolve's own
script interpreter), which reads the current page, project, timeline and render
status through Resolve's scripting API. `resolve-rpc.pl` turns that into a
presence and sends it over Discord's local IPC socket.

The log is at `~/Library/Application Support/resolve-discord-rpc/resolve-rpc.log`.

## Credits

DaVinci Resolve logo by Blackmagic Design, via [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:DaVinci_Resolve_Studio.png) (CC BY-SA 4.0).
