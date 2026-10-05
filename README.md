# couchbox-iptv

Free internet TV for [couchbox](https://github.com/jpsutton/couchbox): the
public channels listed by [iptv-org](https://github.com/iptv-org/iptv), in a
channel guide built for a TV remote. Flutter, Linux (Wayland) only. GPL-3.0.

Two programs:

- **`couchbox-iptv`**, the app: a guide grid with a live preview, and a
  full-screen player.
- **`couchbox-iptv-refresh`**, the background job: downloads the channel list,
  checks every stream, fetches the guide and logos, and writes a local
  database the app reads.

**Status:** the app and the job work and run on two couchbox boxes from test
builds. Not packaged yet: the couchbox package, the Bigscreen tile and the
timers as part of an install are the next milestone (M4, see
[docs/plan.md](docs/plan.md)).

## The app

### Guide

The home screen: channels down the side, half-hour columns over three hours,
a line at the current time. On top, the focused programme's details and the
chosen channel playing in a small preview box. A category bar (All,
Favourites, then iptv-org's categories) filters the channels; channels with
guide data come first.

| Key | In the guide |
|---|---|
| Up / Down | Move between channels |
| Left / Right | Step through programmes (half hours where there is no guide), up to 12 hours ahead, never into the past |
| Channel Up / Down, Next / Previous | A whole page of channels |
| OK, Play | Watch the focused channel full screen |
| Digits | Jump to a channel number |
| Home (tap) | Jump to the category bar and back |
| Menu | Watch, Favourites, Hide this channel, Use ignored streams again |
| Back | Back to now; pressed again, stop the preview |
| Stop | Stop the preview |

The preview plays the chosen channel (the last one watched) and doesn't follow
the focus.

### Player

| Key | In the player |
|---|---|
| Channel Up / Down, Up / Down, Next / Previous | Browse channels in the banner without tuning; OK tunes the one shown |
| OK | Show the info banner (now, next, description) |
| Info | Show or hide the banner |
| Digits | Tune a channel number |
| Pause, Play, Play/Pause | Pause live TV; the stream keeps buffering |
| Left / Right | 10 s back / on within the buffer, never past live |
| Rewind / Fast Forward | 10 s back / 30 s on |
| Menu | Favourites, Try another stream, Don't use this stream, Back to live, Back to the guide |
| Back, Home (tap) | Back to the guide, the channel still playing in the preview |
| Stop | Stop and go back to the guide |

The banner fades out after 5 s. A channel's streams are tried in turn until
one shows a picture within 15 s; a stream that fails in the player goes to the
back of the list for a week, and "Don't use this stream" moves it to the end
for good. While paused or after rewinding, the banner shows how far behind
live you are; the buffer holds a few minutes at typical bitrates.

### Also

- **Screen stays on** while a stream plays and isn't paused
  (`org.freedesktop.ScreenSaver.Inhibit`).
- **Stops when out of sight:** when couchbox minimizes the window (long Home)
  or another app comes to the front, the stream stops and the channel is
  tuned again when the app is back. On Wayland an app isn't told it was
  minimized, so couchbox's KWin script (`couchbox-home`, via the
  `couchbox-focus` helper) calls the app over D-Bus: service
  `org.couchbox.iptv`, object `/org/couchbox/iptv`, interface
  `org.couchbox.iptv.Window`, methods `Hidden` and `Shown`.
- **Audio and subtitle languages:** the preferred ones (English, subtitles
  off by default) are passed to mpv as `alang` and `slang`.

### Remote keys

Keys come from couchbox's [fire-blaster](https://github.com/jpsutton/fire-blaster),
which remaps the remotes. Some Media Center remote keys have no XKB name and
reach Flutter by evdev code instead (Channel Up/Down, Info, the number pad);
`lib/app/keys.dart` matches them. `COUCHBOX_IPTV_KEYS=1` logs every key, to see
what a new remote sends.

### Video

mpv draws into a Wayland subsurface below the window (the native plane
vendored from Plezy, `linux/runner/mpv/`), with VA-API decoding; the Flutter
window is transparent where the video shows. M0 compared it with media_kit's
texture: same decoding, about a third of the CPU ([docs/m0.md](docs/m0.md)).
The player sits behind one interface, `lib/player/live_player.dart`.

## The refresh job

`couchbox-iptv-refresh` runs as a systemd user service:
`couchbox-iptv-refresh.timer` nightly at 04:00 (catching up if the box was
off), and `couchbox-iptv-guide.timer` every 4 hours for the guide only
(`--no-catalog --no-check --no-logos`). Units in `dist/systemd/`.

1. **Catalog:** downloads iptv-org's API files (`channels`, `feeds`,
   `streams`, `logos`, `blocklist`; ETag-cached) and keeps the channels the
   settings ask for. NSFW, blocklisted and closed channels are always left
   out. Pluto TV streams iptv-org lists without a channel record become
   channels of their own when Pluto's guide lists them (`pluto.<id>`); other
   streams with the same title join them.
2. **Check:** fetches each stream's playlist and the start of one segment,
   and records working or dead. Streams checked in the last 12 hours are
   skipped (`--recheck-after`), so a stopped run resumes.
3. **Guide:** [i.mjh.nz](https://i.mjh.nz)'s Pluto TV guide, matched through
   the `jmp2.uk/plu-<id>` stream links. Other channels show "No information".
4. **Logos:** downloaded and cached.

It never competes with what's on screen: idle CPU and disk priority (in the
unit), and 12 checks at a time, 4 with a gap while anything plays (it watches
`pactl` for an active output stream). Channel numbers, once given, stay.

## Files

| Path | What |
|---|---|
| `~/.config/couchbox-iptv/settings.json` | Countries (default `US`), languages (`eng`), categories (all), audio and subtitle languages, preview. No settings screen yet; edit the file. Channels with no working stream are always hidden. |
| `~/.local/share/couchbox-iptv/iptv.db` | SQLite: channels, streams, programmes, channel numbers, and the app's favourites, hidden channels, playback failures and ignored streams |
| `~/.cache/couchbox-iptv/` | iptv-org API files, the Pluto guide, logos |

## Building

Needs Flutter 3.47.1 (the same as couchbox's Plezy build), and the system's
mpv (libmpv), GTK 3, wayland, EGL, libepoxy and sqlite.

```
flutter build linux --release      # the app: build/linux/x64/release/bundle/
dart build cli -o build/refresh    # the job: build/refresh/bundle/bin/
flutter analyze && flutter test
```

`COUCHBOX_IPTV_WINDOWED=1` runs the app in a window instead of full screen.

## Layout

| Path | What |
|---|---|
| `lib/app/` | The guide, the player, remote keys, the tuner |
| `lib/player/` | The player interface and the native mpv plane's Dart side |
| `lib/data/` | iptv-org records, channel selection, the database |
| `lib/refresh/` | The refresh job: downloads, stream checks, guide, throttle |
| `bin/couchbox_iptv_refresh.dart` | The job's entry point |
| `linux/runner/` | The GTK runner, with the native mpv plane in `mpv/` (from Plezy; see its README) |
| `dist/` | Desktop file and systemd units |
| `docs/` | The plan and the M0 player comparison |

## License

GPL-3.0; it includes code from [Plezy](https://github.com/edde746/plezy), also
GPL-3.0. See [LICENSE.md](LICENSE.md).
