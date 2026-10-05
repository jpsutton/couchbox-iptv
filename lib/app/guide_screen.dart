import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../player/live_player.dart';
import '../settings.dart';
import 'guide_logic.dart';
import 'keys.dart';
import 'options_menu.dart';
import 'player_screen.dart';
import 'repository.dart';
import 'tuner.dart';
import 'widgets.dart';

/// The home screen: a grid of channels by half hours, the focused programme's
/// details on top and the chosen channel (the last one watched) playing in a
/// preview box beside them; moving the focus doesn't change it. OK or Play goes full screen, Menu has options, digits jump to a
/// channel, Channel Up/Down (or Next/Previous) page through the channels.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, required this.repository, required this.tuner, required this.settings});

  final Repository repository;
  final Tuner tuner;
  final Settings settings;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

// Layout, in logical pixels at 1920x1080.
const _margin = 48.0;
const _top = 32.0;
const _previewSize = Size(480, 270);
const _channelColumn = 340.0;
const _rowHeight = 84.0;
const _span = Duration(hours: 3);
const _background = Color(0xFF0B0E12);

class _GuideScreenState extends State<GuideScreen> {
  List<ChannelEntry> _all = [];
  Map<String, List<Programme>> _guide = {};
  List<String> _filters = ['All', 'Favourites'];
  List<GlobalKey> _filterKeys = [];
  int _filter = 0;
  bool _inFilterBar = false;
  int _row = 0;
  late DateTime _now;
  late DateTime _focus;
  late DateTime _windowStart;
  DateTime _loadedUntil = DateTime(0);
  final _rows = ScrollController();
  final _filterScroll = ScrollController();
  Timer? _tick;
  Timer? _previewTimer;
  String _digits = '';
  Timer? _digitTimer;
  late final AppLifecycleListener _lifecycle;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _focus = _now;
    _windowStart = floorToSlot(_now);
    _load();
    final last = widget.repository.lastChannel;
    final at = _visible.indexWhere((c) => c.id == last);
    if (at >= 0) _row = at;
    widget.tuner.state.addListener(_onTuner);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => _onTick());
    // The first preview waits until the window is on screen: a video plane
    // started before then gets no frame callbacks and shows one still frame
    // while the sound plays on.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToRow();
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _onResume();
    });
    // In case the window never reports itself active.
    Timer(const Duration(seconds: 3), () => mounted && !_started ? _onResume() : null);
  }

  @override
  void dispose() {
    widget.tuner.state.removeListener(_onTuner);
    _lifecycle.dispose();
    _tick?.cancel();
    _previewTimer?.cancel();
    _digitTimer?.cancel();
    _rows.dispose();
    _filterScroll.dispose();
    super.dispose();
  }

  void _onTuner() => mounted ? setState(() {}) : null;

  void _onResume() {
    if (!_started) {
      _started = true;
      Timer(const Duration(milliseconds: 800), () => mounted ? _schedulePreview(immediately: true) : null);
    } else {
      // Back on screen: the plane may have stopped presenting while hidden.
      widget.tuner.player.redraw();
    }
  }

  void _onTick() {
    setState(() {
      _now = DateTime.now();
      if (_focus.isBefore(_now)) _focus = _now;
      _windowStart = windowFor(_focus, _windowStart, _span, earliest: _now);
    });
    if (_loadedUntil.difference(_now) < const Duration(hours: 18)) setState(_loadGuide);
  }

  void _load() {
    _now = DateTime.now();
    _all = widget.repository.channels();
    _loadGuide();
    // Channels with a guide first, each part in number order.
    _all.sort((a, b) {
      final ga = _guide.containsKey(a.id) ? 0 : 1;
      final gb = _guide.containsKey(b.id) ? 0 : 1;
      return ga != gb ? ga.compareTo(gb) : a.number.compareTo(b.number);
    });
    final counts = <String, int>{};
    for (final c in _all) {
      for (final category in c.categories) {
        counts[category] = (counts[category] ?? 0) + 1;
      }
    }
    final categories = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    _filters = ['All', 'Favourites', ...categories];
    _filterKeys = [for (final _ in _filters) GlobalKey()];
    _filter = _filter.clamp(0, _filters.length - 1);
    _row = _row.clamp(0, _visible.isEmpty ? 0 : _visible.length - 1);
  }

  void _loadGuide() {
    _loadedUntil = _now.add(const Duration(hours: 24));
    _guide = widget.repository.programmes(_now.subtract(const Duration(hours: 1)), _loadedUntil);
  }

  List<ChannelEntry> get _visible => switch (_filter) {
    0 => _all,
    1 => _all.where((c) => c.favourite).toList(),
    _ => _all.where((c) => c.categories.contains(_filters[_filter])).toList(),
  };

  ChannelEntry? get _focused {
    final visible = _visible;
    return visible.isEmpty ? null : visible[_row.clamp(0, visible.length - 1)];
  }

  /// At start, plays the last channel watched in the preview box. Only
  /// choosing a channel (OK) changes it after that, not moving the focus:
  /// tuning on every move was too slow to browse with.
  void _schedulePreview({bool immediately = false}) {
    _previewTimer?.cancel();
    if (!widget.settings.preview || widget.tuner.state.value.channel != null) return;
    final last = widget.repository.lastChannel;
    final channel = _all.where((c) => c.id == last).firstOrNull;
    if (channel == null) return;
    _previewTimer = Timer(immediately ? Duration.zero : const Duration(milliseconds: 1200), () {
      if (mounted && widget.tuner.state.value.channel == null) widget.tuner.tune(channel);
    });
  }

  Future<void> _play() async {
    final visible = _visible;
    if (visible.isEmpty) return;
    _previewTimer?.cancel();
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => Material(
          type: MaterialType.transparency,
          child: PlayerScreen(
            repository: widget.repository,
            tuner: widget.tuner,
            channels: visible,
            allChannels: _all,
            start: _row,
          ),
        ),
      ),
    );
    if (!mounted) return;
    // Back on the channel that was playing (it may have changed).
    final playing = widget.tuner.state.value.channel?.id;
    setState(() {
      final at = _visible.indexWhere((c) => c.id == playing);
      if (at >= 0) _row = at;
    });
    _scrollToRow();
  }

  void _moveRow(int to) {
    final visible = _visible;
    if (visible.isEmpty) return;
    setState(() => _row = to.clamp(0, visible.length - 1));
    _scrollToRow();
  }

  /// Rows on screen: Channel Up/Down move a whole page.
  int get _pageRows {
    if (!_rows.hasClients) return 6;
    final rows = (_rows.position.viewportDimension / _rowHeight).floor();
    return rows < 1 ? 1 : rows;
  }

  void _scrollToRow() {
    if (!_rows.hasClients) return;
    final viewport = _rows.position.viewportDimension;
    final top = _row * _rowHeight;
    var offset = _rows.offset;
    if (top < offset) offset = top;
    if (top + _rowHeight > offset + viewport) offset = top + _rowHeight - viewport;
    _rows.jumpTo(offset.clamp(0, _rows.position.maxScrollExtent));
  }

  void _moveTime(int direction) {
    final channel = _focused;
    if (channel == null) return;
    setState(() {
      _focus = stepFocus(
        _guide[channel.id],
        _focus,
        direction,
        earliest: _now,
        latest: _now.add(const Duration(hours: 12)),
      );
      _windowStart = windowFor(_focus, _windowStart, _span, earliest: _now);
    });
  }

  void _selectFilter(int i) {
    setState(() {
      _filter = i.clamp(0, _filters.length - 1);
      _row = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _filterKeys[_filter].currentContext;
      if (chip != null) Scrollable.ensureVisible(chip, alignment: 0.5, duration: const Duration(milliseconds: 150));
    });
  }

  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() => _digits = '$_digits$d'.substring(_digits.length >= 4 ? 1 : 0));
    _digitTimer = Timer(const Duration(milliseconds: 1500), () {
      final number = int.tryParse(_digits);
      setState(() => _digits = '');
      if (number == null) return;
      var at = _visible.indexWhere((c) => c.number == number);
      if (at < 0 && _all.any((c) => c.number == number)) {
        setState(() => _filter = 0);
        at = _visible.indexWhere((c) => c.number == number);
      }
      if (at >= 0) _moveRow(at);
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!isPress(event)) return KeyEventResult.ignored;
    final key = remoteKey(event);
    if (_inFilterBar) {
      switch (key) {
        case RemoteKey.left:
          _selectFilter(_filter - 1);
        case RemoteKey.right:
          _selectFilter(_filter + 1);
        case RemoteKey.down || RemoteKey.ok:
          setState(() => _inFilterBar = false);
          _moveRow(0);
        default:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    switch (key) {
      case RemoteKey.up:
        if (_row == 0) {
          setState(() => _inFilterBar = true);
        } else {
          _moveRow(_row - 1);
        }
      case RemoteKey.down:
        _moveRow(_row + 1);
      case RemoteKey.channelUp || RemoteKey.previous:
        _moveRow(_row - _pageRows);
      case RemoteKey.channelDown || RemoteKey.next:
        _moveRow(_row + _pageRows);
      case RemoteKey.play || RemoteKey.playPause:
        _play();
      case RemoteKey.left:
        _moveTime(-1);
      case RemoteKey.right:
        _moveTime(1);
      case RemoteKey.ok:
        _play();
      case RemoteKey.menu:
        final channel = _focused;
        if (channel != null) _menu(channel);
      case RemoteKey.digit:
        _digit(digitOf(event)!);
      case RemoteKey.back:
        // Back to now; pressed again, stop the preview.
        if (_focus.difference(_now).inMinutes > 0) {
          setState(() {
            _focus = _now;
            _windowStart = floorToSlot(_now);
          });
        } else {
          _previewTimer?.cancel();
          widget.tuner.stop();
        }
      case RemoteKey.stop:
        _previewTimer?.cancel();
        widget.tuner.stop();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _menu(ChannelEntry channel) {
    showOptionsMenu(context, '${channel.number}  ${channel.name}', [
      MenuOption('Watch', _play),
      MenuOption(channel.favourite ? 'Remove from Favourites' : 'Add to Favourites', () {
        widget.repository.setFavourite(channel.id, !channel.favourite);
        setState(_load);
      }),
      MenuOption('Hide this channel', () {
        widget.repository.setHidden(channel.id, true);
        setState(_load);
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final preview = Rect.fromLTWH(
      screen.width - _margin - _previewSize.width,
      _top,
      _previewSize.width,
      _previewSize.height,
    );
    final playing = widget.tuner.state.value.phase == PlayerPhase.playing;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Everything opaque but the preview box, where the video plane shows.
          Positioned.fill(child: CustomPaint(painter: _HolePainter(playing ? preview : null))),
          Positioned.fromRect(rect: preview, child: _previewBox()),
          Padding(
            padding: const EdgeInsets.fromLTRB(_margin, _top, _margin, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: _previewSize.height,
                  child: Padding(
                    padding: EdgeInsets.only(right: _previewSize.width + 32),
                    child: _details(),
                  ),
                ),
                const SizedBox(height: 20),
                _filterBar(),
                const SizedBox(height: 12),
                Expanded(child: _grid()),
              ],
            ),
          ),
          if (_digits.isNotEmpty)
            Positioned(
              top: _top,
              left: _margin,
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

  Widget _previewBox() {
    final state = widget.tuner.state.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.tuner.player.view(),
          if (state.phase == PlayerPhase.opening) const Center(child: CircularProgressIndicator()),
          if (state.phase == PlayerPhase.failed)
            Center(
              child: Text(
                state.message ?? 'Could not play this channel',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: Tv.small),
              ),
            ),
        ],
      ),
    );
  }

  Widget _details() {
    final channel = _focused;
    if (channel == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          _all.isEmpty
              ? 'No channels yet. The channel list is fetched in the background; try again in a few minutes.'
              : _filter == 1
              ? 'No favourites yet: press Menu on a channel to add it.'
              : 'No channels here.',
          style: const TextStyle(fontSize: Tv.body, color: Colors.white70),
        ),
      );
    }
    final p = programmeAt(_guide[channel.id], _focus);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ChannelLogo(name: channel.name, path: channel.logoPath, size: 64),
            const SizedBox(width: 16),
            Flexible(
              child: Text(
                '${channel.number}  ${channel.name}',
                style: const TextStyle(fontSize: Tv.body, color: Colors.white70),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (channel.favourite)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Icon(Icons.star, color: Colors.white),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          p == null ? 'No guide information' : p.title,
          style: const TextStyle(fontSize: Tv.title, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (p != null) ...[
          const SizedBox(height: 6),
          Text(
            '${clock(p.start)} - ${clock(p.stop)}${p.subtitle == null ? '' : '   ${p.subtitle}'}',
            style: const TextStyle(fontSize: Tv.small, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (p.description != null) ...[
            const SizedBox(height: 10),
            Text(
              p.description!,
              style: const TextStyle(fontSize: Tv.small, color: Colors.white60),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ],
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        controller: _filterScroll,
        scrollDirection: Axis.horizontal,
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final active = i == _filter;
          final focused = active && _inFilterBar;
          final label = _filters[i];
          return Container(
            key: _filterKeys[i],
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: focused ? Tv.accent : (active ? Colors.white24 : Colors.white10),
              borderRadius: BorderRadius.circular(26),
              border: focused ? Border.all(color: Colors.white, width: 3) : null,
            ),
            child: Text(label[0].toUpperCase() + label.substring(1), style: const TextStyle(fontSize: Tv.small)),
          );
        },
      ),
    );
  }

  Widget _grid() {
    final visible = _visible;
    return LayoutBuilder(
      builder: (context, constraints) {
        final pxPerMinute = (constraints.maxWidth - _channelColumn) / _span.inMinutes;
        final windowEnd = _windowStart.add(_span);
        final nowX = _channelColumn + _now.difference(_windowStart).inSeconds / 60 * pxPerMinute;
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 40,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 4,
                        child: Text(
                          clock(_now),
                          style: const TextStyle(fontSize: Tv.small, fontWeight: FontWeight.w600),
                        ),
                      ),
                      for (var t = _windowStart; t.isBefore(windowEnd); t = t.add(slot))
                        Positioned(
                          left: _channelColumn + t.difference(_windowStart).inMinutes * pxPerMinute + 8,
                          top: 4,
                          child: Text(
                            clock(t),
                            style: const TextStyle(fontSize: Tv.small, color: Colors.white70),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _rows,
                    itemExtent: _rowHeight,
                    itemCount: visible.length,
                    itemBuilder: (_, i) =>
                        _gridRow(visible[i], i == _row && !_inFilterBar, pxPerMinute, windowEnd, constraints.maxWidth),
                  ),
                ),
              ],
            ),
            if (nowX >= _channelColumn && nowX <= constraints.maxWidth)
              Positioned(
                left: nowX - 1,
                top: 32,
                bottom: 0,
                child: Container(width: 3, color: const Color(0xFFE53935)),
              ),
          ],
        );
      },
    );
  }

  Widget _gridRow(ChannelEntry channel, bool focusedRow, double pxPerMinute, DateTime windowEnd, double width) {
    final programmes = (_guide[channel.id] ?? const <Programme>[])
        .where((p) => p.stop.isAfter(_windowStart) && p.start.isBefore(windowEnd))
        .toList();
    final focusedProgramme = focusedRow ? programmeAt(_guide[channel.id], _focus) : null;
    double x(DateTime t) {
      final clamped = t.isBefore(_windowStart) ? _windowStart : (t.isAfter(windowEnd) ? windowEnd : t);
      return _channelColumn + clamped.difference(_windowStart).inSeconds / 60 * pxPerMinute;
    }

    Widget cell(double left, double right, String text, {required bool focused, bool dim = false}) => Positioned(
      left: left + 2,
      width: (right - left - 4).clamp(0, double.infinity),
      top: 3,
      bottom: 3,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: focused ? Tv.accent : (dim ? Colors.white.withValues(alpha: 0.04) : Colors.white10),
          borderRadius: BorderRadius.circular(6),
          border: focused ? Border.all(color: Colors.white, width: 3) : null,
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: Tv.small, color: dim ? Colors.white38 : Colors.white),
        ),
      ),
    );

    final cells = <Widget>[
      for (final p in programmes) cell(x(p.start), x(p.stop), p.title, focused: identical(p, focusedProgramme)),
    ];
    if (programmes.isEmpty) {
      cells.add(cell(x(_windowStart), x(windowEnd), 'No information', focused: false, dim: true));
    }
    // An empty half hour where the focus is.
    if (focusedRow && focusedProgramme == null) {
      final start = floorToSlot(_focus);
      cells.add(cell(x(start), x(start.add(slot)), '', focused: true));
    }

    return Stack(
      children: [
        Positioned(
          left: 0,
          width: _channelColumn - 8,
          top: 3,
          bottom: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: focusedRow ? Colors.white24 : Colors.white10,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    '${channel.number}',
                    style: const TextStyle(fontSize: Tv.small, color: Colors.white70),
                  ),
                ),
                ChannelLogo(name: channel.name, path: channel.logoPath, size: 52),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: Tv.small),
                  ),
                ),
                if (widget.tuner.state.value.channel?.id == channel.id)
                  const Icon(Icons.play_arrow, size: 26, color: Colors.white70),
              ],
            ),
          ),
        ),
        ...cells,
      ],
    );
  }
}

/// Paints the screen's background everywhere except [hole].
class _HolePainter extends CustomPainter {
  const _HolePainter(this.hole);

  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (hole != null) path.addRRect(RRect.fromRectAndRadius(hole!, const Radius.circular(4)));
    canvas.drawPath(path, Paint()..color = _background);
  }

  @override
  bool shouldRepaint(_HolePainter old) => old.hole != hole;
}
