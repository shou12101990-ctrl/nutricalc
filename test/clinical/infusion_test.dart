import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/infusion.dart';

void main() {
  group('GIR', () {
    test('ブドウ糖300g / 60kg = 3.47 mg/kg/min', () {
      expect(gir(glucoseGramPerDay: 300, weightKg: 60), closeTo(3.472, 0.001));
    });
    test('上限5を満たす最大ブドウ糖（60kg）= 432 g/day', () {
      expect(maxGlucoseGramPerDay(weightKg: 60), closeTo(432, 0.001));
    });
    test('レベル判定: 3.5=ok, 4.5=caution, 5.5=danger', () {
      expect(girLevel(3.5), AlertLevel.ok);
      expect(girLevel(4.5), AlertLevel.caution);
      expect(girLevel(5.5), AlertLevel.danger);
    });
    test('糖質制限病態 warn=4 を渡すと4超でcaution', () {
      expect(girLevel(4.2, warn: 4.0), AlertLevel.caution);
    });
  });

  group('脂質', () {
    test('速度 50g/60kg/24h = 0.0347 g/kg/h', () {
      expect(lipidRatePerHour(lipidGramPerDay: 50, weightKg: 60),
          closeTo(0.0347, 0.001));
    });
    test('1日量 90g/60kg = 1.5 g/kg/day（上限）', () {
      expect(lipidPerDayGramPerKg(lipidGramPerDay: 90, weightKg: 60),
          closeTo(1.5, 0.001));
    });
    test('速度レベル: 0.08=ok, 0.11=caution, 0.13=danger', () {
      expect(lipidRateLevel(0.08), AlertLevel.ok);
      expect(lipidRateLevel(0.11), AlertLevel.caution);
      expect(lipidRateLevel(0.13), AlertLevel.danger);
    });
    test('1日量レベル: 0.9=ok, 1.2=caution, 1.6=danger', () {
      expect(lipidDayLevel(0.9), AlertLevel.ok);
      expect(lipidDayLevel(1.2), AlertLevel.caution);
      expect(lipidDayLevel(1.6), AlertLevel.danger);
    });
    test('上限を満たす最大脂質（60kg）= 90 g/day', () {
      expect(maxLipidGramPerDay(weightKg: 60), closeTo(90, 0.001));
    });
  });
}
