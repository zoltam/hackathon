import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:valmet_field_app/asset_data.dart';

void main() {
  Map<String, dynamic> bundle() => {
    'schemaVersion': 1,
    'synthetic': true,
    'mappingNotice': 'Synthetic test mapping',
    'mappings': {'object-1': 'asset-1'},
    'tables': {
      'Asset_Master': [
        {'asset_id': 'asset-1', 'tag': 'TEST-1', 'asset_class': 'TEST'},
      ],
      'Current_State': [
        {
          'asset_id': 'asset-1',
          'condition_state': 'watch',
          'last_updated': '2026-01-03',
          'model_confidence': .7,
          'issue_summary': 'Test observation',
          'recommended_next_check': 'Verify reference',
          'issue_code': 'DRIFT',
          'knowledge_doc_id': 'doc-1',
          '_source': 'Current_State!2',
        },
      ],
      'Telemetry_Sample_3d': [
        {
          'asset_id': 'asset-1',
          'timestamp': '2026-01-02',
          'sensor_bias': 2,
          '_source': 'Telemetry_Sample_3d!3',
        },
        {
          'asset_id': 'asset-1',
          'timestamp': '2026-01-01',
          'sensor_bias': 1,
          '_source': 'Telemetry_Sample_3d!2',
        },
        {
          'asset_id': 'other',
          'timestamp': '2026-01-03',
          'sensor_bias': 99,
          '_source': 'Telemetry_Sample_3d!4',
        },
      ],
      'Knowledge_Docs': [
        {
          'doc_id': 'doc-1',
          'content': 'Test context',
          '_source': 'Knowledge_Docs!2',
        },
      ],
      'Historical_Service_Cases': [
        {
          'asset_class': 'TEST',
          'historical_issue_code': 'DRIFT',
          'case_id': 'case-1',
          'historical_interpretation': 'Possible drift',
          'safe_evidence_workflow': 'Confirm identity before checking trend.',
          '_source': 'Historical_Service_Cases!2',
        },
        {
          'asset_class': 'OTHER',
          'historical_issue_code': 'DRIFT',
          'case_id': 'case-2',
          'historical_interpretation': 'Wrong equipment',
          '_source': 'Historical_Service_Cases!3',
        },
      ],
      'Alarms_Events': [],
      'Maintenance_History': [],
      'Data_Quality': [
        {
          'asset_id': 'asset-1',
          'issue_id': 'dq-1',
          'issue_type': 'missing_data',
          'severity': 'high',
          'source_sheet': 'Telemetry_Sample_3d',
          'recommended_handling': 'review',
          '_source': 'Data_Quality!2',
        },
      ],
    },
  };

  test('keeps the newest open fault event alongside recent evidence', () {
    final source = bundle();
    source['tables']['Alarms_Events'] = [
      for (var day = 1; day <= 6; day++)
        {
          'asset_id': day == 6 ? 'other' : 'asset-1',
          'event_id': 'evt-$day',
          'event_code': day <= 2 || day == 6 ? 'DRIFT' : 'NOTE',
          'status': day == 5 ? 'closed' : 'open',
          'timestamp': '2026-01-0$day',
          'description': 'Event $day',
          '_source': 'Alarms_Events!${day + 1}',
        },
    ];
    final data = AssetData.fromJson(jsonEncode(source));
    final diagnosis = data.forObject('object-1')!;
    final events = diagnosis.evidence
        .where((e) => e.reference.contains('Alarms_Events!'))
        .map((e) => e.reference);
    expect(events, [
      'evt-2 · Alarms_Events!3',
      'evt-5 · Alarms_Events!6',
      'evt-4 · Alarms_Events!5',
    ]);
    expect(
      diagnosis.reportText,
      contains(
        'Matching open workbook event: 2026-01-02: DRIFT · Event 2 (open)\n'
        '[evt-2 · Alarms_Events!3]',
      ),
    );
    expect('Alarms_Events!3'.allMatches(diagnosis.reportText), hasLength(1));
  });

  test('malformed bundle shapes use the unavailable-data fallback error', () {
    for (final source in ['null', '[]', 'true', '"bundle"']) {
      expect(() => AssetData.fromJson(source), throwsFormatException);
    }
    for (final field in ['tables', 'mappings']) {
      for (final value in [null, [], 'invalid']) {
        final source = bundle()..[field] = value;
        expect(
          () => AssetData.fromJson(jsonEncode(source)),
          throwsFormatException,
          reason: '$field=$value must reach the existing loader fallback',
        );
      }
    }
    final source = bundle();
    for (final name in (source['tables'] as Map).keys) {
      final invalid = bundle();
      invalid['tables'][name] = ['invalid row'];
      expect(
        () => AssetData.fromJson(jsonEncode(invalid)),
        throwsFormatException,
        reason: '$name rows must be safe for retrieval',
      );
    }
    source['tables']['Current_State'][0]['model_confidence'] = 'invalid';
    expect(() => AssetData.fromJson(jsonEncode(source)), throwsFormatException);
  });

  test(
    'confidence cannot overflow report formatting or exceed probability bounds',
    () {
      for (final value in ['1e308', '1e999', '-0.1', '1.1']) {
        final source = jsonEncode(
          bundle(),
        ).replaceFirst('"model_confidence":0.7', '"model_confidence":$value');
        expect(() => AssetData.fromJson(source), throwsFormatException);
      }
      for (final value in [null, 0, 1]) {
        final source = jsonDecode(jsonEncode(bundle()));
        source['tables']['Current_State'][0]['model_confidence'] = value;
        final diagnosis = AssetData.fromJson(
          jsonEncode(source),
        ).forObject('object-1')!;
        expect(diagnosis.confidence, value);
        expect(diagnosis.reportText, contains('Workbook model confidence:'));
      }
    },
  );

  test('retrieves only mapped asset evidence with source references', () {
    final data = AssetData.fromJson(jsonEncode(bundle()));
    final diagnosis = data.forObject('object-1')!;
    expect(diagnosis.assetId, 'asset-1');
    expect(
      diagnosis.arrivalSummary,
      contains('Next check · Verify reference [Current_State!2]'),
    );
    expect(
      diagnosis.reportText,
      contains('Next verification: Verify reference\n[Current_State!2]'),
    );
    expect('Current_State!2'.allMatches(diagnosis.reportText), hasLength(1));
    expect(
      diagnosis.reportText,
      isNot(contains('Matching open workbook event')),
    );
    expect(
      diagnosis.evidence.any((e) => e.text.contains('sensor_bias=2')),
      isTrue,
    );
    expect(
      diagnosis.evidence.any((e) => e.text.contains('sensor_bias=99')),
      isFalse,
    );
    expect(diagnosis.evidence.every((e) => e.reference.isNotEmpty), isTrue);
    final comparison = diagnosis.evidence.singleWhere(
      (e) => e.text.startsWith('Included telemetry samples'),
    );
    expect(comparison.text, contains('sensor_bias: 1 to 2'));
    expect(
      comparison.reference,
      'Telemetry_Sample_3d!2; Telemetry_Sample_3d!3',
    );
    expect(
      diagnosis.reportText,
      contains('Confirm identity before checking trend.'),
    );
    expect(
      diagnosis.reportText,
      contains('case-1 · Historical_Service_Cases!2'),
    );
    expect(diagnosis.hypotheses, hasLength(1));
    expect(diagnosis.hypotheses.first.text, contains('not a confirmed cause'));
    expect(diagnosis.qualityIssues.single.reference, contains('dq-1'));
    expect(data.forObject('unknown'), isNull);
  });

  test('uses the exact workbook tag only for a compatible scene class', () {
    final json = bundle();
    final tables = json['tables'] as Map;
    final asset = (tables['Asset_Master'] as List).single as Map;
    asset['tag'] = 'P-005';
    asset['asset_class'] = 'PROCESS_PUMP';
    final data = AssetData.fromJson(jsonEncode(json));

    expect(data.tagForObject('object-1', equipmentType: 'pump'), 'P-005');
    expect(data.forObject('object-1', equipmentType: 'pump')?.tag, 'P-005');
    expect(data.conditionForObject('object-1', equipmentType: 'pump'), 'watch');
    expect(data.tagForObject('object-1', equipmentType: 'valve'), isNull);
    expect(data.forObject('object-1', equipmentType: 'valve'), isNull);
    expect(data.conditionForObject('object-1', equipmentType: 'valve'), isNull);
  });

  test('does not retrieve unrelated events, maintenance, quality or cases', () {
    final source = bundle();
    final tables = source['tables'] as Map;
    for (final table in [
      'Alarms_Events',
      'Maintenance_History',
      'Data_Quality',
    ]) {
      (tables[table] as List).add({
        'asset_id': 'other',
        'timestamp': '2099-01-01',
        'opened_at': '2099-01-01',
        'description': 'FOREIGN EVIDENCE',
        'action': 'FOREIGN EVIDENCE',
        'recommended_handling': 'FOREIGN EVIDENCE',
        'event_code': 'DRIFT',
        'status': 'open',
        '_source': '$table!999',
      });
    }
    (tables['Historical_Service_Cases'] as List).add({
      'asset_class': 'TEST',
      'historical_issue_code': 'DIFFERENT',
      'historical_interpretation': 'FOREIGN EVIDENCE',
      'safe_evidence_workflow': 'FOREIGN EVIDENCE',
      '_source': 'Historical_Service_Cases!999',
    });
    (tables['Knowledge_Docs'] as List).add({
      'doc_id': 'unrelated-document',
      'content': 'FOREIGN EVIDENCE',
      '_source': 'Knowledge_Docs!999',
    });
    final diagnosis = AssetData.fromJson(
      jsonEncode(source),
    ).forObject('object-1')!;
    expect(diagnosis.reportText, isNot(contains('FOREIGN EVIDENCE')));
    expect(diagnosis.reportText, isNot(contains('!999')));
    expect(diagnosis.hypotheses, hasLength(1));
    expect(diagnosis.matchingOpenEvidence, isNull);
  });

  test('uses a parent valve record for a reviewed valve actuator', () {
    final source = bundle();
    final tables = source['tables'] as Map;
    final asset = (tables['Asset_Master'] as List).single as Map;
    asset['tag'] = 'CV-001';
    asset['asset_class'] = 'CONTROL_VALVE';
    final data = AssetData.fromJson(jsonEncode(source));

    expect(
      data.tagForObject('object-1', equipmentType: 'valve_actuator'),
      'CV-001',
    );
    expect(data.tagForObject('object-1', equipmentType: 'actuator'), isNull);
    expect(
      data.tagForObject('object-1', equipmentType: 'inline_valve'),
      isNull,
    );

    source['mappingMethod'] = 'synthetic_explicit';
    final reviewed = AssetData.fromJson(jsonEncode(source));
    expect(
      reviewed.tagForObject('object-1', equipmentType: 'inline_valve'),
      'CV-001',
    );
    expect(reviewed.tagForObject('object-1', equipmentType: 'motor'), isNull);
  });

  test('arrival preserves source safety boundaries and exact next check', () {
    final source = bundle();
    (source['tables']['Knowledge_Docs'] as List).add({
      'doc_id': 'DOC-FIELD-SAFETY',
      'content': 'Use approved procedures and qualified personnel.',
      '_source': 'Knowledge_Docs!7',
    });
    final data = AssetData.fromJson(jsonEncode(source));
    final diagnosis = data.forObject('object-1')!;
    expect(diagnosis.nextCheck, 'Verify reference');
    expect(
      diagnosis.arrivalSummary,
      contains(
        'Use approved procedures and qualified personnel. '
        '[DOC-FIELD-SAFETY · Knowledge_Docs!7]',
      ),
    );
    expect(diagnosis.reportText, contains('not a confirmed cause'));
    expect(diagnosis.reportText, isNot(contains('Wrong equipment')));
    expect(diagnosis.reportText, data.forObject('object-1')!.reportText);
    expect(
      diagnosis.arrivalSummary,
      data.forObject('object-1')!.arrivalSummary,
    );
  });

  test('missing evidence is explicit and confidence is not manufactured', () {
    final json = jsonDecode(jsonEncode(bundle())) as Map<String, dynamic>;
    final tables = json['tables'] as Map;
    tables['Telemetry_Sample_3d'] = [];
    tables['Knowledge_Docs'] = [];
    (tables['Current_State'] as List).first['model_confidence'] = null;
    final d = AssetData.fromJson(jsonEncode(json)).forObject('object-1')!;
    expect(d.confidence, isNull);
    expect(d.evidence.any((e) => e.text.contains('No telemetry')), isTrue);
    expect(d.evidence.any((e) => e.text.contains('unavailable')), isTrue);
    expect(
      d.arrivalSummary,
      contains(
        'Follow site procedures, permits and qualified personnel before physical inspection.',
      ),
    );
    expect(d.arrivalSummary, isNot(contains('DOC-FIELD-SAFETY')));
    expect(
      d.reportText,
      contains(
        'Follow site procedures, permits and qualified personnel before physical inspection.',
      ),
    );
  });
}
