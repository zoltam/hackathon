import 'dart:convert';
import 'dart:io';

import 'package:valmet_field_app/site.dart';

void main() {
  final site = Site.fromJson(File('assets/valmet/site.json').readAsStringSync());
  final target = site.objects.firstWhere((object) => object.service != null);
  final route = site.route(site.start, target.service!, clearanceMetres: 0.10);
  if (route.isEmpty) throw StateError('No service route at 0.10 m clearance');
  stdout.write(jsonEncode({
    'targetID': target.objectId,
    'route': route.map((cell) => [cell.$1, cell.$2]).toList(),
  }));
}
