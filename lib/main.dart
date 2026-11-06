import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import 'site.dart';
import 'asset_data.dart';
import 'navigation.dart';
import 'inspection_details.dart';

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
                        'Equipment Room scan is missing. Prepare the local PLY assets before building.',
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
    this.loadAssetData,
  });

  final Site site;
  final Future<void> Function(String, [String?]) openNative;
  final Future<AssetData?> Function()? loadAssetData;

  @override
  State<SiteSimulation> createState() => _SiteSimulationState();
}

class _SiteSimulationState extends State<SiteSimulation>
    with SingleTickerProviderStateMixin {
  late final _devices = widget.site.objects
      .where((o) => o.service != null)
      .toList();
  late SiteObject? _target = _devices.firstOrNull;
  late NavigationJourney? _journey = _createJourney();
  List<Cell> get _route => _journey?.route ?? [];
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  bool _moved = false;
  double _clearanceMetres = 0.2;

  NavigationJourney? _createJourney() {
    final target = _target;
    return target == null
        ? null
        : NavigationJourney(
            site: widget.site,
            target: target,
            moved: _moved,
            clearanceMetres: _clearanceMetres,
          );
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() {
        _journey?.advance(elapsed - _lastTick);
        _lastTick = elapsed;
      });
      if (_journey?.status != JourneyStatus.playing) _ticker.stop();
    });
  }

  void _resetJourney() {
    _ticker.stop();
    _journey = _createJourney();
  }

  void _togglePlayback() {
    setState(() {
      if (_journey?.status == JourneyStatus.playing) {
        _journey?.pause();
        _ticker.stop();
      } else {
        _journey?.play();
        if (_journey?.status == JourneyStatus.playing) {
          _lastTick = Duration.zero;
          _ticker.start();
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _openWorld() async {
    setState(() {
      _journey?.pause();
      _ticker.stop();
    });
    final selectedTarget = _target;
    String? report;
    try {
      final data = widget.loadAssetData != null
          ? await widget.loadAssetData!()
          : AssetData.fromJson(
              await rootBundle.loadString('assets/valmet/asset-data.json'),
            );
      report = data?.forObject(selectedTarget?.objectId ?? '')?.reportText;
    } on FlutterError {
      // Navigation remains available when local workbook data is absent.
    } on FormatException {
      // The viewer will explicitly report unavailable inspection evidence.
    }
    if (!mounted || selectedTarget != _target) return;
    final site = widget.site;
    final visible = site.visibleObjects(_moved).toList();
    final target = visible.indexWhere((object) => object == _target);
    List<int> pair(Cell cell) => [cell.$1, cell.$2];

    await widget.openNative(
      'openWorld',
      jsonEncode({
        'inspectionReport': report,
        'name': site.name,
        'width': site.width,
        'depth': site.depth,
        'cellSize': site.cellSize,
        'start': pair(site.start),
        'route': _route.map(pair).toList(),
        'clearanceMetres': _journey?.clearanceMetres,
        'arrivalRadiusMetres': site.cellSize / 2,
        'floor': site.floor?.map(pair).toList(),
        'target': target < 0 ? null : target,
        'objects': [
          for (final object in visible)
            {
              'object_id': object.objectId,
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
                  _resetJourney();
                }),
        ),
        DropdownButtonFormField<double>(
          initialValue: _clearanceMetres,
          decoration: const InputDecoration(labelText: 'Virtual avatar radius'),
          items: const [
            DropdownMenuItem(
              value: 0.1,
              child: Text('0.10 m · virtual camera'),
            ),
            DropdownMenuItem(value: 0.2, child: Text('0.20 m · avatar')),
            DropdownMenuItem(value: 0.3, child: Text('0.30 m · avatar')),
          ],
          onChanged: (radius) {
            if (radius == null) return;
            setState(() {
              _clearanceMetres = radius;
              _resetJourney();
            });
          },
        ),
        FilledButton.icon(
          onPressed: _route.isEmpty ? null : _openWorld,
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
              _resetJourney();
            }),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: AspectRatio(
            aspectRatio: 1.28,
            child: CustomPaint(
              painter: SitePainter(
                site,
                _target,
                _route,
                _moved,
                position: _journey?.position,
              ),
            ),
          ),
        ),
        Text(
          _route.isEmpty
              ? 'No route with ${_clearanceMetres.toStringAsFixed(2)} m clearance to this device.'
              : '${site.metres(_route).toStringAsFixed(1)} m · route with ${_clearanceMetres.toStringAsFixed(2)} m clearance',
        ),
        const Text('Automatic route preview · 0.7 m/s'),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    _journey == null ||
                        _route.isEmpty ||
                        _journey?.status == JourneyStatus.arrived
                    ? null
                    : _togglePlayback,
                icon: Icon(
                  _journey?.status == JourneyStatus.playing
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                label: Text(
                  _journey?.status == JourneyStatus.playing
                      ? 'Pause preview'
                      : 'Play route preview',
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(_resetJourney),
              child: const Text('Reset'),
            ),
          ],
        ),
        Text(
          _journey?.status == JourneyStatus.arrived
              ? 'At service position · target recognition is checked separately.'
              : '${(_journey?.remainingMetres ?? 0).toStringAsFixed(1)} m remaining',
        ),
        if (_target case final target?)
          InspectionDetails(
            objectId: target.objectId,
            arrived: _journey?.status == JourneyStatus.arrived,
          ),
      ],
    );
  }
}

class SitePainter extends CustomPainter {
  SitePainter(this.site, this.target, this.route, this.moved, {this.position});

  final Site site;
  final SiteObject? target;
  final List<Cell> route;
  final bool moved;
  final Point<double>? position;

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

    final startX = position == null
        ? site.start.$1 + 0.5
        : position!.x / site.cellSize;
    final startZ = position == null
        ? site.start.$2 + 0.5
        : position!.y / site.cellSize;
    canvas.drawCircle(
      point(startX, startZ),
      5,
      Paint()..color = const Color(0xff173751),
    );
  }

  @override
  bool shouldRepaint(covariant SitePainter oldDelegate) =>
      site != oldDelegate.site ||
      target != oldDelegate.target ||
      route != oldDelegate.route ||
      moved != oldDelegate.moved ||
      position != oldDelegate.position;
}
