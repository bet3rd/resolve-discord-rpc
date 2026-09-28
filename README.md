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
- A small icon shows which page you're on, using Resolve's own page icons.

It runs in the background from the moment you log in. It does nothing while
Resolve is closed, shows your presence as soon as Resolve opens, and clears it
when Resolve quits. It runs entirely on Resolve's own script interpreter, so
there's nothing else to install.

## Requirements

- macOS or Windows 10/11
- DaVinci Resolve **Studio** (the free version doesn't allow external scripting)
- In Resolve, **Preferences > System > General > External scripting using**
  set to **Local**
- The Discord desktop app

## Install

Download this repository (**Code > Download ZIP**, or `git clone`), then run
the installer from its folder.

**macOS**, in Terminal:

```sh
./install.sh
```

**Windows**, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Your presence appears the next time you open Resolve (or within a few seconds,
if it's already open).

### Uninstall

- macOS: `./uninstall.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File uninstall.ps1`

Your settings and project times are kept. Add `--purge` (macOS) or `-Purge`
(Windows) to delete them too.

## Settings

Edit `config.json` in the data folder. Changes apply within a few seconds.

- macOS: `~/Library/Application Support/resolve-discord-rpc/`
- Windows: `%APPDATA%\resolve-discord-rpc\`

| Key | Default | |
|---|---|---|
| `showProject` | `true` | Show the project name |
| `showTimeline` | `true` | Show the timeline name on the Cut and Edit pages |
| `showClipPosition` | `true` | Show "clip 12 of 29" on the Color page |
| `showPageIcons` | `true` | Show a small icon for the current page |
| `projectTimer` | `true` | Timer shows total time on the project; `false` shows time since Resolve opened |
| `clientId` | built in | Use your own Discord application; its name is what appears after "Playing" |
| `largeImage` | built in | Image URL (or uploaded asset name) for the large image |

The same folder holds `project-time.tsv` (time spent per project) and
`presence.log`.

## How it works

Resolve has no way to run a script automatically at launch, so the installer
registers `presence.lua` to start at login: a launch agent on macOS, a
scheduled task on Windows. It runs under `fuscript`, Resolve's script
interpreter, and waits for Resolve to open. It then reads the current page,
project, timeline and render status through Resolve's scripting API.

`discord_ipc.lua` sends the presence to the Discord app over its local IPC
connection (a Unix socket on macOS, a named pipe on Windows). It does this
through LuaJIT's FFI, which is built into `fuscript`, so no other runtime is
needed.

## Credits

- DaVinci Resolve logo by Blackmagic Design, via
  [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:DaVinci_Resolve_Studio.png)
  (CC BY-SA 4.0).
- Page icons are from DaVinci Resolve's interface.

DaVinci Resolve is a trademark of Blackmagic Design. This project isn't
affiliated with or endorsed by Blackmagic Design.
