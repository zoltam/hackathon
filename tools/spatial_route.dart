// Local JSON adapter: keep Site.route as the app and spatial viewer authority.
import 'dart:convert';
import 'dart:io';

import 'package:valmet_field_app/site.dart';

Future<void> main() async {
  Map<String, dynamic> response(String status, {String? error}) => {
    'status': status,
    'route': <List<int>>[],
    'distanceMetres': 0.0,
    'walkableFloor': <List<int>>[],
    'error': ?error,
  };
  try {
    final request = jsonDecode(await stdin.transform(utf8.decoder).join());
    if (request is! Map<String, dynamic> ||
        request['sitePath'] is! String ||
        request['targetID'] is! String ||
        request['start'] is! List ||
        (request['start'] as List).length != 2 ||
        (request['start'] as List).any((v) => v is! int)) {
      throw const FormatException(
        'Expected sitePath, targetID and integer start pair',
      );
    }
    final radius = request['clearanceMetres'] ?? .30;
    if (radius is! num || !radius.isFinite || radius < 0) {
      throw const FormatException('Clearance must be finite and nonnegative');
    }
    final site = Site.fromJson(
      File(request['sitePath'] as String).readAsStringSync(),
    );
    if (site.floor == null) {
      throw const FormatException('Observed floor is required');
    }
    final target = site.objects
        .where((o) => o.objectId == request['targetID'])
        .singleOrNull;
    if (target == null) throw const FormatException('Unknown targetID');
    if (target.service == null) {
      stdout.write(
        jsonEncode(
          response('unreachable', error: 'Target has no safe service approach'),
        ),
      );
      return;
    }
    final start = (request['start'][0] as int, request['start'][1] as int);
    final clearance = radius.toDouble();
    final floor = site.walkableCells(clearanceMetres: clearance).toSet();
    final route = site.route(
      start,
      target.service!,
      clearanceMetres: clearance,
    );
    final status = !floor.contains(start)
        ? 'blocked_start'
        : !floor.contains(target.service)
        ? 'blocked_target'
        : route.isEmpty
        ? 'unreachable'
        : route.length == 1
        ? 'arrived'
        : 'ready';
    stdout.write(
      jsonEncode({
        'status': status,
        'route': [
          for (final p in route) [p.$1, p.$2],
        ],
        'distanceMetres': site.metres(route),
        'walkableFloor': [
          for (final p in floor) [p.$1, p.$2],
        ],
      }),
    );
  } on FormatException catch (error) {
    stdout.write(jsonEncode(response('invalid_request', error: error.message)));
  } on FileSystemException {
    stdout.write(
      jsonEncode(
        response('invalid_request', error: 'Site file is unavailable'),
      ),
    );
  } catch (error) {
    stdout.write(jsonEncode(response('invalid_request', error: '$error')));
  }
}
