# DaVinci Resolve Discord Rich Presence

Shows what you're doing in DaVinci Resolve on your Discord profile, for example:

```
Playing DaVinci Resolve
My Project
Editing a video · Timeline 1
14:02:33 elapsed
```

- The timer shows the **total time you've spent on the project**, across
  sessions. Time while the computer sleeps isn't counted.
- On the Color page it shows which clip you're grading: `Color grading · clip 12 of 29`.
- While a render is running: `Rendering · 45%`.
- A small icon shows which page you're on.

It runs as a small background agent that starts at login. It does nothing
while Resolve is closed, shows your presence as soon as Resolve opens, and
clears it when Resolve quits. It runs entirely on Resolve's own script
interpreter, so there's nothing else to install.

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
| `showTimeline` | `true` | Show the timeline name on the Cut and Edit pages |
| `showClipPosition` | `true` | Show "clip 12 of 29" on the Color page |
| `showPageIcons` | `true` | Show a small icon for the current page |
| `projectTimer` | `true` | Timer shows total time on the project; `false` shows time since Resolve opened |
| `clientId` | built in | Use your own Discord application; its name is what appears after "Playing" |
| `largeImage` | built in | Image URL (or uploaded asset name) for the large image |

## How it works

Resolve has no way to run a script automatically at launch, so `presence.lua`
runs under `fuscript` (Resolve's script interpreter) as a launch agent and
waits for Resolve to open. It reads the current page, project, timeline and
render status through Resolve's scripting API, and sends the presence to
Discord with `discord_ipc.lua`. That file talks to Discord's local IPC socket
directly through LuaJIT's FFI (a Unix socket on macOS, a named pipe on
Windows), so no other runtime is needed.

Time per project is kept in `project-time.tsv` next to the config.

The log is at `~/Library/Application Support/resolve-discord-rpc/presence.log`.

## Credits

- DaVinci Resolve logo by Blackmagic Design, via [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:DaVinci_Resolve_Studio.png) (CC BY-SA 4.0).
- Page icons from [Twemoji](https://github.com/jdecked/twemoji) (CC BY 4.0).
