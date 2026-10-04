# Vendored: Plezy's native mpv player for Linux

These files (and `../wayland/`, `../../../shared/`) come from Plezy
(https://github.com/edde746/plezy, GPL-3.0), tag 2.22.0, commit
1c2381f0da4a75d0e16b2dd8745551bb816de9fb:

- `linux/runner/mpv/*` (tests left out)
- `linux/runner/wayland/*` (color-management-v1 protocol)
- `shared/mpv/mpv_player_common.h`, `shared/cpp/sanitize_utf8.h`

mpv renders into a Wayland subsurface below the transparent Flutter window, so
video goes to the compositor without a copy through Flutter. Dart talks to it
over the method channel `org.couchbox.iptv/mpv` (events on `.../events`); see
`lib/player/native_mpv_player.dart`.

Local changes, kept small so updates from Plezy apply cleanly:

- the channel names (`com.plezy/mpv_player` -> `org.couchbox.iptv/mpv`, and the
  audio-only one, which couchbox-iptv does not register).

To update: copy the same files from a newer Plezy tag and reapply the rename.

Not from Plezy: `my_application.cc` clears the transparent window before each
frame (`clear_window_cb`). Without it, overlays that fade out over the video
leave a faint copy behind, because Flutter's GTK compositor draws each frame
over the previous one. Plezy 2.22.0 has the same gap.
