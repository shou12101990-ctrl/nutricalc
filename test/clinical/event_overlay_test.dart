import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/clinical_event.dart';
import 'package:nutrition_flutter_app/clinical/event_overlay.dart';

ClinicalEvent rrtStart(int day, RrtModality m, {int? end, String id = 'rrt'}) =>
    ClinicalEvent(
        id: id,
        type: ClinicalEventType.rrtStart,
        startDay: day,
        endDay: end,
        rrtModality: m);

ClinicalEvent rrtStop(int day, {String? next, String id = 'stop'}) =>
    ClinicalEvent(
        id: id,
        type: ClinicalEventType.rrtStop,
        startDay: day,
        parameters: {'next_modality': next});

void main() {
  group('activeRrtModalityOnDay', () {
    test('CRRT day8開始・停止なし → day8以降ずっとCRRT(§24.6-1)', () {
      final ev = [rrtStart(8, RrtModality.crrt)];
      expect(activeRrtModalityOnDay(ev, 7), isNull);
      expect(activeRrtModalityOnDay(ev, 8), RrtModality.crrt);
      expect(activeRrtModalityOnDay(ev, 30), RrtModality.crrt);
    });

    test('CRRT day8開始・day15停止(next none) → day16以降はnull(§24.6-2)', () {
      final ev = [
        rrtStart(8, RrtModality.crrt),
        rrtStop(16, next: 'none'),
      ];
      expect(activeRrtModalityOnDay(ev, 15), RrtModality.crrt);
      expect(activeRrtModalityOnDay(ev, 16), isNull);
      expect(activeRrtModalityOnDay(ev, 20), isNull);
    });

    test('CRRT停止→IRRT遷移 → 遷移後はIRRT(§24.6-3)', () {
      final ev = [
        rrtStart(8, RrtModality.crrt),
        rrtStop(16, next: 'IRRT'),
      ];
      expect(activeRrtModalityOnDay(ev, 15), RrtModality.crrt);
      expect(activeRrtModalityOnDay(ev, 16), RrtModality.irrt);
    });

    test('endDay設定の rrt_start は期間後に終了', () {
      final ev = [rrtStart(5, RrtModality.crrt, end: 9)];
      expect(activeRrtModalityOnDay(ev, 9), RrtModality.crrt);
      expect(activeRrtModalityOnDay(ev, 10), isNull);
    });

    test('孤立 rrt_stop(先行startなし) はRRTを捏造しない(codex bug A)', () {
      final ev = [rrtStop(5, next: 'IRRT')];
      expect(activeRrtModalityOnDay(ev, 6), isNull);
    });
  });

  group('CRRT継続日数（停止→再開でリセット・codex bug B）', () {
    test('単一runは開始日起算で≥14日Cuノート', () {
      final o = resolveDayOverlay([rrtStart(2, RrtModality.crrt)], 15);
      expect(o.notes.any((n) => n.contains('Cu') || n.contains('銅')), isTrue);
    });

    test('停止→再開後は再開日起算（最古startで早まらない）', () {
      final ev = [
        rrtStart(2, RrtModality.crrt, id: 's1'),
        rrtStop(6, next: 'none', id: 'stop1'),
        rrtStart(10, RrtModality.crrt, id: 's2'),
      ];
      // day12 は再開(day10)から3日目 → Cuノート出ない
      final d12 = resolveDayOverlay(ev, 12);
      expect(d12.activeRrtModality, RrtModality.crrt);
      expect(d12.notes.any((n) => n.contains('Cu') || n.contains('銅')), isFalse);
      // day23 は再開から14日目 → Cuノート出る
      final d23 = resolveDayOverlay(ev, 23);
      expect(d23.notes.any((n) => n.contains('Cu') || n.contains('銅')), isTrue);
    });
  });

  group('RRT停止→次モダリティ不明（要レビュー・§16.6）', () {
    test('unknown停止日にレビューノート + モダリティnull', () {
      final ev = [
        rrtStart(2, RrtModality.crrt),
        rrtStop(8, next: 'unknown'),
      ];
      final o = resolveDayOverlay(ev, 8);
      expect(o.activeRrtModality, isNull);
      expect(o.notes.any((n) => n.contains('不明')), isTrue);
    });
  });

  group('NOMI + CRRT 共存（codex提案の明示テスト）', () {
    test('NOMIで経腸遮断しつつCRRTのprotein/microは生きる', () {
      final ev = [
        rrtStart(8, RrtModality.crrt),
        ClinicalEvent(
            id: 'n', type: ClinicalEventType.suspectedNomi, startDay: 8),
      ];
      final o = resolveDayOverlay(ev, 9);
      expect(o.enteralBlocked, isTrue); // NOMI: 経腸遮断
      expect(o.route, RouteEffect.npo);
      expect(o.protein, ProteinEffect.crrtTarget); // CRRT protein は生きる
      expect(o.activeRrtModality, RrtModality.crrt);
      expect(o.micronutrient.contains(MicronutrientEffect.additionalObligation),
          isTrue);
    });
  });

  group('RRT protein band（§24.5）', () {
    test('IRRT 1.3–1.5 / SLED 1.5–1.7 / CRRT 1.5–1.7', () {
      expect(RrtModality.irrt.proteinBand, (min: 1.3, max: 1.5));
      expect(RrtModality.sled.proteinBand, (min: 1.5, max: 1.7));
      expect(RrtModality.crrt.proteinBand, (min: 1.5, max: 1.7));
    });
    test('SLEDはIRRTでなくCRRT寄りの protein effect(§24.6-4)', () {
      final o = resolveDayOverlay([rrtStart(3, RrtModality.sled)], 5);
      expect(o.activeRrtModality, RrtModality.sled);
      expect(o.protein, ProteinEffect.sledTarget);
    });
  });

  group('resolveDayOverlay 単一イベント', () {
    test('EN hold → route=holdEn, energy=cap, 維持カバレッジ要(§24.6-5)', () {
      final o = resolveDayOverlay([
        ClinicalEvent(
            id: 'h',
            type: ClinicalEventType.enHold,
            startDay: 7,
            endDay: 10)
      ], 8);
      expect(o.route, RouteEffect.holdEn);
      expect(o.energy, EnergyEffect.cap);
      expect(o.micronutrient.contains(MicronutrientEffect.maintenanceRequired),
          isTrue);
    });

    test('EN holdは期間外(future template)では適用されない(§24.1-5)', () {
      final ev = [
        ClinicalEvent(
            id: 'h',
            type: ClinicalEventType.enHold,
            startDay: 7,
            endDay: 10)
      ];
      final o = resolveDayOverlay(ev, 11);
      expect(o.route, RouteEffect.none);
      expect(o.hasOverlay, isFalse);
    });

    test('suspected NOMI → npo + 経腸除外, enteralBlocked(§24.6-6)', () {
      final o = resolveDayOverlay([
        ClinicalEvent(
            id: 'n', type: ClinicalEventType.suspectedNomi, startDay: 4)
      ], 5);
      expect(o.route, RouteEffect.npo);
      expect(o.productFilters.contains(ProductFilterEffect.excludeEnteral),
          isTrue);
      expect(o.enteralBlocked, isTrue);
    });

    test('cholestasis → Mn-free + 毒性ガード(§24.6-8)', () {
      final o = resolveDayOverlay([
        ClinicalEvent(
            id: 'c',
            type: ClinicalEventType.cholestasisOrLiverDysfunction,
            startDay: 2)
      ], 3);
      expect(o.productFilters.contains(ProductFilterEffect.mnFreeTrace), isTrue);
      expect(
          o.micronutrient.contains(MicronutrientEffect.toxicityGuard), isTrue);
    });

    test('fluid overload → fluid cap + 高濃度低容量(§24.6-9)', () {
      final o = resolveDayOverlay([
        ClinicalEvent(
            id: 'f', type: ClinicalEventType.fluidOverload, startDay: 1)
      ], 2);
      expect(o.fluid, FluidEffect.cap);
      expect(o.productFilters.contains(ProductFilterEffect.energyDenseLowVolume),
          isTrue);
    });
  });

  group('優先度・重ね合わせ', () {
    test('NOMI は EN hold を上書き(route=npo)（§14, §24.6-6）', () {
      final ev = [
        ClinicalEvent(
            id: 'h', type: ClinicalEventType.enHold, startDay: 1, endDay: 10),
        ClinicalEvent(
            id: 'n', type: ClinicalEventType.suspectedNomi, startDay: 5),
      ];
      final o = resolveDayOverlay(ev, 6);
      expect(o.route, RouteEffect.npo); // 最も制限的
      expect(o.activeEvents.first.type, ClinicalEventType.suspectedNomi); // 優先度1
    });

    test('CRRT + refeeding低P + EN hold は全次元で共存(§24.6-10)', () {
      final ev = [
        rrtStart(8, RrtModality.crrt),
        ClinicalEvent(
            id: 'rp',
            type: ClinicalEventType.refeedingHypophosphatemia,
            startDay: 8,
            endDay: 10),
        ClinicalEvent(
            id: 'h', type: ClinicalEventType.enHold, startDay: 7, endDay: 12),
      ];
      final o = resolveDayOverlay(ev, 8);
      expect(o.protein, ProteinEffect.crrtTarget); // CRRTが支配
      expect(o.energy, EnergyEffect.restrictFor48h); // refeeding低Pが energy
      expect(o.route, RouteEffect.holdEn); // EN hold
      expect(o.electrolyte, ElectrolyteEffect.supplement); // refeeding補充
      expect(o.micronutrient.contains(MicronutrientEffect.additionalObligation),
          isTrue); // CRRT
      expect(o.micronutrient.contains(MicronutrientEffect.maintenanceRequired),
          isTrue); // refeeding/EN hold
      expect(o.activeRrtModality, RrtModality.crrt);
    });

    test('CRRTは安定CKDの腎制限(protein)を抑制（renalイベントよりRRTが支配・§16）', () {
      final ev = [
        rrtStart(8, RrtModality.crrt),
        // BUN上昇→reviewOnly(優先度8)。CRRT(優先度3)が支配すべき。
        ClinicalEvent(
            id: 'bun',
            type: ClinicalEventType.bunRiseAfterFeeding,
            startDay: 8),
      ];
      final o = resolveDayOverlay(ev, 9);
      expect(o.protein, ProteinEffect.crrtTarget);
    });
  });

  group('KRT液カロリー情報ノート（§17.1）', () {
    test('CRRT稼働 & カロリー未入力 → 情報ノート', () {
      final o = resolveDayOverlay([rrtStart(2, RrtModality.crrt)], 3,
          rrtCalorieUnknown: true);
      expect(o.notes.any((n) => n.contains('KRT')), isTrue);
    });
    test('カロリー入力済みならノートを出さない', () {
      final o = resolveDayOverlay([rrtStart(2, RrtModality.crrt)], 3,
          rrtCalorieUnknown: false);
      expect(o.notes.any((n) => n.contains('KRT')), isFalse);
    });
    test('CRRT≥14日で銅モニタのノート', () {
      final o = resolveDayOverlay([rrtStart(2, RrtModality.crrt)], 15);
      expect(o.notes.any((n) => n.contains('Cu') || n.contains('銅')), isTrue);
    });
  });

  group('優先度定義（§14）', () {
    test('NOMI<refeeding<RRT<fluid<肝<EN不耐<EN hold<BUN', () {
      int p(ClinicalEventType t) => defaultPriorityFor(t);
      expect(p(ClinicalEventType.suspectedNomi), 1);
      expect(p(ClinicalEventType.refeedingHypophosphatemia), 2);
      expect(p(ClinicalEventType.rrtStart), 3);
      expect(p(ClinicalEventType.fluidOverload), 4);
      expect(p(ClinicalEventType.cholestasisOrLiverDysfunction), 5);
      expect(p(ClinicalEventType.enIntolerance), 6);
      expect(p(ClinicalEventType.enHold), 7);
      expect(p(ClinicalEventType.bunRiseAfterFeeding), 8);
    });
  });

  group('resolveTimeline', () {
    test('全日のオーバーレイを返す', () {
      final t = resolveTimeline([rrtStart(3, RrtModality.crrt)], 5);
      expect(t.length, 5);
      expect(t[1].activeRrtModality, isNull); // day2
      expect(t[2].activeRrtModality, RrtModality.crrt); // day3
    });
  });
}
