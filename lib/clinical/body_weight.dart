/// 体重指標（BMI / 理想体重 IBW / 補正体重 ABW / 栄養計算用体重）。
/// Flutter非依存・純粋関数。エネルギー/タンパク目標の体重選択に使う。
///
/// 出典:
/// - Devine IBW（metric）: 男 50 + 0.9×(H−152) / 女 45.5 + 0.9×(H−152)（MDCalc/ClinCalc）
/// - 補正体重 ABW = IBW + 0.25×(actual−IBW)（栄養領域慣習。薬物投与の0.4ではない／Academy of Nutrition）
/// - 短身（<152cm）: Devineは補正項≤0で過小になり破綻するため BMI-22換算（22×H²）を採用（PMC10621523）
/// - 肥満時の体重基準: ASPEN/SCCM 2016（BMI>50 は IBW を使用）
library;

import 'dart:math' as math;

double bmiOf(double weightKg, double heightCm) {
  if (heightCm <= 0) return 0;
  final m = heightCm / 100.0;
  return weightKg / (m * m);
}

/// 理想体重（kg）。短身は BMI-22換算でガード。
double idealBodyWeight({required bool isMale, required double heightCm}) {
  if (heightCm <= 0) return 0;
  if (heightCm < 152) {
    final m = heightCm / 100.0;
    return 22.0 * m * m; // BMI-22換算（短身ガード）
  }
  final base = isMale ? 50.0 : 45.5;
  return base + 0.9 * (heightCm - 152);
}

/// 補正体重（kg）。エネルギー/タンパクには factor=0.25。
double adjustedBodyWeight({
  required double actualKg,
  required double ibwKg,
  double factor = 0.25,
}) =>
    ibwKg + factor * (actualKg - ibwKg);

/// エネルギー計算に用いる体重（決定木）。
/// - るい痩（actual<IBW）→ 実体重
/// - 過体重（BMI<30 かつ actual>1.20×IBW）→ 補正体重(0.25)
/// - 肥満 BMI 30–50 → 実体重（kcal/kg は 11–14 で別途ハンドル）
/// - 高度肥満 BMI>50 → IBW
/// - それ以外（正常域）→ 実体重
double feedingWeight({
  required double actualKg,
  required double heightCm,
  required bool isMale,
}) {
  final ibw = idealBodyWeight(isMale: isMale, heightCm: heightCm);
  final bmi = bmiOf(actualKg, heightCm);
  if (actualKg < ibw) return actualKg;
  if (bmi < 30) {
    if (actualKg > 1.20 * ibw) {
      return adjustedBodyWeight(actualKg: actualKg, ibwKg: ibw);
    }
    return actualKg;
  }
  // 肥満(BMI≥30): ESPEN — 補正体重を使用
  return adjustedBodyWeight(actualKg: actualKg, ibwKg: ibw);
}

/// 肥満区分（日本肥満学会基準・BMI）。
String obesityClass(double bmi) {
  if (bmi < 18.5) return '低体重';
  if (bmi < 25) return '普通体重';
  if (bmi < 30) return '肥満(1度)';
  if (bmi < 35) return '肥満(2度)';
  if (bmi < 40) return '肥満(3度)';
  return '肥満(4度)';
}

/// 体重の内訳（UI透明性表示用）。
class WeightBasis {
  final double actualKg;
  final double idealKg;
  final double feedingKg;
  final String label; // 「実体重」「補正体重」「理想体重(高度肥満)」など
  const WeightBasis({
    required this.actualKg,
    required this.idealKg,
    required this.feedingKg,
    required this.label,
  });
}

WeightBasis weightBasisOf({
  required double actualKg,
  required double heightCm,
  required bool isMale,
}) {
  final ibw = idealBodyWeight(isMale: isMale, heightCm: heightCm);
  final fw = feedingWeight(actualKg: actualKg, heightCm: heightCm, isMale: isMale);
  bool eq(double a, double b) => (a - b).abs() < 0.05;
  String label;
  if (eq(fw, actualKg)) {
    label = '実体重';
  } else if (eq(fw, ibw)) {
    label = '理想体重(高度肥満)';
  } else {
    label = '補正体重';
  }
  return WeightBasis(
    actualKg: actualKg,
    idealKg: double.parse(ibw.toStringAsFixed(1)),
    feedingKg: double.parse(fw.toStringAsFixed(1)),
    label: label,
  );
}

/// pow ヘルパ（テスト可読性のため公開）
double squareM(double heightCm) => math.pow(heightCm / 100.0, 2).toDouble();
