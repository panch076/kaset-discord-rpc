# Kaset Discord Presence
# THIS IS AI SLOP
i made this for myself solely using claude so use at your own risk and dont complain
yes i know ai is bad blah blah blah

Shows what you're playing in [Kaset](https://github.com/sozercan/kaset) as Discord Rich Presence
("Listening to …" with title, artist, album art, progress bar, and a YouTube Music button).

## How it works

```
Kaset (YouTube Music WebView)
  └─ extension/content.js     reads navigator.mediaSession + <video> state
       └─ extension/background.js  POSTs to http://127.0.0.1:47321/presence
            └─ bridge (LaunchAgent)  speaks Discord's local IPC socket → Rich Presence
```

A WebKit extension can't open Discord's Unix socket, and Kaset doesn't implement
native messaging, so a tiny loopback-only helper does that part. Requests must
carry a random token generated at install time.

## Install

1. Create a Discord application at <https://discord.com/developers/applications>.
   Its **name** is what shows after "Listening to" (e.g. `Kaset` or `YouTube Music`).
   Copy its **Application ID**.
2. `./install.sh <application-id>`
3. Kaset → Settings (⌘,) → Extensions → **+** → choose the `extension` folder → restart Kaset.

Discord must have *Settings → Activity Privacy → Share your detected activities* enabled.

## Configure

Edit `~/Library/Application Support/KasetDiscordPresence/config.json`, then
`launchctl kickstart -k gui/$(id -u)/com.kaset.discord-presence`.

- `clearOnPause` — `true` hides the presence while paused; `false` shows "Paused".
- `statusDisplay` — what your status line shows after "Listening to": `"name"` (app name), `"artist"`, or `"title"`.
- `lyrics` — show the current synced lyric line from [LRCLIB](https://lrclib.net). Discord rate-limits
  activity updates (~5 per 20s), so updates are spaced at least 4s apart. Most songs show one line at
  a time. Fast songs (where more than 25% of lines would be skipped that way) show the lines sung
  since the last update together, ending with the line being sung now (`♪ previous line / current line`),
  so lyrics never appear before they're sung. Preview the chunks for a song with:
  `~/Library/Application\ Support/KasetDiscordPresence/kaset-discord-bridge --lyrics "Title" "Artist" [seconds]`

If you re-run `install.sh`, the token is preserved, so you don't need to re-add the extension.

## Troubleshooting

- Log: `~/Library/Logs/KasetDiscordPresence.log`
- Health: `curl 127.0.0.1:47321/health`
- `Invalid Client ID` in the log → wrong application ID passed to `install.sh`.

## Uninstall

`./uninstall.sh`, then remove the extension in Kaset → Settings → Extensions.
