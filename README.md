# couchbox-iptv

Free internet TV for couchbox: the public channels listed by
[iptv-org](https://github.com/iptv-org/iptv), with a channel guide, built for
a TV remote. Flutter, Linux only.

Status: **M0, the player comparison.** The app plays a fixed list of test
streams (`assets/m0_streams.json`) on two mpv backends behind one interface
(`lib/player/live_player.dart`):

- `native`: mpv draws into a Wayland subsurface below the window (vendored
  from Plezy, `linux/runner/mpv/`).
- `media_kit`: mpv draws into a Flutter texture.

`couchbox-iptv --bench` tunes each stream on both and writes tune time, CPU,
dropped frames and the hardware decoder in use to
`~/.local/share/couchbox-iptv/m0-results.json`.

Set `COUCHBOX_IPTV_WINDOWED=1` to run in a window instead of full screen.
