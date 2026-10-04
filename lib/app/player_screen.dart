import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../player/live_player.dart';
import 'keys.dart';
import 'options_menu.dart';
import 'repository.dart';
import 'tuner.dart';
import 'widgets.dart';

/// Full-screen playback. Up/Down or Channel Up/Down change channel, digits
/// tune by number, OK or Info shows what's on, Menu has options. Back returns
/// to the guide with the channel still playing in its preview; Stop stops it.
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
  Timer? _bannerTimer;
  String _digits = '';
  Timer? _digitTimer;
  Map<String, List<Programme>> _guide = {};

  @override
  void initState() {
    super.initState();
    widget.tuner.state.addListener(_onTuner);
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
    _bannerTimer?.cancel();
    _digitTimer?.cancel();
    super.dispose();
  }

  void _onTuner() {
    if (!mounted) return;
    setState(() {});
    final phase = widget.tuner.state.value.phase;
    if (phase == PlayerPhase.playing) _showBanner();
  }

  void _tune() {
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
      case RemoteKey.up || RemoteKey.channelUp:
        _step(1);
      case RemoteKey.down || RemoteKey.channelDown:
        _step(-1);
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
          if (state.phase != PlayerPhase.playing) const Positioned.fill(child: ColoredBox(color: Colors.black)),
          if (state.phase == PlayerPhase.opening || state.phase == PlayerPhase.failed)
            Center(child: _status(state, channel)),
          Positioned(
            left: 48,
            right: 48,
            bottom: 40,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _banner || state.phase != PlayerPhase.playing ? 1 : 0,
                duration: _fade ? const Duration(milliseconds: 600) : Duration.zero,
                child: _bannerPanel(channel, now, next, state),
              ),
            ),
          ),
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
                if (state.stream?.quality != null && state.phase == PlayerPhase.playing)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      state.stream!.quality!,
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
