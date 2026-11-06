import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'asset_data.dart';

class InspectionDetails extends StatefulWidget {
  const InspectionDetails({
    super.key,
    required this.objectId,
    required this.equipmentType,
    required this.arrived,
  });
  final String objectId;
  final String equipmentType;
  final bool arrived;

  @override
  State<InspectionDetails> createState() => _InspectionDetailsState();
}

class _InspectionDetailsState extends State<InspectionDetails> {
  late final _data = rootBundle
      .loadString('assets/valmet/asset-data.json')
      .then(AssetData.fromJson);

  @override
  Widget build(BuildContext context) => FutureBuilder<AssetData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Text(
          'Asset evidence unavailable. Import the supplied workbook to enable inspection details.',
        );
      }
      if (!snapshot.hasData) return const SizedBox.shrink();
      final diagnosis = snapshot.data!.forObject(
        widget.objectId,
        equipmentType: widget.equipmentType,
      );
      if (diagnosis == null) {
        return const Text('No workbook asset is mapped to this scene object.');
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${diagnosis.tag} · ${diagnosis.condition}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(diagnosis.mappingNotice),
              Text('Workbook snapshot: ${diagnosis.updatedAt}'),
              if (!widget.arrived)
                const Text(
                  'Reach the service position in the 3D model to review inspection evidence.',
                ),
              if (widget.arrived) ...[
                const SizedBox(height: 12),
                Text('Observation: ${diagnosis.observation}'),
                Text(
                  'Workbook model confidence: ${diagnosis.confidence == null ? 'unavailable' : '${(diagnosis.confidence! * 100).round()}%'}; this is supplied metadata.',
                ),
                Text('Next verification: ${diagnosis.nextCheck}'),
                const Text(
                  'Local evidence summary. A cause has not been confirmed.',
                ),
                for (final issue in diagnosis.qualityIssues)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Data quality: ${issue.text}'),
                    subtitle: Text(issue.reference),
                  ),
                ExpansionTile(
                  title: const Text('Evidence and source references'),
                  children: [
                    for (final e in diagnosis.evidence)
                      ListTile(
                        title: Text(e.text),
                        subtitle: Text(e.reference),
                      ),
                  ],
                ),
                ExpansionTile(
                  title: const Text('Related historical hypotheses'),
                  children: diagnosis.hypotheses.isEmpty
                      ? [
                          const ListTile(
                            title: Text(
                              'No matching historical case supplied.',
                            ),
                          ),
                        ]
                      : [
                          for (final e in diagnosis.hypotheses)
                            ListTile(
                              title: Text(e.text),
                              subtitle: Text(e.reference),
                            ),
                        ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
