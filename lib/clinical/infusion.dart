/// 投与速度の安全評価（GIR・脂質負荷速度）。Flutter非依存・純粋関数。
///
/// 出典:
/// - GIR上限 5 mg/kg/min（ESPEN ICU 2019）、重症注意 4 mg/kg/min（ASPEN）
/// - 脂質速度 ≤0.1 g/kg/h（上限0.125）、1日量 ≤1.0（上限1.5）g/kg/day
library;

import 'constants.dart';

enum AlertLevel { ok, caution, danger }

/// 糖負荷速度 GIR（mg/kg/min）= ブドウ糖 g/day ×1000 /(体重kg×1440)。
/// 分子は「静脈ブドウ糖のみ」を渡すこと（EN/食事の糖質・glycerol等は除外）。
double gir({required double glucoseGramPerDay, required double weightKg}) {
  if (weightKg <= 0) return 0;
  return glucoseGramPerDay * 1000 / (weightKg * 1440);
}

/// GIR上限を満たす最大ブドウ糖 g/day。
double maxGlucoseGramPerDay({
  required double weightKg,
  double limitMgKgMin = ClinicalConst.girLimitMgKgMin,
}) =>
    limitMgKgMin * weightKg * 1440 / 1000;

/// 脂質負荷速度（g/kg/h）。hours=投与時間（既定24h持続）。
double lipidRatePerHour({
  required double lipidGramPerDay,
  required double weightKg,
  double hours = 24,
}) {
  if (weightKg <= 0 || hours <= 0) return 0;
  return lipidGramPerDay / (weightKg * hours);
}

/// 脂質 1日量（g/kg/day）。
double lipidPerDayGramPerKg({
  required double lipidGramPerDay,
  required double weightKg,
}) {
  if (weightKg <= 0) return 0;
  return lipidGramPerDay / weightKg;
}

/// 脂質上限を満たす最大脂質 g/day（1日量基準）。
double maxLipidGramPerDay({
  required double weightKg,
  double limitGKgD = ClinicalConst.lipidDayLimitGKgD,
}) =>
    limitGKgD * weightKg;

/// GIR警告レベル。糖質制限病態では warn=4 を渡す。
AlertLevel girLevel(
  double girValue, {
  double warn = ClinicalConst.girWarnMgKgMin,
  double limit = ClinicalConst.girLimitMgKgMin,
}) {
  if (girValue > limit) return AlertLevel.danger;
  if (girValue > warn) return AlertLevel.caution;
  return AlertLevel.ok;
}

/// 脂質速度（g/kg/h）の警告レベル。
AlertLevel lipidRateLevel(double ratePerHour) {
  if (ratePerHour > ClinicalConst.lipidRateLimitGKgH) return AlertLevel.danger;
  if (ratePerHour > ClinicalConst.lipidRateWarnGKgH) return AlertLevel.caution;
  return AlertLevel.ok;
}

/// 脂質 1日量（g/kg/day）の警告レベル。
AlertLevel lipidDayLevel(double gPerKgDay) {
  if (gPerKgDay > ClinicalConst.lipidDayLimitGKgD) return AlertLevel.danger;
  if (gPerKgDay > ClinicalConst.lipidDayWarnGKgD) return AlertLevel.caution;
  return AlertLevel.ok;
}
