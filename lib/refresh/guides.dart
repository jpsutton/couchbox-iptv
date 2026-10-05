import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../data/database.dart';

/// Parses XMLTV programmes from [events] for the guide channel ids in [wanted]
/// (guide id to couchbox-iptv channel ids). Programmes outside
/// [from]..[until] are skipped. Streams the document, so a large guide is
/// never held in memory.
Future<List<Programme>> parseXmltv(
  Stream<String> xml,
  Map<String, List<String>> wanted, {
  required DateTime from,
  required DateTime until,
}) async {
  final programmes = <Programme>[];
  final nodes = xml
      .toXmlEvents()
      .normalizeEvents()
      .selectSubtreeEvents(
        (event) =>
            event.name == 'programme' &&
            wanted.containsKey(event.attributes.where((a) => a.name == 'channel').firstOrNull?.value),
      )
      .toXmlNodes();
  await for (final batch in nodes) {
    for (final node in batch) {
      if (node is! XmlElement) continue;
      final start = parseXmltvTime(node.getAttribute('start'));
      final stop = parseXmltvTime(node.getAttribute('stop'));
      final title = node.getElement('title')?.innerText.trim();
      if (start == null || stop == null || title == null || title.isEmpty) continue;
      if (stop.isBefore(from) || start.isAfter(until)) continue;
      String? text(String name) {
        final value = node.getElement(name)?.innerText.trim();
        return value == null || value.isEmpty ? null : value;
      }

      for (final channelId in wanted[node.getAttribute('channel')]!) {
        programmes.add(
          Programme(
            channelId: channelId,
            start: start,
            stop: stop,
            title: title,
            subtitle: text('sub-title'),
            description: text('desc'),
            category: text('category'),
          ),
        );
      }
    }
  }
  return programmes;
}

/// XMLTV's "20261004213000 +0000" (offset optional) as UTC.
DateTime? parseXmltvTime(String? value) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-])?(\d{2})?(\d{2})?').firstMatch(value ?? '');
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i) ?? '0');
  final local = DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
  if (m.group(7) == null) return local;
  final offset = Duration(hours: g(8), minutes: g(9));
  return m.group(7) == '+' ? local.subtract(offset) : local.add(offset);
}

/// The `<channel>` entries of an XMLTV document: id to display name and icon.
Future<Map<String, ({String name, String? icon})>> parseXmltvChannels(Stream<String> xml) async {
  final out = <String, ({String name, String? icon})>{};
  final nodes = xml.toXmlEvents().normalizeEvents().selectSubtreeEvents((e) => e.name == 'channel').toXmlNodes();
  await for (final batch in nodes) {
    for (final node in batch) {
      if (node is! XmlElement) continue;
      final id = node.getAttribute('id');
      final name = node.getElement('display-name')?.innerText.trim();
      if (id == null || name == null || name.isEmpty) continue;
      out[id] = (name: name, icon: node.getElement('icon')?.getAttribute('src'));
    }
  }
  return out;
}

/// A gzipped XMLTV file as text.
Stream<String> readGzippedXml(File file) => file.openRead().transform(gzip.decoder).transform(utf8.decoder);

/// i.mjh.nz's Pluto TV guide for [country] ("us"); Pluto channel ids, which
/// iptv-org's `jmp2.uk/plu-<id>` stream links carry.
Uri plutoGuideUrl(String country) => Uri.parse('https://i.mjh.nz/PlutoTV/${country.toLowerCase()}.xml.gz');
