/// エネルギー必要量モデル（Flutter非依存・純粋関数）。
///
/// 出典:
/// - Harris-Benedict 1919（女性定数は 655。アプリ既存の 665 は +10kcal の既知タイポ）
/// - Mifflin-St Jeor: 男 10W+6.25H−5A+5 / 女 10W+6.25H−5A−161（Medscape）
/// - 簡易式 25–30 kcal/kg/day（ASPEN/SCCM 2016・JSPEN）
/// - 肥満（ASPEN/SCCM 2016）: BMI 30–50 → 実体重×11–14、BMI>50 → IBW×22–25
library;

import 'body_weight.dart';

enum EnergyModel {
  harrisBenedict, // BEE × AF × SF（既定・後方互換）
  mifflinStJeor, // REE × AF × SF
  kcalPerKg, // feedingWeight × kcal/kg（肥満はASPEN自動上書き）
  indirectCalorimetry, // 実測REE × AF
}

extension EnergyModelLabel on EnergyModel {
  String get label {
    switch (this) {
      case EnergyModel.harrisBenedict:
        return 'Harris-Benedict';
      case EnergyModel.mifflinStJeor:
        return 'Mifflin-St Jeor';
      case EnergyModel.kcalPerKg:
        return '簡易式 (kcal/kg)';
      case EnergyModel.indirectCalorimetry:
        return '間接熱量測定';
    }
  }

  String get id {
    switch (this) {
      case EnergyModel.harrisBenedict:
        return 'harrisBenedict';
      case EnergyModel.mifflinStJeor:
        return 'mifflinStJeor';
      case EnergyModel.kcalPerKg:
        return 'kcalPerKg';
      case EnergyModel.indirectCalorimetry:
        return 'indirectCalorimetry';
    }
  }
}

EnergyModel energyModelFromId(String? id) {
  switch (id) {
    case 'mifflinStJeor':
      return EnergyModel.mifflinStJeor;
    case 'kcalPerKg':
      return EnergyModel.kcalPerKg;
    case 'indirectCalorimetry':
      return EnergyModel.indirectCalorimetry;
    case 'harrisBenedict':
    default:
      return EnergyModel.harrisBenedict;
  }
}

/// Harris-Benedict BEE（女性定数 655 でバグ修正済み。男性係数はアプリ既存値を維持）。
double harrisBenedictBee({
  required bool isMale,
  required double weightKg,
  required double heightCm,
  required int age,
}) =>
    isMale
        ? 66 + 13.7 * weightKg + 5 * heightCm - 6.8 * age
        : 655 + 9.6 * weightKg + 1.8 * heightCm - 4.7 * age;

/// Mifflin-St Jeor REE。
double mifflinStJeorRee({
  required bool isMale,
  required double weightKg,
  required double heightCm,
  required int age,
}) =>
    10 * weightKg + 6.25 * heightCm - 5 * age + (isMale ? 5 : -161);

class EnergyResult {
  final double kcal;
  final double feedingWeightKg;
  final double idealWeightKg;
  final double actualWeightKg;
  final String basisLabel; // 計算根拠（UI表示用）
  const EnergyResult({
    required this.kcal,
    required this.feedingWeightKg,
    required this.idealWeightKg,
    required this.actualWeightKg,
    required this.basisLabel,
  });
}

/// 目標エネルギー（kcal/day）をモデルに応じて算出。
/// H-B / Mifflin は feedingWeight を式に投入（肥満/過体重で補正）。
/// kcal/kg は肥満をASPEN自動上書き。
EnergyResult targetEnergy({
  required EnergyModel model,
  required bool isMale,
  required double weightKg,
  required double heightCm,
  required int age,
  required double activityFactor,
  required double stressFactor,
  double kcalPerKgValue = 25,
  double? measuredREE,
}) {
  final ibw = idealBodyWeight(isMale: isMale, heightCm: heightCm);
  final bmi = bmiOf(weightKg, heightCm);
  final fw = feedingWeight(actualKg: weightKg, heightCm: heightCm, isMale: isMale);

  switch (model) {
    case EnergyModel.harrisBenedict:
      final bee = harrisBenedictBee(
          isMale: isMale, weightKg: fw, heightCm: heightCm, age: age);
      return EnergyResult(
        kcal: bee * activityFactor * stressFactor,
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: weightKg,
        basisLabel: 'H-B×AF×SF',
      );
    case EnergyModel.mifflinStJeor:
      final ree = mifflinStJeorRee(
          isMale: isMale, weightKg: fw, heightCm: heightCm, age: age);
      return EnergyResult(
        kcal: ree, // Mifflin REE をそのまま目標とする(AF/SFは用いない)
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: weightKg,
        basisLabel: 'Mifflin REE',
      );
    case EnergyModel.kcalPerKg:
      if (bmi >= 30) {
        // 肥満(BMI≥30, ESPEN): 補正体重 × 20–25 kcal/kg（中央22.5）
        final abw = adjustedBodyWeight(actualKg: weightKg, ibwKg: ibw);
        return EnergyResult(
          kcal: abw * 22.5,
          feedingWeightKg: abw,
          idealWeightKg: ibw,
          actualWeightKg: weightKg,
          basisLabel: '肥満 補正体重×22.5 (ESPEN)',
        );
      }
      return EnergyResult(
        kcal: fw * kcalPerKgValue,
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: weightKg,
        basisLabel: '${kcalPerKgValue.toStringAsFixed(0)} kcal/kg',
      );
    case EnergyModel.indirectCalorimetry:
      final ree = measuredREE ?? 0;
      return EnergyResult(
        kcal: ree, // 実測REEをそのまま目標とする(AF/SFは用いない)
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: weightKg,
        basisLabel: '実測REE',
      );
  }
}
