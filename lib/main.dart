import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'site.dart';
import 'navigation.dart';
import 'spatial_data.dart';

Future<String?> _loadOptionalAsset(String name) async {
  try {
    return await rootBundle.loadString('assets/valmet/$name');
  } on FlutterError {
    return null;
  }
}

Future<SpatialAssetData?> _loadAssetData(
  Site site, [
  Future<SpatialAssetData?> Function()? loader,
]) async {
  try {
    if (loader != null) return await loader();
    final legacy = await _loadOptionalAsset('asset-data.json');
    if (legacy == null) return null;
    final hash = site.sourceSha256;
    if (hash != null) {
      final [associations, diagnostics] = await Future.wait([
        _loadOptionalAsset('associations.json'),
        _loadOptionalAsset('diagnostics.json'),
      ]);
      if (associations != null && diagnostics != null) {
        try {
          return SpatialAssetData.fromJson(
            legacy,
            associationsSource: associations,
            diagnosticsSource: diagnostics,
            sceneSourceSha256: hash,
          );
        } on FormatException {
          // Fall back to the workbook when private sidecars are invalid.
        } on TypeError {
          // Bad field types also invalidate the optional sidecars.
        }
      }
    }
    return SpatialAssetData.fromJson(legacy);
  } on FormatException {
    return null;
  }
}

void main() => runApp(const ValmetApp());

String? _workbookTag(SiteObject object, SpatialAssetData? data) =>
    object.geometryOnly
    ? null
    : data?.tagForObject(object.objectId, equipmentType: object.equipmentType);

String? _workbookCondition(SiteObject object, SpatialAssetData? data) =>
    object.geometryOnly
    ? null
    : data?.conditionForObject(
        object.objectId,
        equipmentType: object.equipmentType,
      );

class ValmetApp extends StatelessWidget {
  const ValmetApp({super.key, this.site});

  final Site? site;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ServicePath',
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
  late final _personSite = _loadPersonSite();
  bool _usePersonSite = true;
  static const _ar = MethodChannel('valmet/field');

  Future<Site?> _loadPersonSite() async {
    final source = await _loadOptionalAsset('person-site.json');
    if (source == null) return null;
    try {
      final site = Site.fromJson(source);
      final legacy = await _site;
      if (site.personNavigation != null &&
          site.floor != null &&
          site.sourceSha256 != null &&
          site.sourceSha256 == legacy.sourceSha256 &&
          site.width == legacy.width &&
          site.depth == legacy.depth &&
          site.cellSize == legacy.cellSize &&
          jsonEncode(site.originShift) == jsonEncode(legacy.originShift) &&
          jsonEncode(site.shRotation) == jsonEncode(legacy.shRotation)) {
        return site;
      }
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    return null;
  }

  Future<Site> _requestedSite(Map<Object?, Object?> request) async {
    if (widget.site case final site?) return site;
    if (request['personNavigation'] != true) return _site;
    return await _personSite ??
        (throw PlatformException(code: 'invalid_person_site'));
  }

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
      final site = await _requestedSite(request);
      final data = await _loadAssetData(site);
      final targetId = request['targetID'] as String;
      final object = site.objects
          .where((object) => object.objectId == targetId)
          .singleOrNull;
      final target = object == null || object.geometryOnly
          ? null
          : data?.forObject(targetId, equipmentType: object.equipmentType);
      return {
        'inspectionReport': target?.reportText,
        'inspectionSummary': target?.arrivalSummary,
        'telemetryChart': target?.telemetryChart,
        'hasWorkbook': data != null,
        'tags': {
          for (final object in site.objects)
            object.objectId: _workbookTag(object, data),
        },
        'conditions': {
          for (final object in site.objects)
            object.objectId: _workbookCondition(object, data),
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
    final site = await _requestedSite(request);
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
      appBar: AppBar(title: const Text('ServicePath')),
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
                  return FutureBuilder<Site?>(
                    future: _personSite,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final person = snapshot.data;
                      return Column(
                        children: [
                          if (person != null)
                            SwitchListTile(
                              title: const Text('Walking-person simulation'),
                              subtitle: const Text('Turn off for live AR'),
                              value: _usePersonSite,
                              onChanged: (value) =>
                                  setState(() => _usePersonSite = value),
                            ),
                          Expanded(
                            child: SiteSimulation(
                              key: ValueKey(_usePersonSite),
                              site: _usePersonSite ? person ?? site : site,
                              extractionBounds: {
                                for (final object
                                    in person?.objects ?? const <SiteObject>[])
                                  object.objectId: ?object.extractionBounds,
                              },
                              openNative: _openNative,
                            ),
                          ),
                        ],
                      );
                    },
                  );
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
    this.extractionBounds = const {},
  });

  final Site site;
  final Future<void> Function(String, [String?]) openNative;
  final Future<SpatialAssetData?> Function()? loadAssetData;
  final Map<String, Object> extractionBounds;

  @override
  State<SiteSimulation> createState() => _SiteSimulationState();
}

typedef _ServiceSelection = ({SiteObject target, Cell? start});

class _SiteSimulationState extends State<SiteSimulation> {
  static const _demoStart = (50, 80);
  static const _demoTargetId = 'boiler-room:far-circulation-pump';

  late final _assetData = _loadAssetData(widget.site, widget.loadAssetData);
  late final _devices = widget.site.objects
      .where((o) => o.service != null && !o.geometryOnly)
      .toList();
  late _ServiceSelection? _selection = _devices.isEmpty
      ? null
      : (target: _devices.first, start: null);
  SiteObject? get _target => _selection?.target;
  Cell get _start => _selection?.start ?? widget.site.start;
  late NavigationJourney? _journey = _createJourney();
  List<Cell> get _route => _journey?.route ?? [];
  bool _moved = false;
  bool _keyControls = false;
  bool _obstacleDemo = false;
  late final double _clearanceMetres =
      widget.site.personNavigation?.radiusMetres ??
      (widget.site.originShift == null ? 0.2 : 0.1);

  NavigationJourney? _createJourney() {
    final target = _target;
    return target == null
        ? null
        : NavigationJourney(
            site: widget.site,
            target: target,
            start: _start,
            moved: _moved,
            clearanceMetres: _clearanceMetres,
          );
  }

  Future<void> _openWorld({bool simulate = false}) async {
    final selection = _selection;
    final selectedTarget = selection?.target;
    final data = await _assetData;
    final diagnosis = selectedTarget == null
        ? null
        : data?.forObject(
            selectedTarget.objectId,
            equipmentType: selectedTarget.equipmentType,
          );
    if (!mounted || selection != _selection || (simulate && _route.isEmpty)) {
      return;
    }
    final site = widget.site;
    final person = site.personNavigation;
    final visible = site.visibleObjects(_moved).toList();
    final target = visible.indexWhere((object) => object == _target);
    List<int> pair(Cell cell) => [cell.$1, cell.$2];

    await widget.openNative(
      simulate ? 'openServiceSimulation' : 'openWorld',
      jsonEncode({
        'inspectionReport': diagnosis?.reportText,
        'inspectionSummary': diagnosis?.arrivalSummary,
        'telemetryChart': diagnosis?.telemetryChart,
        'hasWorkbook': data != null,
        'name': site.name,
        'sourceSha256': site.sourceSha256,
        'keyControls': !simulate && _keyControls,
        'obstacleDemo': !simulate && _obstacleDemo && _route.isNotEmpty,
        'serviceAccessDemo': selection?.start != null,
        'moved': _moved,
        'width': site.width,
        'depth': site.depth,
        'cellSize': site.cellSize,
        'originShift': site.originShift,
        'shRotation': site.shRotation,
        'start': pair(_start),
        'route': _route.map(pair).toList(),
        'clearanceMetres': _clearanceMetres,
        if (person != null) 'eyeHeightMetres': person.eyeHeightMetres,
        if (person != null)
          'walkingSpeedMetresPerSecond': person.speedMetresPerSecond,
        'arrivalRadiusMetres': person == null
            ? math.max(0.30, site.cellSize / 2)
            : site.cellSize / 2,
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
              'extractionBounds':
                  object.extractionBounds ??
                  widget.extractionBounds[object.objectId],
              'service': object.service == null ? null : pair(object.service!),
              'workbookTag': _workbookTag(object, data),
              'equipmentType': object.equipmentType,
              'syntheticCondition': _workbookCondition(object, data),
            },
        ],
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    final person = site.personNavigation;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(site.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        FutureBuilder<SpatialAssetData?>(
          future: _assetData,
          builder: (context, snapshot) =>
              DropdownButtonFormField<_ServiceSelection>(
                initialValue: _selection,
                decoration: const InputDecoration(labelText: 'Service target'),
                items: [
                  for (final device in _devices)
                    DropdownMenuItem(
                      value: (target: device, start: null),
                      child: Text(switch (_workbookTag(device, snapshot.data)) {
                        final String tag => '$tag · ${device.name}',
                        null => device.name,
                      }),
                    ),
                  for (final device in _devices)
                    if (device.objectId == _demoTargetId)
                      DropdownMenuItem(
                        value: (target: device, start: _demoStart),
                        child: const Text('Long-route demo · P-001 pump'),
                      ),
                ],
                onChanged: _devices.isEmpty
                    ? null
                    : (selection) => setState(() {
                        _selection = selection;
                        _journey = _createJourney();
                      }),
              ),
        ),
        if (person == null) ...[
          const SizedBox(height: 12),
          Text('Settings', style: Theme.of(context).textTheme.titleMedium),
        ],
        if (person == null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Forward and backward controls'),
            subtitle: const Text(
              'Use ↑/↓ to move. Turn by rotating the phone.',
            ),
            value: _keyControls,
            onChanged: (value) => setState(() => _keyControls = value),
          ),
        if (person == null && _target != null && _route.isNotEmpty)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Movable demo crate'),
            subtitle: const Text(
              'Try obstacle detection and rerouting in the model.',
            ),
            value: _obstacleDemo,
            onChanged: (value) => setState(() => _obstacleDemo = value),
          ),
        if (person == null)
          const Text(
            'Camera height 1.50 m · not a standing-person clearance check.',
          )
        else
          Text(
            'Model envelope ${(person.radiusMetres * 2).toStringAsFixed(2)} m wide · '
            '${person.bodyHeightMetres.toStringAsFixed(2)} m tall · '
            '${person.headMarginMetres.toStringAsFixed(2)} m overhead margin',
          ),
        if (!site.isWalkable(
          _start,
          moved: _moved,
          clearanceMetres: _clearanceMetres,
        ))
          Text(
            person == null
                ? 'Start position lacks virtual camera clearance.'
                : 'Start position lacks walking-person clearance.',
          ),
        if (person == null)
          FilledButton.icon(
            onPressed: _openWorld,
            icon: const Icon(Icons.directions_walk),
            label: const Text('Walk inside the 3D model'),
          ),
        if (_target != null)
          OutlinedButton.icon(
            onPressed: _route.isEmpty ? null : () => _openWorld(simulate: true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Simulate service visit'),
          ),
        if (person == null && site.objects.any((object) => object.movable))
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
      ],
    );
  }
}
