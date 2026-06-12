import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/refeeding.dart';

void main() {
  group('refeedingTier (NICE CG32)', () {
    test('BMI<14 → EXTREME', () {
      expect(refeedingTier(bmi: 13), RefeedingTier.extreme);
    });
    test('絶食>15日 → EXTREME', () {
      expect(refeedingTier(daysNoIntake: 16), RefeedingTier.extreme);
    });
    test('BMI<16 単独 → HIGH（ONE-OR-MORE）', () {
      expect(refeedingTier(bmi: 15), RefeedingTier.high);
    });
    test('絶食>10日 単独 → HIGH', () {
      expect(refeedingTier(daysNoIntake: 11), RefeedingTier.high);
    });
    test('BMI18 + 絶食6日 → HIGH（TWO-OR-MORE）', () {
      expect(refeedingTier(bmi: 18, daysNoIntake: 6), RefeedingTier.high);
    });
    test('BMI24 + 絶食3日 → NONE', () {
      expect(refeedingTier(bmi: 24, daysNoIntake: 3), RefeedingTier.none);
    });
    test('電解質低値 単独 → HIGH', () {
      expect(refeedingTier(lowElectrolyte: true), RefeedingTier.high);
    });
    test('電解質未測定(null)は該当せず', () {
      expect(refeedingTier(bmi: 24, lowElectrolyte: null), RefeedingTier.none);
    });
  });

  group('kcal/kg ramp', () {
    test('EXTREME = [5,10,15,20,full]', () {
      expect(refeedingKcalPerKgRamp(RefeedingTier.extreme, 30),
          [5, 10, 15, 20, 30]);
    });
    test('HIGH = [10,15,20,full]', () {
      expect(refeedingKcalPerKgRamp(RefeedingTier.high, 25), [10, 15, 20, 25]);
    });
    test('NONE = [full]', () {
      expect(refeedingKcalPerKgRamp(RefeedingTier.none, 25), [25]);
    });
  });

  group('refeedingCapKcalPerKg', () {
    test('HIGH day1=10, day2=15, day4=full25, day10=full', () {
      expect(refeedingCapKcalPerKg(RefeedingTier.high, 1, 25), 10);
      expect(refeedingCapKcalPerKg(RefeedingTier.high, 2, 25), 15);
      expect(refeedingCapKcalPerKg(RefeedingTier.high, 4, 25), 25);
      expect(refeedingCapKcalPerKg(RefeedingTier.high, 10, 25), 25);
    });
    test('full を超えない（fullが小さい時）', () {
      expect(refeedingCapKcalPerKg(RefeedingTier.high, 3, 18), 18);
    });
    test('NONE は常に full', () {
      expect(refeedingCapKcalPerKg(RefeedingTier.none, 1, 25), 25);
    });
  });

  group('kRefeedingCriteria (NICE構造化)', () {
    test('extreme基準は bmi_lt14 / intake_gt15d の2件', () {
      final ext = kRefeedingCriteria
          .where((c) => c.group == 'extreme')
          .map((c) => c.id)
          .toSet();
      expect(ext, {'bmi_lt14', 'intake_gt15d'});
    });
    test('major基準は4件・minor基準は4件', () {
      expect(kRefeedingCriteria.where((c) => c.group == 'major').length, 4);
      expect(kRefeedingCriteria.where((c) => c.group == 'minor').length, 4);
    });
    test('全基準idがユニーク', () {
      final ids = kRefeedingCriteria.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });
    test('refeedingCriterionById で label/group が引ける', () {
      expect(refeedingCriterionById('bmi_lt16')?.group, 'major');
      expect(refeedingCriterionById('alcohol_or_drugs')?.group, 'minor');
      expect(refeedingCriterionById('unknown'), isNull);
    });
  });

  group('refeedingTierFromFlags', () {
    test('major1つ → HIGH', () {
      expect(refeedingTierFromFlags({'bmi_lt16'}), RefeedingTier.high);
      expect(refeedingTierFromFlags({'low_electrolyte'}), RefeedingTier.high);
    });
    test('minor2つ → HIGH', () {
      expect(refeedingTierFromFlags({'bmi_lt18_5', 'wtloss_gt10'}),
          RefeedingTier.high);
      expect(
          refeedingTierFromFlags({'intake_lt_gt5d', 'alcohol_or_drugs'}),
          RefeedingTier.high);
    });
    test('minor1つのみ → NONE', () {
      expect(refeedingTierFromFlags({'bmi_lt18_5'}), RefeedingTier.none);
      expect(refeedingTierFromFlags({'alcohol_or_drugs'}), RefeedingTier.none);
    });
    test('extreme条件 → EXTREME（majorも揃っていても優先）', () {
      expect(refeedingTierFromFlags({'bmi_lt14'}), RefeedingTier.extreme);
      expect(refeedingTierFromFlags({'intake_gt15d'}), RefeedingTier.extreme);
      // extreme該当時は同時にmajorが立っていてもextremeが支配
      expect(
          refeedingTierFromFlags(
              {'bmi_lt14', 'bmi_lt16', 'bmi_lt18_5', 'intake_gt15d'}),
          RefeedingTier.extreme);
    });
    test('空集合 → NONE', () {
      expect(refeedingTierFromFlags({}), RefeedingTier.none);
    });
    test('未知のidは無視 → NONE', () {
      expect(refeedingTierFromFlags({'unknown', 'foo'}), RefeedingTier.none);
    });
  });

  group('autoRefeedingFlags（境界）', () {
    test('BMI<14 は3つのBMIフラグを全て立てる', () {
      expect(autoRefeedingFlags(bmi: 13),
          {'bmi_lt14', 'bmi_lt16', 'bmi_lt18_5'});
    });
    test('BMI=15 は bmi_lt16/bmi_lt18_5', () {
      expect(autoRefeedingFlags(bmi: 15), {'bmi_lt16', 'bmi_lt18_5'});
    });
    test('BMI=17 は bmi_lt18_5 のみ', () {
      expect(autoRefeedingFlags(bmi: 17), {'bmi_lt18_5'});
    });
    test('BMI=18.5 ちょうどは該当なし（<で判定）', () {
      expect(autoRefeedingFlags(bmi: 18.5), <String>{});
    });
    test('絶食16日 は全絶食フラグ', () {
      expect(autoRefeedingFlags(daysNoIntake: 16),
          {'intake_gt15d', 'intake_lt_gt10d', 'intake_lt_gt5d'});
    });
    test('絶食11日 は intake_lt_gt10d/intake_lt_gt5d', () {
      expect(autoRefeedingFlags(daysNoIntake: 11),
          {'intake_lt_gt10d', 'intake_lt_gt5d'});
    });
    test('絶食6日 は intake_lt_gt5d のみ', () {
      expect(autoRefeedingFlags(daysNoIntake: 6), {'intake_lt_gt5d'});
    });
    test('絶食5日 ちょうどは該当なし（>で判定）', () {
      expect(autoRefeedingFlags(daysNoIntake: 5), <String>{});
    });
    test('null入力は空集合', () {
      expect(autoRefeedingFlags(), <String>{});
    });
    test('autoフラグを refeedingTierFromFlags に流すと従来BMI判定と一致', () {
      // BMI15 → bmi_lt16(major) で HIGH
      expect(refeedingTierFromFlags(autoRefeedingFlags(bmi: 15)),
          RefeedingTier.high);
      // 絶食16日 → intake_gt15d(extreme)
      expect(refeedingTierFromFlags(autoRefeedingFlags(daysNoIntake: 16)),
          RefeedingTier.extreme);
      // BMI18 + 絶食6日 → bmi_lt18_5 + intake_lt_gt5d = minor2 → HIGH
      final f = autoRefeedingFlags(bmi: 18, daysNoIntake: 6);
      expect(refeedingTierFromFlags(f), RefeedingTier.high);
    });
  });
}
