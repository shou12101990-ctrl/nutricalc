/// Refeeding症候群リスク判定とエネルギー漸増（NICE CG32 2006準拠）。
/// Flutter非依存・純粋関数。
///
/// 出典: NICE CG32 "Nutrition support for adults"（高リスク基準・10/5 kcal/kg・漸増）
///       JSPEN（チアミン200–300mg、血清P≥2.0mg/dL維持）
library;

enum RefeedingTier { none, high, extreme }

extension RefeedingTierLabel on RefeedingTier {
  String get label {
    switch (this) {
      case RefeedingTier.none:
        return 'リスク低';
      case RefeedingTier.high:
        return '高リスク';
      case RefeedingTier.extreme:
        return '超高リスク';
    }
  }
}

/// NICE基準でリスク階層を判定。
/// - EXTREME: BMI<14 または 絶食>15日
/// - HIGH: いずれか1つ{BMI<16, 体重減>15%/3-6mo, 絶食>10日, 電解質低値}
///         または いずれか2つ{BMI<18.5, 体重減>10%, 絶食>5日, アルコール/薬物歴}
/// daysNoIntake = 栄養開始日 − 絶食開始日（不明なら null）。
/// 電解質未測定（lowElectrolyte=null）は ONE-OR-MORE では「該当せず」扱い。
RefeedingTier refeedingTier({
  double? bmi,
  int? daysNoIntake,
  double? weightLossPct3to6mo,
  bool? lowElectrolyte,
  bool historyAlcoholDrugs = false,
}) {
  // EXTREME
  if (bmi != null && bmi < 14) return RefeedingTier.extreme;
  if (daysNoIntake != null && daysNoIntake > 15) return RefeedingTier.extreme;

  // HIGH: ONE-OR-MORE
  final oneOrMore = (bmi != null && bmi < 16) ||
      (weightLossPct3to6mo != null && weightLossPct3to6mo > 15) ||
      (daysNoIntake != null && daysNoIntake > 10) ||
      (lowElectrolyte == true);

  // HIGH: TWO-OR-MORE
  int two = 0;
  if (bmi != null && bmi < 18.5) two++;
  if (weightLossPct3to6mo != null && weightLossPct3to6mo > 10) two++;
  if (daysNoIntake != null && daysNoIntake > 5) two++;
  if (historyAlcoholDrugs) two++;

  if (oneOrMore || two >= 2) return RefeedingTier.high;
  return RefeedingTier.none;
}

/// 栄養開始からの kcal/kg/day 漸増スケジュール（最終要求量 fullKcalPerKg へ）。
/// 配列の長さ=漸増日数。実日数がこれを超えたら最終値（full）を維持。
List<double> refeedingKcalPerKgRamp(
    RefeedingTier tier, double fullKcalPerKg) {
  switch (tier) {
    case RefeedingTier.extreme:
      return [5, 10, 15, 20, fullKcalPerKg];
    case RefeedingTier.high:
      return [10, 15, 20, fullKcalPerKg];
    case RefeedingTier.none:
      return [fullKcalPerKg];
  }
}

/// 栄養開始からの feeding 日（1始まり）における kcal/kg 上限。
double refeedingCapKcalPerKg(
    RefeedingTier tier, int feedingDayOneBased, double fullKcalPerKg) {
  final ramp = refeedingKcalPerKgRamp(tier, fullKcalPerKg);
  if (feedingDayOneBased < 1) return ramp.first;
  final idx = feedingDayOneBased - 1;
  final v = idx < ramp.length ? ramp[idx] : ramp.last;
  // full を超えない
  return v > fullKcalPerKg ? fullKcalPerKg : v;
}

/// リスク階層に応じた NICE 対処サジェスト本文。
String refeedingActionText(RefeedingTier tier) {
  final monitor = tier == RefeedingTier.extreme ? '・持続心電図モニター' : '';
  return 'チアミン200–300mg/day（糖負荷前〜10日）'
      '・K 2–4 / PO₄ 0.3–0.6 / Mg 0.2–0.4 mmol/kg/day を投与とともに補充'
      '・血清P≥2.0mg/dL維持・K/PO₄/Mg/血糖を頻回モニタ$monitor';
}
