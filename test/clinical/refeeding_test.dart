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
}
