import 'package:flutter/material.dart';

import 'app/channel_list_screen.dart';
import 'app/repository.dart';
import 'app/tuner.dart';
import 'data/database.dart';
import 'paths.dart';
import 'player/native_mpv_player.dart';
import 'settings.dart';

/// couchbox-iptv: the free internet channels iptv-org lists, for a TV remote.
/// The channel list and guide come from iptv.db, which couchbox-iptv-refresh
/// fills in the background.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repository = Repository(IptvDatabase.open(Paths.database));
  final tuner = Tuner(NativeMpvPlayer(), repository);
  await tuner.configure(Settings.load());
  runApp(IptvApp(repository: repository, tuner: tuner));
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key, required this.repository, required this.tuner});

  final Repository repository;
  final Tuner tuner;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Internet TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7DFF), brightness: Brightness.dark),
        // Transparent so the native video plane below the window shows; each
        // screen paints its own background.
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: Material(
        type: MaterialType.transparency,
        child: ChannelListScreen(repository: repository, tuner: tuner),
      ),
    );
  }
}
