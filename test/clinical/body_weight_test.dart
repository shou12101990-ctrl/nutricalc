import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/body_weight.dart';

void main() {
  group('bmiOf', () {
    test('170cm 70kg ≒ 24.2', () {
      expect(bmiOf(70, 170), closeTo(24.22, 0.01));
    });
  });

  group('idealBodyWeight (Devine, 短身ガード)', () {
    test('男 170cm = 50 + 0.9×18 = 66.2', () {
      expect(idealBodyWeight(isMale: true, heightCm: 170), closeTo(66.2, 0.001));
    });
    test('女 160cm = 45.5 + 0.9×8 = 52.7', () {
      expect(idealBodyWeight(isMale: false, heightCm: 160), closeTo(52.7, 0.001));
    });
    test('短身 140cm はBMI-22換算 = 22×1.4² = 43.12', () {
      expect(
          idealBodyWeight(isMale: false, heightCm: 140), closeTo(43.12, 0.01));
    });
    test('151cm（<152）もBMI-22換算で破綻しない', () {
      final ibw = idealBodyWeight(isMale: true, heightCm: 151);
      expect(ibw, greaterThan(40)); // Devine素の50+0.9×(-1)=49.1ではなくBMI22
      expect(ibw, closeTo(22 * 1.51 * 1.51, 0.01));
    });
  });

  group('adjustedBodyWeight (factor 0.25)', () {
    test('実100 / IBW66.2 → 66.2 + 0.25×33.8 = 74.65', () {
      expect(adjustedBodyWeight(actualKg: 100, ibwKg: 66.2),
          closeTo(74.65, 0.001));
    });
  });

  group('feedingWeight 決定木', () {
    test('るい痩(実<IBW)→実体重', () {
      // 男170 IBW66.2、実50
      expect(feedingWeight(actualKg: 50, heightCm: 170, isMale: true),
          closeTo(50, 0.001));
    });
    test('過体重(BMI<30 かつ 実>1.2×IBW)→補正体重', () {
      // 男170 IBW66.2、1.2×=79.44、実85(BMI29.4)→ ABW=66.2+0.25×18.8=70.9
      expect(feedingWeight(actualKg: 85, heightCm: 170, isMale: true),
          closeTo(70.9, 0.01));
    });
    test('正常域(実≦1.2×IBW)→実体重', () {
      // 男170、実72(BMI24.9, <79.44)→実体重
      expect(feedingWeight(actualKg: 72, heightCm: 170, isMale: true),
          closeTo(72, 0.001));
    });
    test('肥満 BMI30–50 →実体重', () {
      // 男170 実95(BMI32.9)→実体重(kcal/kgは別途11-14)
      expect(feedingWeight(actualKg: 95, heightCm: 170, isMale: true),
          closeTo(95, 0.001));
    });
    test('高度肥満 BMI>50 →IBW', () {
      // 男170 実150(BMI51.9)→IBW66.2
      expect(feedingWeight(actualKg: 150, heightCm: 170, isMale: true),
          closeTo(66.2, 0.001));
    });
  });

  group('weightBasisOf ラベル', () {
    test('過体重→補正体重ラベル', () {
      final b = weightBasisOf(actualKg: 85, heightCm: 170, isMale: true);
      expect(b.label, '補正体重');
      expect(b.feedingKg, closeTo(70.9, 0.1));
    });
    test('正常→実体重ラベル', () {
      final b = weightBasisOf(actualKg: 72, heightCm: 170, isMale: true);
      expect(b.label, '実体重');
    });
  });
}
