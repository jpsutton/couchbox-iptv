import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'm0/bench.dart';
import 'player/live_player.dart';
import 'player/media_kit_player.dart';
import 'player/native_mpv_player.dart';

/// M0: the player comparison. Plays assets/m0_streams.json on both backends.
///
///   couchbox-iptv           a list: Left/Right picks the backend, OK plays,
///                           Back stops, P toggles the small preview box
///   couchbox-iptv --bench   tunes every stream on each backend in turn,
///                           writes ~/.local/share/couchbox-iptv/m0-results.json,
///                           then quits
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final raw = jsonDecode(await rootBundle.loadString('assets/m0_streams.json')) as List;
  final streams = raw.map((e) => TestStream.fromJson(e as Map<String, dynamic>)).toList();
  runApp(M0App(streams: streams, bench: args.contains('--bench')));
}

class M0App extends StatelessWidget {
  const M0App({super.key, required this.streams, required this.bench});

  final List<TestStream> streams;
  final bool bench;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        // Transparent so the native video plane below the window shows.
        scaffoldBackgroundColor: Colors.transparent,
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 28)),
      ),
      home: M0Screen(streams: streams, bench: bench),
    );
  }
}

class M0Screen extends StatefulWidget {
  const M0Screen({super.key, required this.streams, required this.bench});

  final List<TestStream> streams;
  final bool bench;

  @override
  State<M0Screen> createState() => _M0ScreenState();
}

class _M0ScreenState extends State<M0Screen> {
  final _backends = <String, LivePlayer Function()>{'native': NativeMpvPlayer.new, 'media_kit': MediaKitPlayer.new};
  late String _backendName = _backends.keys.first;
  LivePlayer? _player;
  int _selected = 0;
  bool _playing = false;
  bool _preview = false;
  String _line = '';
  final _results = <BenchResult>[];
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.bench) WidgetsBinding.instance.addPostFrameCallback((_) => _runBench());
  }

  Future<LivePlayer> _usePlayer(String backend) async {
    if (_player != null && _player!.name == backend) return _player!;
    await _player?.dispose();
    final player = _backends[backend]!();
    await player.init();
    setState(() => _player = player);
    return player;
  }

  Future<void> _runBench() async {
    // Alternate the backends per stream, so both see the same network moment.
    for (final stream in widget.streams) {
      for (final backend in _backends.keys) {
        setState(() {
          _playing = true;
          _line = '$backend: ${stream.name}';
        });
        final player = await _usePlayer(backend);
        final result = await benchOne(player, stream);
        stdout.writeln('M0 $result');
        setState(() => _results.add(result));
        saveResults(_results);
      }
    }
    // The preview box: 15 s per backend on the first stream that tuned.
    final good = _results.firstWhere((r) => r.error == null, orElse: () => _results.first);
    final stream = widget.streams.firstWhere((s) => s.name == good.stream);
    for (final backend in _backends.keys) {
      setState(() {
        _preview = true;
        _line = 'Preview box, $backend: is the video inside the box?';
      });
      final player = await _usePlayer(backend);
      await player.open(stream.url, headers: stream.headers);
      await Future<void>.delayed(const Duration(seconds: 15));
      await player.stop();
    }
    stdout.writeln('M0 results: ${resultsFile().path}');
    await _player?.dispose();
    exit(0);
  }

  Future<void> _play() async {
    final stream = widget.streams[_selected];
    final player = await _usePlayer(_backendName);
    setState(() {
      _playing = true;
      _line = '$_backendName: ${stream.name}, tuning';
    });
    final clock = Stopwatch()..start();
    final sub = player.status.listen((s) async {
      if (s.phase == PlayerPhase.playing) {
        final hwdec = await player.property('hwdec-current');
        setState(() => _line = '$_backendName: ${stream.name}, ${clock.elapsedMilliseconds} ms, hwdec $hwdec');
      } else if (s.phase == PlayerPhase.failed) {
        setState(() => _line = '$_backendName: ${stream.name}, failed: ${s.error}');
      }
    });
    await player.open(stream.url, headers: stream.headers);
    Future<void>.delayed(const Duration(seconds: 25), sub.cancel);
  }

  Future<void> _stop() async {
    await _player?.stop();
    setState(() => _playing = false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_playing) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.backspace) {
        _stop();
      } else if (key == LogicalKeyboardKey.keyP) {
        setState(() => _preview = !_preview);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1) % widget.streams.length);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1 + widget.streams.length) % widget.streams.length);
    } else if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final names = _backends.keys.toList();
      setState(() => _backendName = names[(names.indexOf(_backendName) + 1) % names.length]);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      _play();
    } else if (key == LogicalKeyboardKey.keyP) {
      setState(() => _preview = !_preview);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _video() {
    final view = _player?.view() ?? const SizedBox.expand();
    if (!_preview) return Positioned.fill(child: view);
    return Positioned.fromRect(rect: _previewRect(MediaQuery.sizeOf(context)), child: view);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        body: Stack(
          children: [
            // Opaque everywhere except where the video is, so the native
            // plane only shows through its own box.
            if (!_playing) const Positioned.fill(child: ColoredBox(color: Colors.black)),
            if (_playing && _preview) const Positioned.fill(child: CustomPaint(painter: _PreviewHolePainter())),
            if (_playing) _video(),
            if (!_playing) _list(),
            Positioned(left: 48, bottom: 32, right: 48, child: _status()),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(96, 64, 96, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('M0 player test, backend: $_backendName (Left/Right to change)', style: const TextStyle(fontSize: 36)),
          const SizedBox(height: 24),
          for (var i = 0; i < widget.streams.length; i++)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: i == _selected ? Colors.blue.shade700 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(widget.streams[i].name),
            ),
        ],
      ),
    );
  }

  Widget _status() {
    final last = _results.isEmpty ? '' : '\nlast: ${_results.last}';
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text('$_line$last', style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}

/// The preview box: 640x360 at the top right.
Rect _previewRect(Size screen) => Rect.fromLTWH(screen.width - 64 - 640, 64, 640, 360);

/// Black everywhere but the preview box, which stays transparent so the
/// native video plane below the window shows through it.
class _PreviewHolePainter extends CustomPainter {
  const _PreviewHolePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(_previewRect(size));
    canvas.drawPath(path, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
