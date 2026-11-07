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
  });

  final String tag, condition, arrivalSummary, reportText, engine;
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

  String? tagForObject(String objectId, {required String equipmentType}) =>
      _reports[objectId]?['tag'] as String? ??
      _legacy.tagForObject(objectId, equipmentType: equipmentType);

  String? conditionForObject(String objectId, {String? equipmentType}) =>
      _reports[objectId]?['condition'] as String? ??
      _legacy.conditionForObject(objectId, equipmentType: equipmentType);

  SpatialDiagnosis? forObject(String objectId, {String? equipmentType}) {
    final report = _reports[objectId];
    if (report != null) {
      final explanation =
          report['engine'] == 'ollama' && report['llmSummary'] is String
          ? report['llmSummary'] as String
          : report['summary'] as String;
      final disclosure = report['mappingNotice'] as String;
      final legacyGuidance = _legacy
          .forObject(objectId, equipmentType: equipmentType)
          ?.arrivalSummary;
      final evidence = legacyGuidance ?? report['reportText'] as String;
      return SpatialDiagnosis(
        tag: report['tag'] as String,
        condition: report['condition'] as String,
        arrivalSummary:
            '${report['tag']} · ${report['condition']}\n'
            '$disclosure\n$explanation\n$evidence\nEngine: ${report['engine']}',
        reportText:
            '$disclosure\n\n'
            '${report['engine'] == 'ollama' ? 'Local AI explanation: $explanation\n\n' : ''}'
            '${report['reportText']}\n\nEngine: ${report['engine']}',
        engine: report['engine'] as String,
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
          );
  }
}
