import 'dart:convert';

import 'asset_data.dart';

/// Optional backend exports for the existing app. No native payload changes.
class SpatialDiagnosis {
  const SpatialDiagnosis({
    required this.tag,
    required this.condition,
    required this.arrivalSummary,
    required this.reportText,
    required this.engine,
    this.motorCurrentSamples = const [],
  });

  final String tag, condition, arrivalSummary, reportText, engine;
  final List<double> motorCurrentSamples;
}

class SpatialAssetData {
  SpatialAssetData.fromJson(
    String legacySource, {
    String? associationsSource,
    String? diagnosticsSource,
    String? sceneSourceSha256,
  }) : _legacy = AssetData.fromJson(legacySource) {
    if (associationsSource == null && diagnosticsSource == null) return;
    if (associationsSource == null || diagnosticsSource == null) {
      throw const FormatException(
        'Spatial associations and reports must be loaded together',
      );
    }
    final legacy = _map(jsonDecode(legacySource));
    final mappings = _map(legacy['mappings']);
    final associations = _map(jsonDecode(associationsSource));
    final diagnostics = _map(jsonDecode(diagnosticsSource));
    for (final sidecar in [associations, diagnostics]) {
      if (sidecar['schemaVersion'] != 1 ||
          sidecar['sourceSha256'] != legacy['sourceSha256'] ||
          (sceneSourceSha256 != null &&
              sidecar['sceneSourceSha256'] != sceneSourceSha256)) {
        throw const FormatException(
          'Spatial export source or version mismatch',
        );
      }
    }
    if (associations['sceneSourceSha256'] != diagnostics['sceneSourceSha256']) {
      throw const FormatException('Spatial sidecars describe different scenes');
    }
    if (associations['synthetic'] != true ||
        associations['associations'] is! List) {
      throw const FormatException(
        'Spatial associations must disclose synthetic identities',
      );
    }
    final reports = _map(diagnostics['reports']);
    final assets = {
      for (final value in _map(legacy['tables'])['Asset_Master'] as List)
        _map(value)['asset_id']: _map(value),
    };
    final allowedReferences = <String>{
      for (final rows in _map(legacy['tables']).values)
        if (rows is List)
          for (final value in rows)
            if (_map(value)['_source'] is String)
              _map(value)['_source'] as String,
    };
    for (final value in associations['associations'] as List) {
      final association = _map(value);
      final id = association['sceneObjectId'];
      if (id is! String ||
          id.isEmpty ||
          _reports.containsKey(id) ||
          association['synthetic'] != true) {
        throw const FormatException('Invalid or duplicate spatial association');
      }
      final report = _map(reports[id]);
      final sceneType = association['sceneType'];
      if (_legacy.hasReviewedMappings &&
          (association['associationKind'] != 'synthetic_explicit' ||
              !mappings.containsKey(id) ||
              mappings[id] != association['workbookAssetId'] ||
              sceneType is! String ||
              _legacy.tagForObject(id, equipmentType: sceneType) !=
                  report['tag'])) {
        throw const FormatException(
          'Spatial association differs from reviewed mapping',
        );
      }
      if (report['sceneObjectId'] != id ||
          report['workbookAssetId'] != association['workbookAssetId'] ||
          report['sourceSha256'] != legacy['sourceSha256'] ||
          report['synthetic'] != true) {
        throw const FormatException('Spatial report identity mismatch');
      }
      if (assets[association['workbookAssetId']]?['tag'] != report['tag'] ||
          !{'deterministic', 'ollama'}.contains(report['engine']) ||
          report['citations'] is! List) {
        throw const FormatException(
          'Unknown workbook identity or report engine',
        );
      }
      final citations = <String>{};
      for (final value in report['citations'] as List) {
        final reference = _map(value)['reference'];
        if (reference is! String || !allowedReferences.contains(reference)) {
          throw const FormatException('Unknown workbook citation');
        }
        citations.add(reference);
      }
      if (report['engine'] == 'ollama' &&
          (report['modelStatus'] != 'validated' ||
              report['llmSummary'] is! String ||
              report['llmReferences'] is! List ||
              (report['llmReferences'] as List).isEmpty ||
              (report['llmReferences'] as List).any(
                (r) => !citations.contains(r),
              ))) {
        throw const FormatException('Invalid local model explanation');
      }
      for (final key in [
        'tag',
        'condition',
        'summary',
        'reportText',
        'engine',
        'mappingNotice',
      ]) {
        if (report[key] is! String || (report[key] as String).isEmpty) {
          throw FormatException('Missing spatial report field: $key');
        }
      }
      _reports[id] = report;
    }
  }

  final AssetData _legacy;
  final Map<String, Map<String, dynamic>> _reports = {};

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid spatial export');
    }
    return value;
  }

  Map<String, dynamic>? _reportForObject(
    String objectId,
    String? equipmentType,
  ) {
    final report = _reports[objectId];
    if (report != null &&
        _legacy.hasReviewedMappings &&
        equipmentType != null &&
        _legacy.tagForObject(objectId, equipmentType: equipmentType) == null) {
      return null;
    }
    return report;
  }

  String? tagForObject(String objectId, {required String equipmentType}) =>
      _reportForObject(objectId, equipmentType)?['tag'] as String? ??
      _legacy.tagForObject(objectId, equipmentType: equipmentType);

  String? conditionForObject(String objectId, {String? equipmentType}) =>
      _reportForObject(objectId, equipmentType)?['condition'] as String? ??
      _legacy.conditionForObject(objectId, equipmentType: equipmentType);

  SpatialDiagnosis? forObject(String objectId, {String? equipmentType}) {
    final report = _reportForObject(objectId, equipmentType);
    if (report != null) {
      final explanation =
          report['engine'] == 'ollama' && report['llmSummary'] is String
          ? report['llmSummary'] as String
          : report['summary'] as String;
      final disclosure = report['mappingNotice'] as String;
      final legacy = _legacy.forObject(objectId, equipmentType: equipmentType);
      final evidence = legacy?.arrivalSummary ?? report['reportText'] as String;
      final redPump =
          objectId == 'boiler-room:red-circulation-pump' &&
          legacy?.tag == 'P-005' &&
          legacy?.assetId == 'ASSET-017';
      final brief = redPump ? _redPumpBrief(legacy!, report) : null;
      final aiEvidence = report['engine'] == 'ollama'
          ? 'Local AI explanation · Precomputed\n$explanation\n'
                '[${(report['llmReferences'] as List).join(', ')}]\n\n'
          : '';
      return SpatialDiagnosis(
        tag: report['tag'] as String,
        condition: report['condition'] as String,
        arrivalSummary: brief != null
            ? '${legacy!.condition == 'attention_required' ? 'Needs attention' : legacy.condition} · Synthetic workbook\n'
                  'Next check: ${legacy.nextCheck} [${legacy.stateEvidence.reference}]'
            : '${report['tag']} · ${report['condition']}\n'
                  '$disclosure\n$explanation\n$evidence\nEngine: ${report['engine']}',
        reportText:
            '${brief == null ? '' : '$brief\n\n${aiEvidence}Full workbook evidence\n\n'}'
            '$disclosure\n\n'
            '${brief == null ? aiEvidence : ''}'
            '${report['reportText']}\n\nEngine: ${report['engine']}',
        engine: report['engine'] as String,
        motorCurrentSamples: redPump ? legacy!.motorCurrentSamples : const [],
      );
    }
    final legacy = _legacy.forObject(objectId, equipmentType: equipmentType);
    return legacy == null
        ? null
        : SpatialDiagnosis(
            tag: legacy.tag,
            condition: legacy.condition,
            arrivalSummary: legacy.arrivalSummary,
            reportText: legacy.reportText,
            engine: 'legacy-deterministic',
            motorCurrentSamples: legacy.motorCurrentSamples,
          );
  }

  static String _redPumpBrief(AssetDiagnosis pump, RecordData report) {
    const metrics = {
      'motor_current_a': ('Motor current', 'A', 1),
      'speed_rpm': ('Speed', 'rpm', 0),
      'bearing_temp_c': ('Bearing temperature', '°C', 1),
      'process_flow_pct': ('Flow', '%', 1),
      'process_pressure_bar': ('Process pressure', 'bar', 2),
      'vibration_mm_s': ('Vibration', 'mm/s', 2),
    };
    final allowed = {
      for (final citation in report['citations'] as List)
        _map(citation)['reference'],
    };
    final trends = <String, String>{};
    final observations = report['observations'];
    if (observations is List) {
      for (final row in observations.whereType<RecordData>()) {
        final metric = row['metric'];
        final format = metrics[metric];
        final before = row['baselineMedian'];
        final after = row['recentMedian'];
        final sources = row['references'];
        if (metric is! String ||
            format == null ||
            before is! num ||
            !before.isFinite ||
            after is! num ||
            !after.isFinite ||
            sources is! List ||
            sources.isEmpty ||
            !sources.every((ref) => ref is String && allowed.contains(ref))) {
          continue;
        }
        final (label, unit, precision) = format;
        trends[metric] =
            '$label · ${before.toStringAsFixed(precision)} → '
            '${after.toStringAsFixed(precision)} $unit';
      }
    }
    String? firstCitedItem(String field, {String? contains}) {
      final entries = report[field];
      if (entries is! List) return null;
      for (final entry in entries.whereType<RecordData>()) {
        final references = entry['references'];
        final text = entry['text'];
        if (text is String &&
            (contains == null || text.contains(contains)) &&
            references is List &&
            references.isNotEmpty &&
            references.every((ref) => ref is String && allowed.contains(ref))) {
          return '$text [${references.join(', ')}]';
        }
      }
      return null;
    }

    final conflictingEvent = firstCitedItem('contradictions');
    final qualityNote = firstCitedItem(
      'qualityIssues',
      contains: 'in Telemetry',
    );
    final caseWorkflow = pump.evidence
        .where((item) => item.reference.contains('Historical_Service_Cases!'))
        .firstOrNull;
    return [
      'P-005 · Red circulation pump',
      'Synthetic workbook snapshot · ${pump.updatedAt}',
      'Next check\n${pump.nextCheck} [${pump.stateEvidence.reference}]',
      'Why this check\n${pump.stateEvidence.text} [${pump.stateEvidence.reference}]',
      if (pump.matchingOpenEvidence case final event?)
        'Open workbook event\n${event.text} [${event.reference}]',
      if (trends.isNotEmpty)
        'Telemetry · first vs last 12-hour medians\n'
            '${metrics.keys.map((key) => trends[key]).nonNulls.join('\n')}\n'
            'Exact sample rows are listed in the full evidence below.',
      'Interpretation\nThe workbook flags possible efficiency loss or fouling. '
          'The cause is unconfirmed. Check that the operating points are comparable '
          'before interpreting changes across time. [${pump.stateEvidence.reference}]',
      if (conflictingEvent != null || qualityNote != null)
        'Review required\n${[?conflictingEvent, ?qualityNote].join('\n')}',
      if (caseWorkflow != null)
        'Verification workflow\n${caseWorkflow.text} [${caseWorkflow.reference}]',
      'Site procedures and qualified personnel govern physical inspection.',
    ].join('\n\n');
  }
}
