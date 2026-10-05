# couchbox-iptv plan

A Flutter app for the free internet TV channels listed by iptv-org, with a
channel guide, built for a remote; plus a background job that refreshes the
channels and guide. A tile on the Bigscreen home screen opens it. GPL-3.0.

## Data

iptv-org's API (`https://iptv-org.github.io/api/`), not its `.m3u` playlists:

| File | Records (2026-10) | Use |
|---|---|---|
| `channels.json` | 31,487 | Name, country, categories, NSFW flag, closed or replaced |
| `streams.json` | 18,139 | URL, quality, required User-Agent or Referer |
| `feeds.json` | 44,979 | Regional versions: languages, time zones, broadcast area |
| `logos.json` | 35,120 | Logos |
| `guides.json` | 180,681 | Which site has each channel's schedule (for iptv-org/epg) |
| `categories`, `countries`, `languages` | 30 / 250 / 7,893 | Filter menus |
| `blocklist.json` | 1,440 | Always excluded (NSFW, legal) |

## Background job: `couchbox-iptv-refresh`

A systemd user service with a timer: nightly at 04:00 (`Persistent=true`), and
whenever the filters change.

1. Download the API files; keep channels matching the filters. NSFW and
   blocklisted channels are always out.
2. Check each kept stream: fetch its playlist, then one segment, with a
   timeout. Record working or dead and the response time.
3. Fetch guide data for the kept channels (see Guide data).
4. Write a SQLite database, `~/.local/share/couchbox-iptv/iptv.db`: channels,
   streams with health, programmes, logos. Cache logos.

Dart, as a second entry point in this repo, sharing the data and database code
with the app.

### Never disrupting playback

The job may run at any time, including while someone uses the TV; it must
never disturb what is on screen.

- **CPU and disk:** the service runs at the lowest priority:

  ```ini
  [Service]
  Nice=19
  CPUSchedulingPolicy=idle
  IOSchedulingClass=idle
  CPUWeight=idle
  IOWeight=1
  ```

  On the M715q the user manager gets only the cpu, memory and pids
  controllers, so `IOWeight` does nothing there; `IOSchedulingClass=idle`
  still applies (checked 2026-10-04).
- **Network**, which no scheduler setting covers: few checks at a time, and
  only a playlist plus one short segment per stream: twelve at a time. While
  anything plays (an uncorked PipeWire stream, from `pactl -f json list
  sink-inputs`), four at a time with a 250 ms gap after each, rather than
  pausing.
- "Refresh now" in the app runs with the same limits.

## App

- **Guide:** channels as rows, 30-minute columns, about 12 hours ahead; a
  now line; details of the focused programme at the top with a small preview
  of the channel. OK tunes. A filter bar: categories, Favourites, All.
- **Channel list:** logos with now and next; search.
- **Player:** full screen. Channel Up/Down change channel, Info shows now
  and next, Back returns to the guide, Stop leaves the player, number keys
  tune by number (local numbers, kept stable).
- **Menu key on a channel:** favourite, hide, check again, try another stream.
- **Settings:** countries, languages, categories; preferred audio and
  subtitle languages (mpv `alang`/`slang`; default English, subtitles off);
  hide dead streams; refresh now and the last run's status.
- **Start:** last channel, or the guide.
- **Player backend:** the native mpv plane (decided in M0, `m0.md`), behind
  `LivePlayer`.
- **TV layout:** large focus outlines, 1080p at 10 feet, everything reachable
  from the remote.

## couchbox integration

- `packages/couchbox-iptv` in the couchbox repo builds this repo (fvm-pinned
  Flutter, as for Plezy) and ships the service and timer.
- couchbox-base: the tile (desktop file ID `org.couchbox.iptv`, the app's
  window ID), `visible-apps`, and the dependency.
- fire-blaster already sends Channel Up/Down, digits, Info, Stop and Menu.

## Guide data

| Option | For | Against |
|---|---|---|
| A. The guide named in iptv-org's playlist header (third-party host) | One download | Unknown coverage; may disappear |
| B. iptv-org/epg's grabber, run nightly for the kept channels | The supported route | Node.js on the box; slow; sites break |
| C. A first, B later | Fast start | Two code paths |

A turned out to cover 2 channels (2026-10-04), so M1 uses i.mjh.nz's Pluto
TV guide instead: iptv-org's Pluto streams go through i.mjh.nz's
`jmp2.uk/plu-<id>` links, so the id matches directly. With US and English
that is 353 of 1,190 channels. B (iptv-org/epg) for the rest comes in M5.
Channels without data show "No information".

## Milestones

| | Goal | Status |
|---|---|---|
| M0 | Player comparison on the M715q | Done: native plane (`m0.md`) |
| M1 | Background job and database | Done |
| M2 | Player and channel list | Done (the list became the guide in M3) |
| M3 | Guide | Done, plus what testing on the M715q asked for: channel browsing in the banner, pause and skip within the buffer, a fixed preview channel, stopping when out of sight, ignored streams, channel-less Pluto streams |
| M4 | Packaging, tile, timer, CI | |
| M5 | Polish: other streams per channel, search, guide option B | |

## Open questions

1. Separate GitHub repo `jpsutton/couchbox-iptv` (like fire-blaster)? Local
   only for now.
2. Default filters: US and English?
3. Guide data: option C?
4. Local channel numbers, or none?
5. Preview in the guide: one stream open while browsing; keep it?
