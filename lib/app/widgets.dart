import 'dart:io';

import 'package:flutter/material.dart';

import '../data/database.dart';

/// Sizes for a 1080p TV seen from 3 m.
class Tv {
  static const rowHeight = 104.0;
  static const title = 44.0;
  static const body = 30.0;
  static const small = 24.0;
  static const accent = Color(0xFF2E7DFF);
  static const panel = Color(0xE6101418);
}

/// A channel's logo, or its initials when there is none.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.name, this.path, this.size = 72});

  final String name;
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)),
      child: Text(
        name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join(),
        style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w600),
      ),
    );
    if (path == null) return initials;
    return SizedBox(
      width: size,
      height: size,
      child: Image.file(
        File(path!),
        fit: BoxFit.contain,
        cacheWidth: (size * 2).round(),
        errorBuilder: (_, _, _) => initials,
      ),
    );
  }
}

/// "21:30"
String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The programme on now and the one after, from a channel's time-ordered list.
({Programme? now, Programme? next}) nowAndNext(List<Programme>? programmes, DateTime at) {
  if (programmes == null) return (now: null, next: null);
  Programme? now;
  Programme? next;
  for (final p in programmes) {
    if (!p.start.isAfter(at) && p.stop.isAfter(at)) {
      now = p;
    } else if (p.start.isAfter(at)) {
      next = p;
      break;
    }
  }
  return (now: now, next: next);
}

/// How far into [p] we are, 0..1.
double progress(Programme p, DateTime at) {
  final total = p.stop.difference(p.start).inSeconds;
  if (total <= 0) return 0;
  return (at.difference(p.start).inSeconds / total).clamp(0.0, 1.0);
}
