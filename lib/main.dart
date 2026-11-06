import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'site.dart';
import 'asset_data.dart';
import 'inspection_details.dart';
import 'navigation.dart';

Future<AssetData?> _loadAssetData([
  Future<AssetData?> Function()? loader,
]) async {
  try {
    if (loader != null) return await loader();
    return AssetData.fromJson(
      await rootBundle.loadString('assets/valmet/asset-data.json'),
    );
  } on FlutterError {
    return null;
  } on FormatException {
    return null;
  }
}

void main() => runApp(const ValmetApp());

String? _workbookTag(SiteObject object, AssetData? data) =>
    data?.tagForObject(object.objectId, equipmentType: object.equipmentType);

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

  @override
  void initState() {
    super.initState();
    _ar.setMethodCallHandler(_handleNativeCall);
  }

  @override
  void dispose() {
    _ar.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method == 'serviceJourneyEvidence') {
      final request = call.arguments as Map<Object?, Object?>;
      final data = await _loadAssetData();
      final site = widget.site ?? await _site;
      final targetId = request['targetID'] as String;
      final object = site.objects
          .where((object) => object.objectId == targetId)
          .singleOrNull;
      final target = object == null
          ? null
          : data?.forObject(targetId, equipmentType: object.equipmentType);
      return {
        'inspectionReport': target?.reportText,
        'inspectionSummary': target?.arrivalSummary,
        'hasWorkbook': data != null,
        'tags': {
          for (final object in site.objects)
            object.objectId: _workbookTag(object, data),
        },
        'conditions': {
          for (final object in site.objects)
            object.objectId: data?.conditionForObject(
              object.objectId,
              equipmentType: object.equipmentType,
            ),
        },
      };
    }
    if (call.method != 'replanServiceRoute') {
      throw MissingPluginException();
    }
    final request = call.arguments as Map<Object?, Object?>;
    Cell readCell(Object? raw) {
      final values = raw as List;
      return (values[0] as int, values[1] as int);
    }

    List<int> pair(Cell cell) => [cell.$1, cell.$2];
    final site = widget.site ?? await _site;
    final from = readCell(request['from']);
    final to = readCell(request['to']);
    final blocked = (request['blocked'] as List).map(readCell).toSet();
    final clearance = (request['clearanceMetres'] as num).toDouble();
    final moved = request['moved'] == true;
    return {
      'route': site
          .route(
            from,
            to,
            moved: moved,
            clearanceMetres: clearance,
            additionalBlocked: blocked,
          )
          .map(pair)
          .toList(),
      'walkableFloor': site
          .walkableCells(
            moved: moved,
            clearanceMetres: clearance,
            additionalBlocked: blocked,
          )
          .map(pair)
          .toList(),
    };
  }

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

class _SiteSimulationState extends State<SiteSimulation> {
  late final _assetData = _loadAssetData(widget.loadAssetData);
  late final _devices = widget.site.objects
      .where((o) => o.service != null)
      .toList();
  late SiteObject? _target = _devices.firstOrNull;
  late NavigationJourney? _journey = _createJourney();
  List<Cell> get _route => _journey?.route ?? [];
  bool _moved = false;
  bool _keyControls = false;
  bool _obstacleDemo = false;
  late double _clearanceMetres = widget.site.originShift == null ? 0.2 : 0.1;

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

  Future<void> _openWorld() async {
    final selectedTarget = _target;
    final data = await _assetData;
    final diagnosis = selectedTarget == null
        ? null
        : data?.forObject(
            selectedTarget.objectId,
            equipmentType: selectedTarget.equipmentType,
          );
    if (!mounted || selectedTarget != _target) return;
    final site = widget.site;
    final visible = site.visibleObjects(_moved).toList();
    final target = visible.indexWhere((object) => object == _target);
    List<int> pair(Cell cell) => [cell.$1, cell.$2];

    await widget.openNative(
      'openWorld',
      jsonEncode({
        'inspectionReport': diagnosis?.reportText,
        'inspectionSummary': diagnosis?.arrivalSummary,
        'hasWorkbook': data != null,
        'name': site.name,
        'keyControls': _keyControls,
        'obstacleDemo': _obstacleDemo && _route.isNotEmpty,
        'moved': _moved,
        'width': site.width,
        'depth': site.depth,
        'cellSize': site.cellSize,
        'originShift': site.originShift,
        'shRotation': site.shRotation,
        'start': pair(site.start),
        'route': _route.map(pair).toList(),
        'clearanceMetres': _clearanceMetres,
        'arrivalRadiusMetres': math.max(0.30, site.cellSize / 2),
        'floor': site.floor?.map(pair).toList(),
        'walkableFloor': site
            .walkableCells(moved: _moved, clearanceMetres: _clearanceMetres)
            .map(pair)
            .toList(),
        'target': target < 0 ? null : target,
        'objects': [
          for (final object in visible)
            {
              'object_id': object.objectId,
              'name': object.name,
              'objectId': object.objectId,
              'x': object.x,
              'z': object.z,
              'width': object.width,
              'depth': object.depth,
              'height': object.height,
              'cells': object.cells?.map(pair).toList(),
              'bounds': object.bounds,
              'service': object.service == null ? null : pair(object.service!),
              'workbookTag': _workbookTag(object, data),
              'syntheticCondition': data?.conditionForObject(
                object.objectId,
                equipmentType: object.equipmentType,
              ),
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
        FutureBuilder<AssetData?>(
          future: _assetData,
          builder: (context, snapshot) => DropdownButtonFormField<SiteObject>(
            initialValue: _target,
            decoration: const InputDecoration(labelText: 'Service target'),
            items: [
              for (final device in _devices)
                DropdownMenuItem(
                  value: device,
                  child: Text(switch (_workbookTag(device, snapshot.data)) {
                    final String tag => '$tag · ${device.name}',
                    null => device.name,
                  }),
                ),
            ],
            onChanged: _devices.isEmpty
                ? null
                : (target) => setState(() {
                    _target = target;
                    _journey = _createJourney();
                  }),
          ),
        ),
        const SizedBox(height: 12),
        Text('Settings', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Forward and backward controls'),
          subtitle: const Text('Use ↑/↓ to move. Turn by rotating the phone.'),
          value: _keyControls,
          onChanged: (value) => setState(() => _keyControls = value),
        ),
        if (_target != null && _route.isNotEmpty)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Movable demo crate'),
            subtitle: const Text(
              'Try obstacle detection and rerouting in the model.',
            ),
            value: _obstacleDemo,
            onChanged: (value) => setState(() => _obstacleDemo = value),
          ),
        DropdownButtonFormField<double>(
          initialValue: _clearanceMetres,
          decoration: const InputDecoration(labelText: 'Virtual camera radius'),
          items: const [
            DropdownMenuItem(
              value: 0.1,
              child: Text('0.10 m · virtual camera'),
            ),
            DropdownMenuItem(value: 0.2, child: Text('0.20 m · camera')),
            DropdownMenuItem(value: 0.3, child: Text('0.30 m · camera')),
          ],
          onChanged: (radius) {
            if (radius == null) return;
            setState(() {
              _clearanceMetres = radius;
              _journey = _createJourney();
            });
          },
        ),
        const Text(
          'Camera height 1.50 m · not a standing-person clearance check.',
        ),
        if (!site.isWalkable(
          site.start,
          moved: _moved,
          clearanceMetres: _clearanceMetres,
        ))
          const Text(
            'Start position lacks the selected clearance. Reduce the radius to move from this start.',
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
              _journey = _createJourney();
            }),
          ),
        Text(
          _route.isEmpty
              ? 'No route with ${_clearanceMetres.toStringAsFixed(2)} m clearance to this device.'
              : '${site.metres(_route).toStringAsFixed(1)} m · route with ${_clearanceMetres.toStringAsFixed(2)} m clearance',
        ),
        if (_target case final target?)
          InspectionDetails(
            objectId: target.objectId,
            equipmentType: target.equipmentType,
            arrived: _journey?.status == JourneyStatus.arrived,
          ),
      ],
    );
  }
}
