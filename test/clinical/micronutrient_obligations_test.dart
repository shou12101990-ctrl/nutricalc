import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/micronutrient_obligations.dart';
import 'package:nutrition_flutter_app/clinical/source_tier.dart';

void main() {
  group('A. Maintenance coverage（§24.4-1/2/3・ビタミン/trace分離）', () {
    test('PN稼働・MVI/trace未カバー → 両群red / guidelineObligation(§24.4-1)', () {
      final c = assessMaintenanceCoverage(pnActive: true);
      expect(c.vitamins, CoverageBand.red);
      expect(c.traceElements, CoverageBand.red);
      expect(c.band, CoverageBand.red);
      expect(c.sourceTier, SourceTier.guidelineObligation);
    });

    test('PN稼働・MVIのみ内蔵(フルカリック型) → ビタミンgreen/trace red', () {
      final c = assessMaintenanceCoverage(
          pnActive: true, pnContainsMvi: true);
      expect(c.vitamins, CoverageBand.green);
      expect(c.traceElements, CoverageBand.red);
      expect(c.band, CoverageBand.red); // 全体は悪い方
    });

    test('PN稼働・MVI+trace内蔵 → 両群green', () {
      final c = assessMaintenanceCoverage(
          pnActive: true, pnContainsMvi: true, pnContainsTrace: true);
      expect(c.vitamins, CoverageBand.green);
      expect(c.traceElements, CoverageBand.green);
    });

    test('full EN formula量 → green 維持充足(§24.4-2)', () {
      final c = assessMaintenanceCoverage(
          enActive: true, enFormulaVolumeFraction: 1.0);
      expect(c.band, CoverageBand.green);
    });

    test('PN+full EN量 → green（ENが維持カバー）', () {
      final c = assessMaintenanceCoverage(
          pnActive: true, enActive: true, enFormulaVolumeFraction: 1.0);
      expect(c.band, CoverageBand.green);
    });

    test('部分EN → amber 不確実(§24.4-3)', () {
      final c = assessMaintenanceCoverage(
          enActive: true, enFormulaVolumeFraction: 0.5);
      expect(c.band, CoverageBand.amber);
    });

    test('EN閾値を0.8に下げると0.8でgreen（codex整合の可変閾値）', () {
      final c = assessMaintenanceCoverage(
          enActive: true,
          enFormulaVolumeFraction: 0.8,
          fullEnFractionForGreen: 0.8);
      expect(c.band, CoverageBand.green);
    });

    test('部分EN が48–72h以上持続 → amber + 注記', () {
      final c = assessMaintenanceCoverage(
          enActive: true, enFormulaVolumeFraction: 0.5, daysOnSupport: 3);
      expect(c.band, CoverageBand.amber);
      expect(c.reason.contains('48–72h'), isTrue);
    });

    test('栄養療法なし → green（対象外）', () {
      final c = assessMaintenanceCoverage();
      expect(c.band, CoverageBand.green);
    });
  });

  group('B. Additional obligations（§24.4-4/5/7）', () {
    test('B1高リスク（refeeding+糖負荷）→ thiamine 追加義務（維持でない）(§24.4-4)', () {
      final o = additionalMicronutrientObligations(
        highOrExtremeRefeedingRisk: true,
        dextroseOrHighCarbStart: true,
      );
      final b1 = o.where((e) => e.nutrient == 'thiamine');
      expect(b1.length, 1);
      expect(b1.first.action, 'supplement_high_dose');
      expect(b1.first.sourceTier, SourceTier.guidelineObligation);
    });

    test('アルコール多飲のみでも thiamine 追加', () {
      final o = additionalMicronutrientObligations(
          alcoholUseDisorderOrSuspicion: true);
      expect(o.any((e) => e.nutrient == 'thiamine'), isTrue);
    });

    test('トリガー無し → Zn/Se は付かない（普遍でない・§24.4-5）', () {
      final o = additionalMicronutrientObligations();
      expect(o.any((e) => e.nutrient == 'zinc'), isFalse);
      expect(o.any((e) => e.nutrient == 'selenium'), isFalse);
      expect(o.isEmpty, isTrue);
    });

    test('CRRT稼働 → Se/Zn が requiresReview付きで追加(§24.4-5)', () {
      final o = additionalMicronutrientObligations(crrtOrSledActive: true);
      final se = o.firstWhere((e) => e.nutrient == 'selenium');
      final zn = o.firstWhere((e) => e.nutrient == 'zinc');
      expect(se.requiresReview, isTrue);
      expect(zn.requiresReview, isTrue);
    });

    test('創傷/熱傷 → Zn/Se 追加', () {
      final o =
          additionalMicronutrientObligations(majorWoundOrBurn: true);
      expect(o.any((e) => e.nutrient == 'zinc'), isTrue);
      expect(o.any((e) => e.nutrient == 'selenium'), isTrue);
    });

    test('CRRT≥14日 → 銅モニタ義務(§24.4-7)', () {
      final o = additionalMicronutrientObligations(crrtDurationDays: 14);
      final cu = o.firstWhere((e) => e.nutrient == 'copper');
      expect(cu.action, 'monitor_review');
    });

    test('長期PN → 銅モニタ義務', () {
      final o = additionalMicronutrientObligations(longTermPn: true);
      expect(o.any((e) => e.nutrient == 'copper'), isTrue);
    });

    test('CRRT13日では銅モニタは出ない（境界）', () {
      final o = additionalMicronutrientObligations(crrtDurationDays: 13);
      expect(o.any((e) => e.nutrient == 'copper'), isFalse);
    });
  });

  group('C. Manganese toxicity guard（§24.4-6）', () {
    test('胆汁うっ滞 → Mn-free ガード', () {
      final g = manganeseGuard(cholestasis: true);
      expect(g, isNotNull);
      expect(g!.action, 'prefer_mn_free');
      expect(g.nutrient, 'manganese');
    });

    test('長期PN → Mn-free ガード', () {
      expect(manganeseGuard(longTermPn: true), isNotNull);
    });

    test('肝/長期PNリスク無し → null', () {
      expect(manganeseGuard(), isNull);
    });
  });
}
