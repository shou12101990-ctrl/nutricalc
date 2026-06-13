import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/clinical_event.dart';
import 'package:nutrition_flutter_app/clinical/source_tier.dart';

void main() {
  group('ClinicalEvent serialization', () {
    test('restores open-ended CRRT start with null endDay', () {
      const event = ClinicalEvent(
        id: 'crrt-start',
        type: ClinicalEventType.rrtStart,
        startDay: 8,
        rrtModality: RrtModality.crrt,
      );

      final restored = ClinicalEvent.fromMap(event.toMap());

      expect(restored.id, 'crrt-start');
      expect(restored.type, ClinicalEventType.rrtStart);
      expect(restored.startDay, 8);
      expect(restored.endDay, isNull);
      expect(restored.isOpenEnded, isTrue);
      expect(restored.rrtModality, RrtModality.crrt);
    });

    test('keeps EN hold parameters as Map<String, Object?>', () {
      const event = ClinicalEvent(
        id: 'en-hold',
        type: ClinicalEventType.enHold,
        startDay: 7,
        endDay: 10,
        parameters: {
          'hold_rate_ml_h': 20,
          'reason': 'high_grv',
          'requires_review': true,
        },
      );

      final restored = ClinicalEvent.fromMap(event.toMap());

      expect(restored.parameters, isA<Map<String, Object?>>());
      expect(restored.parameters['hold_rate_ml_h'], 20);
      expect(restored.parameters['reason'], 'high_grv');
      expect(restored.parameters['requires_review'], isTrue);
    });

    test('round-trips sourceTier by key', () {
      const event = ClinicalEvent(
        id: 'guideline-event',
        type: ClinicalEventType.refeedingHypophosphatemia,
        startDay: 3,
        sourceTier: SourceTier.guidelineObligation,
      );

      final map = event.toMap();
      final restored = ClinicalEvent.fromMap(map);

      expect(map['sourceTier'], 'guideline_obligation');
      expect(restored.sourceTier, SourceTier.guidelineObligation);
    });

    test('accepts enum names and safely ignores unknown optional fields', () {
      final restored = ClinicalEvent.fromMap({
        'id': 'legacy',
        'type': 'rrtStart',
        'startDay': 4,
        'endDay': null,
        'severity': 'unknown_severity',
        'sourceTier': 'unknown_source_tier',
        'rrtModality': 'crrt',
        'parameters': {
          'next_modality': 'SLED',
          42: 'numeric key',
        },
        'legacyExtra': 'ignored',
      });

      expect(restored.type, ClinicalEventType.rrtStart);
      expect(restored.severity, EventSeverity.moderate);
      expect(restored.sourceTier, SourceTier.userInputEvent);
      expect(restored.rrtModality, RrtModality.crrt);
      expect(restored.endDay, isNull);
      expect(restored.parameters['next_modality'], 'SLED');
      expect(restored.parameters['42'], 'numeric key');
    });
  });
}
