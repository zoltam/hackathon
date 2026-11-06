import 'dart:convert';
import 'dart:io';

import 'package:valmet_field_app/site.dart';

void main(List<String> args) {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart tools/verify_service_route.dart [object-id]',
    );
  }
  final site = Site.fromJson(
    File('assets/valmet/site.json').readAsStringSync(),
  );
  final target = site.objects.firstWhere(
    (object) =>
        object.service != null &&
        (args.isEmpty || object.objectId == args.single),
    orElse: () => throw StateError('No matching service target'),
  );
  final route = site.route(site.start, target.service!, clearanceMetres: 0.10);
  if (route.isEmpty) throw StateError('No service route at 0.10 m clearance');
  stdout.write(
    jsonEncode({
      'targetID': target.objectId,
      'route': route.map((cell) => [cell.$1, cell.$2]).toList(),
    }),
  );
}
