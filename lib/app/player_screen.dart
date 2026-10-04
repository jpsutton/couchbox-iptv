import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../player/live_player.dart';
import 'keys.dart';
import 'options_menu.dart';
import 'repository.dart';
import 'tuner.dart';
import 'widgets.dart';

/// Full-screen playback. Up/Down, Channel Up/Down or Next/Previous change
/// channel, digits tune by number, OK shows what's on and Info toggles it,
/// Menu has options. Play/Pause pauses live TV (the cache keeps filling);
/// Rewind and Fast Forward move within the cache, never past live. Back
/// returns to the guide with the channel still playing in its preview; Stop
/// stops it.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.repository,
    required this.tuner,
    required this.channels,
    required this.allChannels,
    required this.start,
  });

  final Repository repository;
  final Tuner tuner;

  /// The list the viewer came from (a filter), for Up/Down.
  final List<ChannelEntry> channels;

  /// Every channel, for tuning by number.
  final List<ChannelEntry> allChannels;
  final int start;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late List<ChannelEntry> _channels = widget.channels;
  late int _index = widget.start;
  bool _banner = true;

  /// Fade only when the banner times out; Info shows and hides it at once.
  bool _fade = false;

  /// Out of the tree once faded, so nothing of it is left on screen.
  bool _bannerGone = false;
  Timer? _bannerTimer;

  /// Seconds behind live after a pause or rewind, shown in the banner. mpv
  /// always reads some seconds ahead of playback, so that normal lead
  /// ([_lead], measured while not time-shifted) is subtracted.
  double _behind = 0;
  double _lead = 0;
  bool _timeshifted = false;
  Timer? _behindTimer;
  String _digits = '';
  Timer? _digitTimer;
  Map<String, List<Programme>> _guide = {};

  @override
  void initState() {
    super.initState();
    widget.tuner.state.addListener(_onTuner);
    widget.tuner.paused.addListener(_onTuner);
    _behindTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateBehind());
    // Coming from the guide's preview: already on this channel.
    final current = widget.tuner.state.value;
    if (current.channel?.id == _channels[_index].id && current.phase != PlayerPhase.failed) {
      final now = DateTime.now();
      _guide = widget.repository.programmes(now, now.add(const Duration(hours: 4)));
      _showBanner();
    } else {
      // After the first frame: tuning notifies listeners, which rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _tune() : null);
    }
  }

  @override
  void dispose() {
    widget.tuner.state.removeListener(_onTuner);
    widget.tuner.paused.removeListener(_onTuner);
    _bannerTimer?.cancel();
    _behindTimer?.cancel();
    _digitTimer?.cancel();
    super.dispose();
  }

  void _onTuner() {
    if (!mounted) return;
    setState(() {});
    final phase = widget.tuner.state.value.phase;
    if (phase == PlayerPhase.playing) _showBanner();
  }

  Future<void> _updateBehind() async {
    if (widget.tuner.state.value.phase != PlayerPhase.playing) return;
    final ahead = await widget.tuner.behindLive();
    if (!mounted || ahead == null) return;
    if (!_timeshifted) {
      _lead = ahead;
      return;
    }
    final behind = (ahead - _lead).clamp(0.0, double.infinity);
    // Caught up (fast forward, or Back to live).
    if (behind < 5 && !widget.tuner.paused.value) {
      setState(() {
        _timeshifted = false;
        _behind = 0;
      });
    } else if ((behind - _behind).abs() >= 1) {
      setState(() => _behind = behind);
    }
  }

  void _timeshift() => _timeshifted = true;

  void _tune() {
    _behind = 0;
    _timeshifted = false;
    final now = DateTime.now();
    _guide = widget.repository.programmes(now, now.add(const Duration(hours: 4)));
    _showBanner(hold: true);
    widget.tuner.tune(_channels[_index]);
  }

  void _step(int by) {
    if (_channels.isEmpty) return;
    setState(() => _index = (_index + by) % _channels.length);
    _tune();
  }

  /// Shows the banner; it hides 5 s after the picture appears.
  void _showBanner({bool hold = false}) {
    _bannerTimer?.cancel();
    setState(() {
      _banner = true;
      _fade = false;
      _bannerGone = false;
    });
    if (!hold) {
      _bannerTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        setState(() {
          _banner = false;
          _fade = true;
        });
      });
    }
  }

  /// Info: show the banner, or hide it if it is showing.
  void _toggleBanner() {
    if (_banner && widget.tuner.state.value.phase == PlayerPhase.playing) {
      _bannerTimer?.cancel();
      setState(() {
        _banner = false;
        _fade = false;
        _bannerGone = true;
      });
    } else {
      _showBanner();
    }
  }

  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() => _digits = '$_digits$d'.substring(_digits.length >= 4 ? 1 : 0));
    _digitTimer = Timer(const Duration(milliseconds: 1500), _tuneDigits);
  }

  void _tuneDigits() {
    final number = int.tryParse(_digits);
    setState(() => _digits = '');
    if (number == null) return;
    final channel = widget.allChannels.where((c) => c.number == number).firstOrNull;
    if (channel == null) return;
    // Tuning by number leaves the filtered list for the full one.
    setState(() {
      _channels = widget.allChannels;
      _index = widget.allChannels.indexOf(channel);
    });
    _tune();
  }

  /// Back to the guide; [stop] also stops playback.
  Future<void> _leave({bool stop = false}) async {
    if (stop) await widget.tuner.stop();
    if (mounted) Navigator.of(context).pop();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!isPress(event)) return KeyEventResult.handled;
    switch (remoteKey(event)) {
      case RemoteKey.up || RemoteKey.channelUp || RemoteKey.next:
        _step(1);
      case RemoteKey.down || RemoteKey.channelDown || RemoteKey.previous:
        _step(-1);
      case RemoteKey.playPause:
        if (!widget.tuner.paused.value) _timeshift();
        widget.tuner.setPaused(!widget.tuner.paused.value);
        _showBanner();
      case RemoteKey.play:
        widget.tuner.setPaused(false);
        _showBanner();
      case RemoteKey.pause:
        _timeshift();
        widget.tuner.setPaused(true);
        _showBanner();
      case RemoteKey.rewind:
        _timeshift();
        widget.tuner.seekBy(-10);
        _showBanner();
      case RemoteKey.fastForward:
        widget.tuner.seekBy(30);
        _showBanner();
      case RemoteKey.info:
        _toggleBanner();
      case RemoteKey.ok || RemoteKey.left || RemoteKey.right:
        _showBanner();
      case RemoteKey.back:
        _leave();
      case RemoteKey.stop:
        _leave(stop: true);
      case RemoteKey.menu:
        _menu();
      case RemoteKey.digit:
        _digit(digitOf(event)!);
      case RemoteKey.other:
        break;
    }
    return KeyEventResult.handled;
  }

  void _menu() {
    final channel = _channels[_index];
    final state = widget.tuner.state.value;
    showOptionsMenu(context, '${channel.number}  ${channel.name}', [
      MenuOption(channel.favourite ? 'Remove from Favourites' : 'Add to Favourites', () {
        channel.favourite = !channel.favourite;
        widget.repository.setFavourite(channel.id, channel.favourite);
        setState(() {});
      }),
      if (state.attempt > 0 && state.attempt < channel.streams.length)
        MenuOption('Try another stream (${state.attempt + 1} of ${channel.streams.length})', () {
          _showBanner(hold: true);
          widget.tuner.nextStream();
        }),
      if (_timeshifted)
        MenuOption('Back to live', () {
          widget.tuner.setPaused(false);
          widget.tuner.seekBy(1 << 20);
        }),
      MenuOption('Back to the guide', _leave),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.tuner.state.value;
    final channel = _channels[_index];
    final (:now, :next) = nowAndNext(_guide[channel.id], DateTime.now());
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Transparent: the native video plane shows through.
          Positioned.fill(child: widget.tuner.player.view()),
          // Keeps every frame non-empty. With the overlays gone the screen
          // drew nothing, and the last frame with them stayed up (see also
          // clear_window_cb in linux/runner/my_application.cc).
          const Positioned(left: 0, top: 0, width: 1, height: 1, child: ColoredBox(color: Color(0x01000000))),
          if (state.phase != PlayerPhase.playing) const Positioned.fill(child: ColoredBox(color: Colors.black)),
          if (state.phase == PlayerPhase.opening || state.phase == PlayerPhase.failed)
            Center(child: _status(state, channel)),
          if (!_bannerGone || state.phase != PlayerPhase.playing)
            Positioned(
              left: 48,
              right: 48,
              bottom: 40,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _banner || state.phase != PlayerPhase.playing ? 1 : 0,
                  duration: _fade ? const Duration(milliseconds: 600) : Duration.zero,
                  onEnd: () {
                    if (mounted && !_banner) setState(() => _bannerGone = true);
                  },
                  child: _bannerPanel(channel, now, next, state),
                ),
              ),
            ),
          // Stays while paused, after the banner has gone.
          if (state.phase == PlayerPhase.playing && widget.tuner.paused.value)
            Positioned(top: 40, left: 56, child: _pausedBadge()),
          if (_digits.isNotEmpty)
            Positioned(
              top: 40,
              right: 56,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(color: Tv.panel, borderRadius: BorderRadius.circular(12)),
                child: Text(_digits, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pausedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(color: Tv.panel, borderRadius: BorderRadius.circular(12)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.pause, size: 32),
          SizedBox(width: 12),
          Text('Paused', style: TextStyle(fontSize: Tv.small)),
        ],
      ),
    );
  }

  /// "Live", or how far behind after a pause or rewind.
  String get _liveText {
    if (!_timeshifted || _behind < 1) return 'Live';
    final behind = Duration(seconds: _behind.round());
    return '${behind.inMinutes}:${(behind.inSeconds % 60).toString().padLeft(2, '0')} behind live';
  }

  Widget _status(TunerState state, ChannelEntry channel) {
    final text = state.phase == PlayerPhase.failed
        ? '${state.message ?? 'Could not play this channel'}\nUp/Down for another channel'
        : channel.streams.length > 1
        ? 'Tuning (stream ${state.attempt} of ${channel.streams.length})'
        : 'Tuning';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.phase == PlayerPhase.opening) const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: Tv.body),
        ),
      ],
    );
  }

  Widget _bannerPanel(ChannelEntry channel, Programme? now, Programme? next, TunerState state) {
    final at = DateTime.now();
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Tv.panel, borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${channel.number}',
            style: const TextStyle(fontSize: Tv.title, color: Colors.white70),
          ),
          const SizedBox(width: 24),
          ChannelLogo(name: channel.name, path: channel.logoPath, size: 96),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        channel.name,
                        style: const TextStyle(fontSize: Tv.title, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.favourite) const Padding(padding: EdgeInsets.only(left: 12), child: Icon(Icons.star)),
                    const Spacer(),
                    Text(
                      clock(at),
                      style: const TextStyle(fontSize: Tv.body, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (now != null) ...[
                  Text(
                    '${clock(now.start)}-${clock(now.stop)}  ${now.title}${now.subtitle == null ? '' : ': ${now.subtitle}'}',
                    style: const TextStyle(fontSize: Tv.body),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(value: progress(now, at), minHeight: 6),
                  ),
                  if (now.description != null)
                    Text(
                      now.description!,
                      style: const TextStyle(fontSize: Tv.small, color: Colors.white70),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ] else
                  const Text(
                    'No guide information',
                    style: TextStyle(fontSize: Tv.body, color: Colors.white54),
                  ),
                if (next != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Next: ${clock(next.start)}  ${next.title}',
                      style: const TextStyle(fontSize: Tv.small, color: Colors.white54),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (state.phase == PlayerPhase.playing)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      [_liveText, ?state.stream?.quality].join('  ·  '),
                      style: const TextStyle(fontSize: Tv.small, color: Colors.white38),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
