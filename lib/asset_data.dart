import 'dart:convert';

typedef RecordData = Map<String, dynamic>;

class Evidence {
  const Evidence(this.reference, this.text);
  final String reference;
  final String text;
}

class AssetDiagnosis {
  const AssetDiagnosis({
    required this.assetId,
    required this.tag,
    required this.condition,
    required this.updatedAt,
    required this.confidence,
    required this.observation,
    required this.nextCheck,
    required this.evidence,
    required this.hypotheses,
    required this.qualityIssues,
    required this.mappingNotice,
  });

  final String assetId, tag, condition, updatedAt, observation, nextCheck;
  final String mappingNotice;
  final double? confidence;
  final List<Evidence> evidence, hypotheses, qualityIssues;

  String get reportText => [
    '$tag · $condition ($assetId)',
    mappingNotice,
    'Workbook snapshot: $updatedAt',
    'Observation: $observation',
    'Workbook model confidence: ${confidence == null ? 'unavailable' : '${(confidence! * 100).round()}%'} (supplied metadata)',
    'Next verification: $nextCheck',
    'Local evidence summary. A cause has not been confirmed.',
    for (final e in qualityIssues) 'Data quality: ${e.text}\n[${e.reference}]',
    'Evidence:',
    for (final e in evidence) '${e.text}\n[${e.reference}]',
    'Historical hypotheses:',
    if (hypotheses.isEmpty) 'No matching historical case supplied.',
    for (final e in hypotheses) '${e.text}\n[${e.reference}]',
  ].join('\n\n');
}

/// Local evidence retrieval and deterministic explanations. No remote model,
/// inferred equipment identity, or invented thresholds are used here.
class AssetData {
  AssetData.fromJson(String source) : _json = jsonDecode(source) {
    if (_json['schemaVersion'] != 1 || _json['synthetic'] != true) {
      throw const FormatException('Unsupported asset data bundle');
    }
    for (final name in [
      'Asset_Master',
      'Current_State',
      'Telemetry_Sample_3d',
      'Alarms_Events',
      'Maintenance_History',
      'Historical_Service_Cases',
      'Knowledge_Docs',
      'Data_Quality',
    ]) {
      if (_tables[name] is! List) {
        throw FormatException('Missing evidence table: $name');
      }
    }
  }

  final RecordData _json;
  RecordData get _tables => _json['tables'] as RecordData;
  List<RecordData> _rows(String name) =>
      (_tables[name] as List).cast<RecordData>();

  RecordData? _currentState(Object assetId) => _rows(
    'Current_State',
  ).where((r) => r['asset_id'] == assetId).singleOrNull;

  String? conditionForObject(String objectId) {
    final assetId = (_json['mappings'] as RecordData)[objectId];
    if (assetId == null) return null;
    final condition = _currentState(assetId)?['condition_state'];
    return condition is String && condition.isNotEmpty ? condition : null;
  }

  AssetDiagnosis? forObject(String objectId) {
    final assetId = (_json['mappings'] as RecordData)[objectId];
    if (assetId == null) return null;
    final asset = _rows(
      'Asset_Master',
    ).where((r) => r['asset_id'] == assetId).singleOrNull;
    final state = _currentState(assetId);
    if (asset == null || state == null) return null;

    List<RecordData> latest(String name, String time) {
      final rows = _rows(name).where((r) => r['asset_id'] == assetId).toList();
      rows.sort((a, b) => '${b[time]}'.compareTo('${a[time]}'));
      return rows;
    }

    Evidence entry(RecordData r, String text, [String? id]) => Evidence(
      id == null ? '${r['_source']}' : '${r[id]} · ${r['_source']}',
      text,
    );

    final telemetry = latest('Telemetry_Sample_3d', 'timestamp');
    final docs = _rows('Knowledge_Docs').where(
      (r) =>
          r['doc_id'] == state['knowledge_doc_id'] ||
          r['doc_id'] == 'DOC-FIELD-SAFETY',
    );
    final evidence = <Evidence>[
      entry(
        state,
        '${state['issue_summary']}. Health score: '
        '${state['health_score']}; urgency: ${state['urgency']}.',
      ),
      if (telemetry.isNotEmpty)
        entry(
          telemetry.first,
          'Telemetry at ${telemetry.first['timestamp']}: '
          '${telemetry.first.entries.where((e) => e.value is num).map((e) => '${e.key}=${e.value}').join(', ')}',
        ),
      for (final r in latest('Alarms_Events', 'timestamp').take(3))
        entry(
          r,
          '${r['timestamp']}: ${r['event_code']} · '
              '${r['description']} (${r['status']})',
          'event_id',
        ),
      for (final r in latest('Maintenance_History', 'opened_at').take(2))
        entry(
          r,
          '${r['opened_at']}: ${r['action']} · ${r['result']}',
          'work_order_id',
        ),
      for (final r in docs) entry(r, '${r['content']}', 'doc_id'),
    ];
    if (!docs.any((r) => r['doc_id'] == state['knowledge_doc_id'])) {
      evidence.add(
        Evidence(
          '${state['_source']}',
          'Referenced context document ${state['knowledge_doc_id']} is unavailable.',
        ),
      );
    }
    if (telemetry.isEmpty) {
      evidence.add(
        const Evidence(
          'Telemetry_Sample_3d',
          'No telemetry samples supplied for this asset.',
        ),
      );
    }
    return AssetDiagnosis(
      assetId: '$assetId',
      tag: '${asset['tag']}',
      condition: '${state['condition_state']}',
      updatedAt: '${state['last_updated']}',
      confidence: (state['model_confidence'] as num?)?.toDouble(),
      observation: '${state['issue_summary']}',
      nextCheck: '${state['recommended_next_check']}',
      mappingNotice: '${_json['mappingNotice']}',
      evidence: evidence,
      hypotheses: [
        for (final r
            in _rows('Historical_Service_Cases')
                .where(
                  (r) =>
                      r['asset_class'] == asset['asset_class'] &&
                      r['historical_issue_code'] == state['issue_code'],
                )
                .take(3))
          entry(
            r,
            '${r['historical_interpretation']}. '
                'Historical synthetic example; not a confirmed cause.',
            'case_id',
          ),
      ],
      qualityIssues: [
        for (final r in _rows(
          'Data_Quality',
        ).where((r) => r['asset_id'] == assetId))
          entry(
            r,
            '${r['issue_type']} (${r['severity']}) in '
                '${r['source_sheet']}: ${r['recommended_handling']}',
            'issue_id',
          ),
      ],
    );
  }
}
