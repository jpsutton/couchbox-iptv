import 'dart:async';
import 'dart:convert';
import 'dart:io';

const userAgent = 'couchbox-iptv (+https://github.com/jpsutton/couchbox)';

/// A GET that reads at most [maxBytes] of the body, then stops. Follows
/// redirects. Throws [TimeoutException] past [timeout].
Future<({int status, List<int> body, Uri url})> fetchHead(
  HttpClient client,
  Uri url, {
  Map<String, String> headers = const {},
  int maxBytes = 256 * 1024,
  Duration timeout = const Duration(seconds: 10),
}) async {
  Future<({int status, List<int> body, Uri url})> go() async {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = <int>[];
    await for (final chunk in response) {
      body.addAll(chunk);
      if (body.length >= maxBytes) break;
    }
    final finalUrl = response.redirects.isEmpty ? url : url.resolveUri(response.redirects.last.location);
    return (status: response.statusCode, body: body, url: finalUrl);
  }

  return go().timeout(timeout);
}

/// Downloads [url] to [file], sending the ETag of the last download so an
/// unchanged file isn't fetched again. Returns the file.
Future<File> downloadCached(
  HttpClient client,
  Uri url,
  File file, {
  Duration timeout = const Duration(minutes: 5),
}) async {
  final etagFile = File('${file.path}.etag');
  final request = await client.getUrl(url);
  request.headers.set(HttpHeaders.userAgentHeader, userAgent);
  if (file.existsSync() && etagFile.existsSync()) {
    request.headers.set(HttpHeaders.ifNoneMatchHeader, etagFile.readAsStringSync());
  }
  final response = await request.close().timeout(timeout);
  if (response.statusCode == HttpStatus.notModified) {
    await response.drain<void>();
    return file;
  }
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}', uri: url);
  }
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.part');
  await response.pipe(tmp.openWrite()).timeout(timeout);
  tmp.renameSync(file.path);
  final etag = response.headers.value(HttpHeaders.etagHeader);
  if (etag == null) {
    if (etagFile.existsSync()) etagFile.deleteSync();
  } else {
    etagFile.writeAsStringSync(etag);
  }
  return file;
}

/// Reads a downloaded JSON list.
Future<List<Map<String, dynamic>>> readJsonList(File file) async =>
    (jsonDecode(await file.readAsString()) as List).cast<Map<String, dynamic>>();
