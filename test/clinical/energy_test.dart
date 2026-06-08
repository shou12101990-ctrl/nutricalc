import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/energy.dart';

void main() {
  group('Harris-Benedict（女性定数655バグ修正）', () {
    test('男 60kg/170cm/40y = 66+822+850-272 = 1466', () {
      expect(
          harrisBenedictBee(
              isMale: true, weightKg: 60, heightCm: 170, age: 40),
          closeTo(1466, 0.001));
    });
    test('女 60kg/160cm/40y = 655+576+288-188 = 1331（665ではない）', () {
      expect(
          harrisBenedictBee(
              isMale: false, weightKg: 60, heightCm: 160, age: 40),
          closeTo(1331, 0.001));
    });
  });

  group('Mifflin-St Jeor', () {
    test('男 60/170/40 = 600+1062.5-200+5 = 1467.5', () {
      expect(
          mifflinStJeorRee(isMale: true, weightKg: 60, heightCm: 170, age: 40),
          closeTo(1467.5, 0.001));
    });
    test('女 60/160/40 = 600+1000-200-161 = 1239', () {
      expect(
          mifflinStJeorRee(
              isMale: false, weightKg: 60, heightCm: 160, age: 40),
          closeTo(1239, 0.001));
    });
  });

  group('targetEnergy ディスパッチ', () {
    test('H-B × AF × SF（正常体重は実体重で計算）', () {
      final r = targetEnergy(
        model: EnergyModel.harrisBenedict,
        isMale: true,
        weightKg: 60,
        heightCm: 170,
        age: 40,
        activityFactor: 1.1,
        stressFactor: 1.2,
      );
      expect(r.kcal, closeTo(1466 * 1.1 * 1.2, 0.01));
    });

    test('kcal/kg 簡易式（正常体重 fw×25）', () {
      final r = targetEnergy(
        model: EnergyModel.kcalPerKg,
        isMale: true,
        weightKg: 72,
        heightCm: 170,
        age: 40,
        activityFactor: 1.0,
        stressFactor: 1.0,
        kcalPerKgValue: 25,
      );
      expect(r.kcal, closeTo(72 * 25, 0.01)); // 正常域→実体重72
    });

    test('kcal/kg 肥満 BMI≥30 → 補正体重×22.5 (ESPEN)', () {
      // 男170 95kg(BMI32.9) IBW66.2 → ABW=66.2+0.25×28.8=73.4
      final r = targetEnergy(
        model: EnergyModel.kcalPerKg,
        isMale: true,
        weightKg: 95,
        heightCm: 170,
        age: 40,
        activityFactor: 1.0,
        stressFactor: 1.0,
      );
      expect(r.kcal, closeTo(73.4 * 22.5, 0.5));
      expect(r.feedingWeightKg, closeTo(73.4, 0.1));
    });

    test('kcal/kg 高度肥満 BMI>50 も補正体重×22.5', () {
      // 男170 150kg(BMI51.9) IBW66.2 → ABW=66.2+0.25×83.8=87.15
      final r = targetEnergy(
        model: EnergyModel.kcalPerKg,
        isMale: true,
        weightKg: 150,
        heightCm: 170,
        age: 40,
        activityFactor: 1.0,
        stressFactor: 1.0,
      );
      expect(r.kcal, closeTo(87.15 * 22.5, 0.5));
    });

    test('間接熱量測定 = 実測REEをそのまま(AF/SF不使用)', () {
      final r = targetEnergy(
        model: EnergyModel.indirectCalorimetry,
        isMale: true,
        weightKg: 60,
        heightCm: 170,
        age: 40,
        activityFactor: 1.2,
        stressFactor: 1.5,
        measuredREE: 1500,
      );
      expect(r.kcal, closeTo(1500, 0.01)); // AF/SFは使わない
    });

    test('Mifflin = REEをそのまま(AF/SF不使用)', () {
      final r = targetEnergy(
        model: EnergyModel.mifflinStJeor,
        isMale: true,
        weightKg: 60,
        heightCm: 170,
        age: 40,
        activityFactor: 1.2,
        stressFactor: 1.5,
      );
      // 男 60/170/40 のMifflin REE = 1467.5、AF/SFは掛けない
      expect(r.kcal, closeTo(1467.5, 0.5));
    });
  });

  test('energyModelFromId 後方互換', () {
    expect(energyModelFromId(null), EnergyModel.harrisBenedict);
    expect(energyModelFromId('kcalPerKg'), EnergyModel.kcalPerKg);
    expect(energyModelFromId('unknown'), EnergyModel.harrisBenedict);
  });
}
