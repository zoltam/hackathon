import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'site.dart';

void main() => runApp(const ValmetApp());

class ValmetApp extends StatelessWidget {
  const ValmetApp({super.key, this.site});

  final Site? site;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Valmet Field App',
      theme: ThemeData(colorSchemeSeed: const Color(0xff006755)),
      home: FieldScreen(site: site),
    );
  }
}

class FieldScreen extends StatefulWidget {
  const FieldScreen({super.key, this.site});

  final Site? site;

  @override
  State<FieldScreen> createState() => _FieldScreenState();
}

class _FieldScreenState extends State<FieldScreen> {
  late final _site = rootBundle
      .loadString('assets/valmet/site.json')
      .then(Site.fromJson);
  static const _ar = MethodChannel('valmet/field');

  Future<void> _openNative(String method, [String? data]) async {
    try {
      await _ar.invokeMethod<void>(method, data);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'AR could not start.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    return Scaffold(
      appBar: AppBar(title: const Text('Valmet Field App')),
      body: SafeArea(
        child: site != null
            ? SiteSimulation(site: site, openNative: _openNative)
            : FutureBuilder<Site>(
                future: _site,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text(
                        'Industrial Boiler Room scan is missing. Prepare the Valmet PLY before building.',
                      ),
                    );
                  }
                  final site = snapshot.data;
                  if (site == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return SiteSimulation(site: site, openNative: _openNative);
                },
              ),
      ),
    );
  }
}

class SiteSimulation extends StatefulWidget {
  const SiteSimulation({
    super.key,
    required this.site,
    required this.openNative,
  });

  final Site site;
  final Future<void> Function(String, [String?]) openNative;

  @override
  State<SiteSimulation> createState() => _SiteSimulationState();
}

class _SiteSimulationState extends State<SiteSimulation> {
  late final _devices = widget.site.objects
      .where((o) => o.service != null)
      .toList();
  late SiteObject? _target = _devices.firstOrNull;
  late List<Cell> _route = _findRoute();
  bool _moved = false;

  List<Cell> _findRoute() {
    final destination = _target?.service;
    return destination == null
        ? []
        : widget.site.route(widget.site.start, destination, moved: _moved);
  }

  void _openWorld() {
    final site = widget.site;
    final visible = site.visibleObjects(_moved).toList();
    final target = visible.indexWhere((object) => object == _target);
    List<int> pair(Cell cell) => [cell.$1, cell.$2];

    widget.openNative(
      'openWorld',
      jsonEncode({
        'name': site.name,
        'width': site.width,
        'depth': site.depth,
        'cellSize': site.cellSize,
        'start': pair(site.start),
        'route': _route.map(pair).toList(),
        'floor': site.floor?.map(pair).toList(),
        'target': target < 0 ? null : target,
        'objects': [
          for (final object in visible)
            {
              'name': object.name,
              'x': object.x,
              'z': object.z,
              'width': object.width,
              'depth': object.depth,
              'height': object.height,
              'cells': object.cells?.map(pair).toList(),
            },
        ],
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(site.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<SiteObject>(
          initialValue: _target,
          decoration: const InputDecoration(labelText: 'Service target'),
          items: [
            for (final device in _devices)
              DropdownMenuItem(value: device, child: Text(device.name)),
          ],
          onChanged: _devices.isEmpty
              ? null
              : (target) => setState(() {
                  _target = target;
                  _route = _findRoute();
                }),
        ),
        FilledButton.icon(
          onPressed: _openWorld,
          icon: const Icon(Icons.directions_walk),
          label: const Text('Walk inside the 3D model'),
        ),
        if (site.objects.any((object) => object.movable))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Move pallet out of the aisle'),
            value: _moved,
            onChanged: (value) => setState(() {
              _moved = value;
              _route = _findRoute();
            }),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: AspectRatio(
            aspectRatio: 1.28,
            child: CustomPaint(
              painter: SitePainter(site, _target, _route, _moved),
            ),
          ),
        ),
        Text(
          _route.isEmpty
              ? 'No walkable route to this device.'
              : '${site.metres(_route).toStringAsFixed(1)} m · shortest walkable grid route',
        ),
      ],
    );
  }
}

class SitePainter extends CustomPainter {
  SitePainter(this.site, this.target, this.route, this.moved);

  final Site site;
  final SiteObject? target;
  final List<Cell> route;
  final bool moved;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = min(
      size.width / (site.width + site.depth + 2),
      size.height / (0.47 * (site.width + site.depth) + 7),
    );
    final origin = Offset(
      (size.width - unit * (site.width + site.depth)) / 2 + unit * site.depth,
      size.height / 2 - unit * (site.width + site.depth) * 0.18,
    );
    Offset point(num x, num z, [num y = 0]) =>
        origin +
        Offset((x - z) * unit, (0.47 * (x + z) - y / site.cellSize) * unit);

    void polygon(List<Offset> points, Color color) {
      canvas.drawPath(Path()..addPolygon(points, true), Paint()..color = color);
    }

    const floorColor = Color(0xffdce5e2);
    polygon([
      point(0, 0),
      point(site.width, 0),
      point(site.width, site.depth),
      point(0, site.depth),
    ], site.floor == null ? floorColor : const Color(0xffa7b4b1));
    for (final (x, z) in site.floor ?? const <Cell>{}) {
      polygon([
        point(x, z),
        point(x + 1, z),
        point(x + 1, z + 1),
        point(x, z + 1),
      ], floorColor);
    }
    final grid = Paint()..color = const Color(0x22505858);
    for (var x = 0; x <= site.width; x++) {
      canvas.drawLine(point(x, 0), point(x, site.depth), grid);
    }
    for (var z = 0; z <= site.depth; z++) {
      canvas.drawLine(point(0, z), point(site.width, z), grid);
    }
    final line = Paint()
      ..color = const Color(0xff007558)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    for (var index = 1; index < route.length; index++) {
      final (x, z) = route[index - 1];
      final (nextX, nextZ) = route[index];
      canvas.drawLine(
        point(x + 0.5, z + 0.5),
        point(nextX + 0.5, nextZ + 0.5),
        line,
      );
    }

    final blocks = [
      for (final object in site.visibleObjects(moved))
        if (object.cells case final cells?)
          for (final (x, z) in cells) (object, x, z, x + 1, z + 1)
        else
          (
            object,
            object.x,
            object.z,
            object.x + object.width,
            object.z + object.depth,
          ),
    ]..sort((a, b) => (a.$4 + a.$5).compareTo(b.$4 + b.$5));
    for (final (object, x, z, right, front) in blocks) {
      final h = object.height;
      final color = object == target
          ? const Color(0xffdf7a20)
          : object.service != null
          ? const Color(0xff4c849d)
          : const Color(0xff758883);
      polygon([
        point(right, z),
        point(right, front),
        point(right, front, h),
        point(right, z, h),
      ], Color.lerp(color, Colors.black, 0.25)!);
      polygon([
        point(x, front),
        point(right, front),
        point(right, front, h),
        point(x, front, h),
      ], Color.lerp(color, Colors.black, 0.40)!);
      polygon([
        point(x, z, h),
        point(right, z, h),
        point(right, front, h),
        point(x, front, h),
      ], color);
    }
    if (target case final device?) {
      final center = point(
        device.x + device.width / 2,
        device.z + device.depth / 2,
        device.height,
      );
      canvas.drawCircle(
        center,
        9,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    final (startX, startZ) = site.start;
    canvas.drawCircle(
      point(startX + 0.5, startZ + 0.5),
      5,
      Paint()..color = const Color(0xff173751),
    );
  }

  @override
  bool shouldRepaint(covariant SitePainter oldDelegate) =>
      site != oldDelegate.site ||
      target != oldDelegate.target ||
      route != oldDelegate.route ||
      moved != oldDelegate.moved;
}
