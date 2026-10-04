import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database.dart';
import 'keys.dart';
import 'options_menu.dart';
import 'player_screen.dart';
import 'repository.dart';
import 'tuner.dart';
import 'widgets.dart';

/// Every channel with what's on now and next. A filter bar on top: All,
/// Favourites, then the categories present. OK plays, Menu has options.
class ChannelListScreen extends StatefulWidget {
  const ChannelListScreen({super.key, required this.repository, required this.tuner});

  final Repository repository;
  final Tuner tuner;

  @override
  State<ChannelListScreen> createState() => _ChannelListScreenState();
}

class _ChannelListScreenState extends State<ChannelListScreen> {
  List<ChannelEntry> _all = [];
  Map<String, List<Programme>> _guide = {};
  List<String> _filters = ['All', 'Favourites'];
  int _filter = 0;
  int _row = 0;
  bool _inFilterBar = false;
  DateTime _now = DateTime.now();
  final _scroll = ScrollController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() => _now = DateTime.now()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeLastChannel());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _load() {
    _now = DateTime.now();
    _all = widget.repository.channels();
    _guide = widget.repository.programmes(_now.subtract(const Duration(hours: 1)), _now.add(const Duration(hours: 6)));
    final counts = <String, int>{};
    for (final c in _all) {
      for (final category in c.categories) {
        counts[category] = (counts[category] ?? 0) + 1;
      }
    }
    final categories = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    _filters = ['All', 'Favourites', ...categories];
    _filter = _filter.clamp(0, _filters.length - 1);
    _row = _row.clamp(0, (_visible.length - 1).clamp(0, 1 << 30));
  }

  List<ChannelEntry> get _visible => switch (_filter) {
    0 => _all,
    1 => _all.where((c) => c.favourite).toList(),
    _ => _all.where((c) => c.categories.contains(_filters[_filter])).toList(),
  };

  Future<void> _resumeLastChannel() async {
    final last = widget.repository.lastChannel;
    final index = _all.indexWhere((c) => c.id == last);
    if (index >= 0) await _play(_all, index);
  }

  Future<void> _play(List<ChannelEntry> channels, int index) async {
    await Navigator.of(context).push(
      // Opaque, so the list below isn't painted over the video plane.
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => Material(
          type: MaterialType.transparency,
          child: PlayerScreen(
            repository: widget.repository,
            tuner: widget.tuner,
            channels: channels,
            allChannels: _all,
            start: index,
          ),
        ),
      ),
    );
    if (!mounted) return;
    final current = widget.tuner.state.value.channel;
    setState(() {
      _load();
      // Come back to the channel that was playing.
      final at = _visible.indexWhere((c) => c.id == current?.id);
      if (at >= 0) _row = at;
    });
    _scrollTo(_row);
  }

  void _scrollTo(int row) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final top = row * Tv.rowHeight;
    var offset = _scroll.offset;
    if (top < offset) offset = top;
    if (top + Tv.rowHeight > offset + viewport) offset = top + Tv.rowHeight - viewport;
    _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!isPress(event)) return KeyEventResult.ignored;
    final visible = _visible;
    final key = remoteKey(event);
    if (_inFilterBar) {
      switch (key) {
        case RemoteKey.left:
          setState(() => _filter = (_filter - 1).clamp(0, _filters.length - 1));
        case RemoteKey.right:
          setState(() => _filter = (_filter + 1).clamp(0, _filters.length - 1));
        case RemoteKey.down || RemoteKey.ok:
          setState(() {
            _inFilterBar = false;
            _row = 0;
          });
          _scrollTo(0);
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
          setState(() => _row--);
          _scrollTo(_row);
        }
      case RemoteKey.down:
        if (_row < visible.length - 1) {
          setState(() => _row++);
          _scrollTo(_row);
        }
      case RemoteKey.channelUp:
        setState(() => _row = (_row - 8).clamp(0, (visible.length - 1).clamp(0, 1 << 30)));
        _scrollTo(_row);
      case RemoteKey.channelDown:
        setState(() => _row = (_row + 8).clamp(0, (visible.length - 1).clamp(0, 1 << 30)));
        _scrollTo(_row);
      case RemoteKey.ok:
        if (visible.isNotEmpty) _play(visible, _row);
      case RemoteKey.menu:
        if (visible.isNotEmpty) _menu(visible[_row]);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _menu(ChannelEntry channel) {
    showOptionsMenu(context, '${channel.number}  ${channel.name}', [
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
    final visible = _visible;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: const Color(0xFF0B0E12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(64, 40, 64, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Internet TV',
                    style: TextStyle(fontSize: Tv.title, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    clock(_now),
                    style: const TextStyle(fontSize: Tv.title, color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _filterBar(),
              const SizedBox(height: 16),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _all.isEmpty
                              ? 'No channels yet. The channel list is fetched in the background; try again in a few minutes.'
                              : _filter == 1
                              ? 'No favourites yet: press Menu on a channel to add it.'
                              : 'No channels here.',
                          style: const TextStyle(fontSize: Tv.body, color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: Tv.rowHeight,
                        itemCount: visible.length,
                        itemBuilder: (_, i) => _row_(visible[i], selected: !_inFilterBar && i == _row),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final active = i == _filter;
          final focused = active && _inFilterBar;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: focused ? Tv.accent : (active ? Colors.white24 : Colors.white10),
              borderRadius: BorderRadius.circular(28),
              border: focused ? Border.all(color: Colors.white, width: 3) : null,
            ),
            child: Text(_label(_filters[i]), style: const TextStyle(fontSize: Tv.small)),
          );
        },
      ),
    );
  }

  static String _label(String category) =>
      category.isEmpty ? category : category[0].toUpperCase() + category.substring(1);

  Widget _row_(ChannelEntry c, {required bool selected}) {
    final (:now, :next) = nowAndNext(_guide[c.id], _now);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: selected ? Tv.accent.withValues(alpha: 0.35) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 3),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '${c.number}',
              style: const TextStyle(fontSize: Tv.body, color: Colors.white70),
            ),
          ),
          ChannelLogo(name: c.name, path: c.logoPath),
          const SizedBox(width: 20),
          SizedBox(
            width: 420,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    c.name,
                    style: const TextStyle(fontSize: Tv.body),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (c.favourite) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.star, size: 28)),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  now?.title ?? '',
                  style: const TextStyle(fontSize: Tv.small),
                  overflow: TextOverflow.ellipsis,
                ),
                if (now != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: LinearProgressIndicator(value: progress(now, _now), minHeight: 4),
                  ),
                if (next != null)
                  Text(
                    '${clock(next.start)}  ${next.title}',
                    style: const TextStyle(fontSize: Tv.small, color: Colors.white54),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
