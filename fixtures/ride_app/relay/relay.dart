import 'dart:convert';
import 'dart:io';

/// Keeps the driver's last position so a rider app on another device can follow it: POST /driver stores it, GET /driver returns it.
Future<void> main(List<String> args) async {
  final port = int.tryParse(args.firstOrNull ?? '') ?? 8790;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  Map<String, Object?>? driver;
  stdout.writeln('ride relay on :$port');
  await for (final req in server) {
    if (req.uri.path != '/driver') {
      req.response.statusCode = HttpStatus.notFound;
    } else if (req.method == 'POST') {
      driver = (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, Object?>();
      req.response.statusCode = HttpStatus.noContent;
    } else if (req.method == 'DELETE') {
      driver = null;
      req.response.statusCode = HttpStatus.noContent;
    } else if (driver == null) {
      req.response.statusCode = HttpStatus.noContent;
    } else {
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(driver));
    }
    await req.response.close();
  }
}
