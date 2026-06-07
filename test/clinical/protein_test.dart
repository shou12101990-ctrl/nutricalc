import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/protein.dart';

void main() {
  test('非肥満: feedingWeight × g/kg', () {
    // 男170 72kg(正常)→体重72、×1.3
    expect(
        targetProtein(
            actualKg: 72, heightCm: 170, isMale: true, gramPerKg: 1.3),
        closeTo(72 * 1.3, 0.01));
  });

  test('肥満(BMI≥30): 理想体重 × g/kg', () {
    // 男170 95kg(BMI32.9) IBW66.2、×2.0
    expect(
        targetProtein(
            actualKg: 95, heightCm: 170, isMale: true, gramPerKg: 2.0),
        closeTo(66.2 * 2.0, 0.1));
  });

  test('proteinTargetWeight 肥満→IBW', () {
    expect(proteinTargetWeight(actualKg: 95, heightCm: 170, isMale: true),
        closeTo(66.2, 0.1));
  });

  test('obeseProteinGoalPerKg: BMI30-40→2.0, ≥40→2.5, 非肥満→null', () {
    expect(obeseProteinGoalPerKg(35), 2.0);
    expect(obeseProteinGoalPerKg(42), 2.5);
    expect(obeseProteinGoalPerKg(25), isNull);
  });
}
