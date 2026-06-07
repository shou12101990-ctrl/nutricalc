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
}
