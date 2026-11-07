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
    required this.nextCheck,
    required this.stateEvidence,
    required this.matchingOpenEvidence,
    required this.evidence,
    required this.hypotheses,
    required this.qualityIssues,
    required this.mappingNotice,
  });

  final String assetId, tag, condition, updatedAt, nextCheck;
  final String mappingNotice;
  final double? confidence;
  final Evidence stateEvidence;
  final Evidence? matchingOpenEvidence;
  final List<Evidence> evidence, hypotheses, qualityIssues;

  Evidence? get _fieldSafety => evidence
      .where((e) => e.reference.startsWith('DOC-FIELD-SAFETY · '))
      .firstOrNull;

  String get _safetyBoundary {
    final safety = _fieldSafety;
    return safety == null
        ? 'Follow site procedures, permits and qualified personnel before physical inspection.'
        : '${safety.text} [${safety.reference}]';
  }

  String get arrivalSummary =>
      '$tag · $condition · Synthetic workbook\n'
      'Next check · $nextCheck [${stateEvidence.reference}]\n'
      '$_safetyBoundary';

  String get reportText => [
    '$tag · $condition ($assetId)',
    mappingNotice,
    'Workbook snapshot: $updatedAt',
    'Observation: ${stateEvidence.text}\n'
        'Next verification: $nextCheck\n[${stateEvidence.reference}]',
    'Workbook model confidence: ${confidence == null ? 'unavailable' : '${(confidence! * 100).round()}%'} (supplied metadata)',
    if (matchingOpenEvidence case final event?)
      'Matching open workbook event: ${event.text}\n[${event.reference}]',
    'Local evidence summary. A cause has not been confirmed.',
    if (_fieldSafety == null) _safetyBoundary,
    for (final e in qualityIssues) 'Data quality: ${e.text}\n[${e.reference}]',
    'Evidence:',
    for (final e in evidence)
      if (e != stateEvidence && e != matchingOpenEvidence)
        '${e.text}\n[${e.reference}]',
    'Historical hypotheses:',
    if (hypotheses.isEmpty) 'No matching historical case supplied.',
    for (final e in hypotheses) '${e.text}\n[${e.reference}]',
  ].join('\n\n');
}

/// Offline diagnostic guidance from workbook records and matching cases.
class AssetData {
  AssetData.fromJson(String source) : _json = _decodeBundle(source) {
    if (_json['schemaVersion'] != 1 ||
        _json['synthetic'] != true ||
        _json['tables'] is! RecordData ||
        _json['mappings'] is! RecordData) {
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
      final rows = _tables[name];
      if (rows is! List) {
        throw FormatException('Missing evidence table: $name');
      }
      if (rows.any((row) => row is! RecordData)) {
        throw FormatException('Invalid evidence row: $name');
      }
    }
    for (final state in _rows('Current_State')) {
      final confidence = state['model_confidence'];
      if (confidence != null &&
          (confidence is! num ||
              !confidence.isFinite ||
              confidence < 0 ||
              confidence > 1)) {
        throw const FormatException('Invalid workbook model confidence');
      }
    }
  }

  static RecordData _decodeBundle(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! RecordData) {
      throw const FormatException('Unsupported asset data bundle');
    }
    return decoded;
  }

  final RecordData _json;
  RecordData get _tables => _json['tables'] as RecordData;
  List<RecordData> _rows(String name) =>
      (_tables[name] as List).cast<RecordData>();

  RecordData? _currentState(Object assetId) => _rows(
    'Current_State',
  ).where((r) => r['asset_id'] == assetId).singleOrNull;

  RecordData? _assetForObject(String objectId, String? equipmentType) {
    final assetId = (_json['mappings'] as RecordData)[objectId];
    if (assetId == null) return null;
    final asset = _rows(
      'Asset_Master',
    ).where((r) => r['asset_id'] == assetId).singleOrNull;
    final compatible = switch (equipmentType) {
      null => true,
      'pump' => asset?['asset_class'] == 'PROCESS_PUMP',
      'valve' || 'valve_actuator' => asset?['asset_class'] == 'CONTROL_VALVE',
      _ => false,
    };
    return compatible ? asset : null;
  }

  String? tagForObject(String objectId, {required String equipmentType}) {
    final tag = _assetForObject(objectId, equipmentType)?['tag'];
    return tag is String && tag.isNotEmpty ? tag : null;
  }

  String? conditionForObject(String objectId, {String? equipmentType}) {
    final assetId = _assetForObject(objectId, equipmentType)?['asset_id'];
    if (assetId == null) return null;
    final condition = _currentState(assetId)?['condition_state'];
    return condition is String && condition.isNotEmpty ? condition : null;
  }

  AssetDiagnosis? forObject(String objectId, {String? equipmentType}) {
    final asset = _assetForObject(objectId, equipmentType);
    if (asset == null) return null;
    final assetId = asset['asset_id'] as Object;
    final state = _currentState(assetId);
    if (state == null) return null;

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
    final recent = telemetry.firstOrNull;
    final oldest = telemetry.lastOrNull;
    final recentTime = recent?['timestamp'];
    final oldestTime = oldest?['timestamp'];
    final comparison = recent == null || oldest == null
        ? <String>[]
        : [
            for (final field in recent.entries)
              if (field.value is num && oldest[field.key] is num)
                '${field.key}: ${oldest[field.key]} to ${field.value}',
          ];
    final issue = state['issue_code'];
    final events = latest('Alarms_Events', 'timestamp');
    final matchingOpenEvent = events
        .where(
          (r) =>
              issue is String &&
              issue.isNotEmpty &&
              issue != 'NORMAL' &&
              r['event_code'] == issue &&
              r['status'] == 'open',
        )
        .firstOrNull;
    Evidence eventEvidence(RecordData r) => entry(
      r,
      '${r['timestamp']}: ${r['event_code']} · '
          '${r['description']} (${r['status']})',
      'event_id',
    );
    final matchingOpenEvidence = matchingOpenEvent == null
        ? null
        : eventEvidence(matchingOpenEvent);
    final otherReportEvents = events
        .where((event) => event != matchingOpenEvent)
        .take(matchingOpenEvidence == null ? 3 : 2);
    final cases = _rows('Historical_Service_Cases')
        .where(
          (r) =>
              issue is String &&
              issue.isNotEmpty &&
              r['asset_class'] == asset['asset_class'] &&
              r['historical_issue_code'] == issue,
        )
        .take(3)
        .toList();
    final workflow = cases
        .where(
          (r) =>
              r['safe_evidence_workflow'] is String &&
              (r['safe_evidence_workflow'] as String).trim().isNotEmpty,
        )
        .firstOrNull;
    final docs = _rows('Knowledge_Docs').where(
      (r) =>
          r['doc_id'] == state['knowledge_doc_id'] ||
          r['doc_id'] == 'DOC-FIELD-SAFETY',
    );
    final stateEvidence = entry(
      state,
      '${state['issue_summary']}. Health score: '
      '${state['health_score']}; urgency: ${state['urgency']}.',
    );
    final evidence = <Evidence>[
      stateEvidence,
      if (recent != null)
        entry(
          recent,
          'Telemetry at ${recent['timestamp']}: '
          '${recent.entries.where((e) => e.value is num).map((e) => '${e.key}=${e.value}').join(', ')}',
        ),
      if (recent != null &&
          oldest != null &&
          recentTime is String &&
          oldestTime is String &&
          recentTime != oldestTime &&
          comparison.isNotEmpty)
        Evidence(
          '${oldest['_source']}; ${recent['_source']}',
          'Included telemetry samples from $oldestTime to '
              '$recentTime. ${comparison.join(', ')}.',
        ),
      ?matchingOpenEvidence,
      for (final r in otherReportEvents) eventEvidence(r),
      for (final r in latest('Maintenance_History', 'opened_at').take(2))
        entry(
          r,
          '${r['opened_at']}: ${r['action']} · ${r['result']}',
          'work_order_id',
        ),
      for (final r in docs) entry(r, '${r['content']}', 'doc_id'),
      if (workflow != null)
        entry(
          workflow,
          'Historical evidence workflow. ${workflow['safe_evidence_workflow']}',
          'case_id',
        ),
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
      nextCheck: '${state['recommended_next_check']}',
      stateEvidence: stateEvidence,
      matchingOpenEvidence: matchingOpenEvidence,
      mappingNotice: '${_json['mappingNotice']}',
      evidence: evidence,
      hypotheses: [
        for (final r in cases)
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
