import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/conditions.dart';

void main() {
  test('病態なし → null（既存値を変更しない）', () {
    expect(resolveCoeff([]), isNull);
    expect(resolveCoeff(['dysphagia']), isNull); // 係数なし病態
  });

  test('単一: 腎不全保存期 → NPC/N350・脂質0.9・糖質制限なし', () {
    final r = resolveCoeff(['renal'])!;
    expect(r.npcN, 350);
    expect(r.lipidGPerKg, 0.9);
    expect(r.glucoseRestrict, isFalse);
  });

  test('複合: 腎不全保存期+重症 → NPC/N=max(350)・脂質=min(0.9)・糖質制限=OR(true)', () {
    final r = resolveCoeff(['renal', 'critical'])!;
    expect(r.npcN, 350); // 最もタンパク節約
    expect(r.lipidGPerKg, 0.9);
    expect(r.glucoseRestrict, isTrue); // criticalで制限
  });

  test('脂質は1.0でクランプ', () {
    final r = resolveCoeff(['liver'])!; // lipid 1.0
    expect(r.lipidGPerKg, lessThanOrEqualTo(1.0));
  });

  test('タンパク範囲サジェスト', () {
    final ranges = proteinRangesFor(['renal', 'critical']);
    expect(ranges.length, 2);
    final renal = ranges.firstWhere((c) => c.id == 'renal');
    expect(renal.proteinMinPerKg, 0.6);
    expect(renal.proteinMaxPerKg, 0.8);
  });

  test('共通範囲: 重ならなければnull（腎0.6-0.8 と 重症1.2-2.0）', () {
    expect(intersectedProteinRange(['renal', 'critical']), isNull);
  });

  test('共通範囲: 重なる例（肝1.0-1.2 と 透析1.0-1.2）', () {
    final r = intersectedProteinRange(['liver', 'renal_dialysis'])!;
    expect(r.min, 1.0);
    expect(r.max, 1.2);
  });

  group('renalProteinTarget (ESPEN腎疾患GL)', () {
    test('CKD単独(急性/重症なし・RRTなし) → 0.6–0.8・要review', () {
      final t = renalProteinTarget(['renal'])!;
      expect(t.minPerKg, 0.6);
      expect(t.maxPerKg, 0.8);
      expect(t.requiresReview, isTrue);
    });
    test('AKI単独(急性/重症なし) → 0.8–1.0', () {
      final t = renalProteinTarget(['aki'])!;
      expect(t.minPerKg, 0.8);
      expect(t.maxPerKg, 1.0);
    });
    test('CKD+重症(RRTなし) → 1.0→1.3 漸増', () {
      final t = renalProteinTarget(['renal', 'critical'])!;
      expect(t.minPerKg, 1.0);
      expect(t.maxPerKg, 1.3);
      expect(t.progressive, isTrue);
    });
    test('間欠RRT(renal_dialysis) → 1.3–1.5', () {
      final t = renalProteinTarget(['renal_dialysis'])!;
      expect(t.minPerKg, 1.3);
      expect(t.maxPerKg, 1.5);
    });
    test('CRRT → 1.5–1.7（criticalより優先=蛋白を下げない）', () {
      final t = renalProteinTarget(['renal', 'critical', 'crrt'])!;
      expect(t.minPerKg, 1.5);
      expect(t.maxPerKg, 1.7);
    });
    test('腎修飾なし → null', () {
      expect(renalProteinTarget(['liver']), isNull);
      expect(renalProteinTarget([]), isNull);
    });
    test('effectiveProteinPerKg: 腎は代表値(CRRT=1.6), 無しはfallback', () {
      expect(effectiveProteinPerKg(['crrt'], 1.5), closeTo(1.6, 1e-9));
      expect(effectiveProteinPerKg([], 1.5), 1.5);
    });
    test('effectiveProteinPerKg: 漸増は到達点(1.3)', () {
      expect(
          effectiveProteinPerKg(['renal', 'critical'], 1.5), closeTo(1.3, 1e-9));
    });
  });

  group('CkrtObligation / glutamine', () {
    test('CKRT obligation: crrtタグで成立・モニタ/高優先/Cu>14日', () {
      expect(CkrtObligation.appliesTo(['crrt']), isTrue);
      expect(CkrtObligation.appliesTo(['renal_dialysis']), isFalse);
      expect(CkrtObligation.monitor, containsAll(['Se', 'Zn', 'Cu', 'B1']));
      expect(CkrtObligation.highPriority, ['B1', 'Se', 'Zn']);
      expect(CkrtObligation.cuReviewAfterDays, 14);
    });
    test('glutamine: 一般ICUはnull / 熱傷0.3–0.5×10–15日 / 外傷0.2–0.3×5日', () {
      expect(glutamineRecommendation(['critical']), isNull);
      final b = glutamineRecommendation(['burn'])!;
      expect(b.minPerKg, 0.3);
      expect(b.maxPerKg, 0.5);
      final t = glutamineRecommendation(['trauma'])!;
      expect(t.minPerKg, 0.2);
      expect(t.maxPerKg, 0.3);
    });
  });
}
