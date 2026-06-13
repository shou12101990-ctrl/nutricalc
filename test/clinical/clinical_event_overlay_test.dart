import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/clinical_event.dart';
import 'package:nutrition_flutter_app/clinical/event_overlay.dart';

void main() {
  group('RRT event resolver', () {
    test('open-ended CRRT start persists until timeline end', () {
      const events = [
        ClinicalEvent(
          id: 'crrt-start',
          type: ClinicalEventType.rrtStart,
          startDay: 8,
          rrtModality: RrtModality.crrt,
        ),
      ];

      expect(activeRrtModalityOnDay(events, 7), isNull);
      expect(activeRrtModalityOnDay(events, 8), RrtModality.crrt);
      expect(activeRrtModalityOnDay(events, 30), RrtModality.crrt);
    });

    test('CRRT→IRRT切替はモダリティ別の開始＋期間で表現', () {
      const events = [
        ClinicalEvent(
          id: 'crrt-start',
          type: ClinicalEventType.rrtStart,
          startDay: 8,
          endDay: 14,
          rrtModality: RrtModality.crrt,
        ),
        ClinicalEvent(
          id: 'irrt-start',
          type: ClinicalEventType.rrtStart,
          startDay: 15,
          rrtModality: RrtModality.irrt,
        ),
      ];

      expect(activeRrtModalityOnDay(events, 14), RrtModality.crrt);
      expect(activeRrtModalityOnDay(events, 15), RrtModality.irrt);
      expect(activeRrtModalityOnDay(events, 20), RrtModality.irrt);
    });

    test('SLED start uses SLED/PIKRT-like protein effect', () {
      const events = [
        ClinicalEvent(
          id: 'sled-start',
          type: ClinicalEventType.rrtStart,
          startDay: 3,
          rrtModality: RrtModality.sled,
        ),
      ];

      final overlay = resolveDayOverlay(events, 5);
      expect(overlay.activeRrtModality, RrtModality.sled);
      expect(overlay.protein, ProteinEffect.sledTarget);
      expect(overlay.micronutrient,
          contains(MicronutrientEffect.additionalObligation));
    });
  });

  group('Event overlay composition', () {
    test('CRRT + refeeding hypophosphatemia + EN hold coexist by dimension',
        () {
      const events = [
        ClinicalEvent(
          id: 'crrt',
          type: ClinicalEventType.rrtStart,
          startDay: 8,
          rrtModality: RrtModality.crrt,
        ),
        ClinicalEvent(
          id: 'refeed-p',
          type: ClinicalEventType.refeedingHypophosphatemia,
          startDay: 8,
          endDay: 9,
          parameters: {'phosphate_value': 1.8},
        ),
        ClinicalEvent(
          id: 'hold',
          type: ClinicalEventType.enHold,
          startDay: 8,
          endDay: 10,
          parameters: {'hold_rate_ml_h': 20},
        ),
      ];

      final overlay = resolveDayOverlay(events, 8);
      expect(overlay.route, RouteEffect.holdEn);
      expect(overlay.energy, EnergyEffect.restrictFor48h);
      expect(overlay.protein, ProteinEffect.crrtTarget);
      expect(overlay.fluid, FluidEffect.netBalanceAware);
      expect(overlay.electrolyte, ElectrolyteEffect.supplement);
      expect(overlay.micronutrient,
          contains(MicronutrientEffect.additionalObligation));
      expect(overlay.micronutrient,
          contains(MicronutrientEffect.maintenanceRequired));
    });

    test('suspected NOMI blocks enteral route and product filter', () {
      const events = [
        ClinicalEvent(
          id: 'nomi',
          type: ClinicalEventType.recurrentNpo,
          startDay: 2,
          severity: EventSeverity.severe,
        ),
      ];

      final overlay = resolveDayOverlay(events, 2);
      expect(overlay.enteralBlocked, isTrue);
      expect(overlay.route, RouteEffect.npo);
      expect(
          overlay.productFilters, contains(ProductFilterEffect.excludeEnteral));
    });
  });
}
