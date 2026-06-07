/// タンパク目標（Flutter非依存・純粋関数）。
///
/// 出典:
/// - 肥満（ASPEN/SCCM 2016）: BMI 30–40 → 2.0 g/kg理想体重、BMI≥40 → 2.5 g/kg理想体重
/// - 非肥満: feedingWeight × g/kg
library;

import 'body_weight.dart';

/// タンパク計算に用いる体重（kg）。肥満（BMI≥30）は理想体重、非肥満は feedingWeight。
double proteinTargetWeight({
  required double actualKg,
  required double heightCm,
  required bool isMale,
}) {
  final bmi = bmiOf(actualKg, heightCm);
  if (bmi >= 30) {
    return idealBodyWeight(isMale: isMale, heightCm: heightCm);
  }
  return feedingWeight(actualKg: actualKg, heightCm: heightCm, isMale: isMale);
}

/// 目標タンパク量（g/day）。
double targetProtein({
  required double actualKg,
  required double heightCm,
  required bool isMale,
  required double gramPerKg,
}) =>
    proteinTargetWeight(actualKg: actualKg, heightCm: heightCm, isMale: isMale) *
    gramPerKg;

/// ASPEN肥満タンパクの推奨 g/kg（BMI 30–40→2.0、≥40→2.5）。null=非肥満。
double? obeseProteinGoalPerKg(double bmi) {
  if (bmi >= 40) return 2.5;
  if (bmi >= 30) return 2.0;
  return null;
}
