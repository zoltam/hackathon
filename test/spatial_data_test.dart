import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/asset_data.dart';
import 'package:valmet_field_app/site.dart';
import 'package:valmet_field_app/spatial_data.dart';

void main() {
  test(
    'portable sidecars preserve synthetic identity and reject unknown citations',
    () {
      final bundle = {
        'schemaVersion': 1,
        'synthetic': true,
        'sourceSha256': 'workbook-hash',
        'mappingNotice': 'Synthetic test association',
        'mappings': {'old-pump': 'asset'},
        'tables': {
          'Asset_Master': [
            {
              'asset_id': 'asset',
              'tag': 'P-001',
              'asset_class': 'PROCESS_PUMP',
              '_source': 'Asset_Master!2',
            },
          ],
          'Current_State': [],
          'Telemetry_Sample_3d': [],
          'Alarms_Events': [],
          'Maintenance_History': [],
          'Historical_Service_Cases': [],
          'Knowledge_Docs': [],
          'Data_Quality': [],
        },
      };
      final associations = {
        'schemaVersion': 1,
        'sourceSha256': 'workbook-hash',
        'sceneSourceSha256': 'scene-hash',
        'synthetic': true,
        'associations': [
          {
            'sceneObjectId': 'chair',
            'workbookAssetId': 'asset',
            'synthetic': true,
          },
        ],
      };
      final report = <String, dynamic>{
        'sceneObjectId': 'chair',
        'workbookAssetId': 'asset',
        'sourceSha256': 'workbook-hash',
        'synthetic': true,
        'tag': 'P-001',
        'condition': 'healthy',
        'mappingNotice':
            'Synthetic contextual association; chair identity retained.',
        'summary': 'Supplied synthetic state.',
        'reportText': 'Evidence [Asset_Master!2]',
        'engine': 'deterministic',
        'citations': [
          {'reference': 'Asset_Master!2', 'text': 'Asset record'},
        ],
      };
      SpatialAssetData load() => SpatialAssetData.fromJson(
        jsonEncode(bundle),
        associationsSource: jsonEncode(associations),
        sceneSourceSha256: 'scene-hash',
        diagnosticsSource: jsonEncode({
          'schemaVersion': 1,
          'sourceSha256': 'workbook-hash',
          'sceneSourceSha256': 'scene-hash',
          'reports': {'chair': report},
        }),
      );
      expect(load().tagForObject('chair', equipmentType: 'chair'), 'P-001');
      expect(
        load().forObject('chair')!.arrivalSummary,
        contains('chair identity retained'),
      );
      report['citations'] = [
        {'reference': 'Invented!999', 'text': 'unavailable'},
      ];
      expect(load, throwsFormatException);
      report['citations'] = [
        {'reference': 'Asset_Master!2', 'text': 'Asset record'},
      ];
      report['engine'] = 'ollama';
      report['modelStatus'] = 'validated';
      report['llmSummary'] = 'Local model explanation';
      report['llmReferences'] = ['Invented!999'];
      expect(load, throwsFormatException);
      report['llmReferences'] = ['Asset_Master!2'];
      expect(
        load().forObject('chair')!.reportText,
        contains('Local AI explanation'),
      );
    },
  );

  final output = Directory('build/spatial');
  final prepared = File('${output.path}/diagnostics.json').existsSync();

  test(
    'loads the actual person scene and every synthetic report export',
    () {
      final site = Site.fromJson(
        File('${output.path}/site.json').readAsStringSync(),
      );
      final data = SpatialAssetData.fromJson(
        File('${output.path}/asset-data.json').readAsStringSync(),
        associationsSource: File(
          '${output.path}/associations.json',
        ).readAsStringSync(),
        diagnosticsSource: File(
          '${output.path}/diagnostics.json',
        ).readAsStringSync(),
        sceneSourceSha256: site.sourceSha256,
      );
      for (final object in site.objects) {
        final report = data.forObject(
          object.objectId,
          equipmentType: object.equipmentType,
        );
        expect(report, isNotNull, reason: object.objectId);
        expect(report!.reportText, contains('Synthetic'));
        expect(report.reportText, contains('Current_State!'));
        expect(report.arrivalSummary, contains('Engine:'));
      }
      expect(
        data.tagForObject(
          'boiler-room:red-circulation-pump',
          equipmentType: 'pump',
        ),
        'P-005',
      );
      expect(data.forObject('unknown'), isNull);
    },
    skip: !prepared ? 'Prepare the local spatial backend exports first' : false,
  );

  test(
    'legacy reports remain unchanged when optional sidecars are absent',
    () {
      final source = File('${output.path}/asset-data.json').readAsStringSync();
      final original = AssetData.fromJson(source);
      final adapted = SpatialAssetData.fromJson(source);
      const id = 'boiler-room:red-circulation-pump';
      expect(
        adapted.forObject(id)!.reportText,
        original.forObject(id)!.reportText,
      );
      expect(
        adapted.forObject(id)!.arrivalSummary,
        original.forObject(id)!.arrivalSummary,
      );
      expect(adapted.tagForObject(id, equipmentType: 'carton'), isNull);
    },
    skip: !prepared ? 'Prepare the local spatial backend exports first' : false,
  );

  test(
    'rejects mixed sources, duplicate associations and mismatched report identity',
    () {
      final source = File('${output.path}/asset-data.json').readAsStringSync();
      final associations =
          jsonDecode(
                File('${output.path}/associations.json').readAsStringSync(),
              )
              as Map;
      final diagnostics = File(
        '${output.path}/diagnostics.json',
      ).readAsStringSync();
      SpatialAssetData load(Map associations) => SpatialAssetData.fromJson(
        source,
        associationsSource: jsonEncode(associations),
        diagnosticsSource: diagnostics,
      );
      final wrongHash = {...associations, 'sourceSha256': 'wrong'};
      expect(() => load(wrongHash), throwsFormatException);
      final wrongScene = {...associations, 'sceneSourceSha256': 'other-scene'};
      // Internal consistency is required even without an expected scene hash.
      expect(() => load(wrongScene), throwsFormatException);
      final rows = associations['associations'] as List;
      expect(
        () => load({
          ...associations,
          'associations': [...rows, rows.first],
        }),
        throwsFormatException,
      );
      final wrongAsset = jsonDecode(jsonEncode(associations)) as Map;
      wrongAsset['associations'][0]['workbookAssetId'] = 'other';
      expect(() => load(wrongAsset), throwsFormatException);
      expect(
        () => SpatialAssetData.fromJson(source, diagnosticsSource: diagnostics),
        throwsFormatException,
      );
    },
    skip: !prepared ? 'Prepare the local spatial backend exports first' : false,
  );
}
