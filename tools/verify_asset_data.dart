// Run after local workbook import. Output contains private evidence: keep it local.
import 'dart:convert';
import 'dart:io';

import 'package:valmet_field_app/asset_data.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main(List<String> args) {
  if (args.isNotEmpty) {
    throw ArgumentError('Usage: dart tools/verify_asset_data.dart');
  }
  final source = File('assets/valmet/asset-data.json').readAsStringSync();
  final bundle = jsonDecode(source) as Map<String, dynamic>;
  final site = jsonDecode(File('assets/valmet/site.json').readAsStringSync());
  final data = AssetData.fromJson(source);
  const expected = {
    'boiler-room:red-circulation-pump': ('P-005', 'Red circulation pump'),
    'boiler-room:black-circulation-pump': ('P-002', 'Black circulation pump'),
    'boiler-room:blue-inline-valve': ('CV-003', 'Blue inline valve'),
    'boiler-room:far-circulation-pump': ('P-001', 'Far circulation pump'),
    'boiler-room:middle-circulation-pump': ('P-004', 'Middle circulation pump'),
    'boiler-room:wall-circulation-pump': ('P-003', 'Wall circulation pump'),
    'boiler-room:orange-actuator-a': ('CV-001', 'Orange actuator A'),
    'boiler-room:orange-actuator-b': ('CV-002', 'Orange actuator B'),
  };
  final mappings = bundle['mappings'] as Map;
  require(mappings.length == expected.length, 'Expected eight mappings');
  final tables = bundle['tables'] as Map;
  final results = <Map<String, dynamic>>[];
  for (final entry in expected.entries) {
    final id = entry.key;
    final object = (site['objects'] as List).singleWhere(
      (o) => o['objectId'] == id,
    );
    require(object['name'] == entry.value.$2, 'Scene name changed for $id');
    final type = object['equipmentType'] as String;
    final diagnosis = data.forObject(id, equipmentType: type);
    require(diagnosis != null, 'Missing compatible diagnosis for $id');
    final d = diagnosis!;
    final asset = (tables['Asset_Master'] as List).singleWhere(
      (r) => r['asset_id'] == d.assetId,
    );
    final state = (tables['Current_State'] as List).singleWhere(
      (r) => r['asset_id'] == d.assetId,
    );
    require(d.tag == entry.value.$1 && d.tag == asset['tag'], 'Wrong tag: $id');
    require(d.tag == state['tag'], 'State tag mismatch: $id');
    require(d.condition == state['condition_state'], 'Wrong condition: $id');
    require(d.nextCheck == state['recommended_next_check'], 'Wrong check: $id');
    require(
      d.stateEvidence.reference == state['_source'],
      'Wrong state row: $id',
    );
    require(
      d.arrivalSummary.contains('[${state['_source']}]'),
      'Missing check citation: $id',
    );
    require(
      d.arrivalSummary.contains('DOC-FIELD-SAFETY · Knowledge_Docs!'),
      'Missing arrival safety: $id',
    );
    require(
      d.reportText == data.forObject(id, equipmentType: type)!.reportText,
      'Nondeterministic offline report: $id',
    );
    require(
      d.reportText.contains(bundle['mappingNotice'] as String),
      'Missing synthetic mapping disclosure: $id',
    );
    final allowedSources = <String>{};
    for (final tableName in [
      'Current_State',
      'Telemetry_Sample_3d',
      'Alarms_Events',
      'Maintenance_History',
      'Data_Quality',
    ]) {
      allowedSources.addAll(
        (tables[tableName] as List)
            .where((r) => r['asset_id'] == d.assetId)
            .map((r) => r['_source'] as String),
      );
    }
    allowedSources.addAll(
      (tables['Knowledge_Docs'] as List)
          .where(
            (r) =>
                r['doc_id'] == state['knowledge_doc_id'] ||
                r['doc_id'] == 'DOC-FIELD-SAFETY',
          )
          .map((r) => r['_source'] as String),
    );
    allowedSources.addAll(
      (tables['Historical_Service_Cases'] as List)
          .where(
            (r) =>
                r['asset_class'] == asset['asset_class'] &&
                r['historical_issue_code'] == state['issue_code'],
          )
          .map((r) => r['_source'] as String),
    );
    for (final evidence in [
      ...d.evidence,
      ...d.hypotheses,
      ...d.qualityIssues,
    ]) {
      final references = RegExp(
        r'[A-Za-z_0-9]+!\d+',
      ).allMatches(evidence.reference).map((m) => m.group(0)!);
      require(
        references.isNotEmpty && references.every(allowedSources.contains),
        'Unrelated or ungrounded evidence for $id: ${evidence.reference}',
      );
    }
    results.add({
      'objectId': id,
      'sceneName': object['name'],
      'service': object['service'] != null,
      'tag': d.tag,
      'assetId': d.assetId,
      'assetRow': asset['_source'],
      'stateRow': d.stateEvidence.reference,
      'condition': d.condition,
      'arrivalSummary': d.arrivalSummary,
      'evidence': d.evidence.map((e) => e.reference).toList(),
      'hypotheses': d.hypotheses.map((e) => e.reference).toList(),
      'qualityIssues': d.qualityIssues.map((e) => e.reference).toList(),
    });
  }
  require(
    results.where((r) => r['service'] == true).length == 6,
    'Expected six service diagnoses',
  );
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'sourceSha256': bundle['sourceSha256'],
      'tableRows': {
        for (final entry in tables.entries)
          entry.key: (entry.value as List).length,
      },
      'offlineDeterministic': true,
      'mappings': results,
    }),
  );
}
