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

// ─────────── NICE 高リスク基準（構造化・UI列挙用） ───────────
//
// NICE CG32 の高リスク基準を id/label/group で構造化する。
// group: 'major'(1つ以上で高リスク) / 'minor'(2つ以上で高リスク) / 'extreme'(超高リスク)。
// UI はこのリストを列挙してチップ/トグルを生成する（自動算出フラグと手動入力フラグの和集合を判定にかける）。

/// NICE 高リスク基準の1項目。
class RefeedingCriterion {
  final String id;
  final String label;
  final String group; // 'major' | 'minor' | 'extreme'
  const RefeedingCriterion({
    required this.id,
    required this.label,
    required this.group,
  });
}

/// NICE CG32 高リスク基準の定数リスト（id 群は判定・保存・UIで共有）。
const List<RefeedingCriterion> kRefeedingCriteria = [
  // 超高リスク（いずれかで extreme）
  RefeedingCriterion(id: 'bmi_lt14', label: 'BMI<14', group: 'extreme'),
  RefeedingCriterion(
      id: 'intake_gt15d', label: '15日超ほぼ絶食', group: 'extreme'),
  // major（1つ以上で高リスク）
  RefeedingCriterion(id: 'bmi_lt16', label: 'BMI<16', group: 'major'),
  RefeedingCriterion(
      id: 'wtloss_gt15', label: '3–6ヶ月で>15%体重減', group: 'major'),
  RefeedingCriterion(
      id: 'intake_lt_gt10d', label: '10日超ほぼ絶食', group: 'major'),
  RefeedingCriterion(
      id: 'low_electrolyte', label: '投与前K/P/Mg低値', group: 'major'),
  // minor（2つ以上で高リスク）
  RefeedingCriterion(id: 'bmi_lt18_5', label: 'BMI<18.5', group: 'minor'),
  RefeedingCriterion(id: 'wtloss_gt10', label: '>10%体重減', group: 'minor'),
  RefeedingCriterion(
      id: 'intake_lt_gt5d', label: '5日超ほぼ絶食', group: 'minor'),
  RefeedingCriterion(
      id: 'alcohol_or_drugs',
      label: 'アルコール/インスリン/化学療法/制酸薬/利尿薬歴',
      group: 'minor'),
];

/// id → 基準（label/group 参照用）。
RefeedingCriterion? refeedingCriterionById(String id) {
  for (final c in kRefeedingCriteria) {
    if (c.id == id) return c;
  }
  return null;
}

/// 手動入力すべき基準か（BMI/絶食日数から自動算出される基準=自動扱い、それ以外=手動）。
/// 保存・評価で stale な自動フラグ(bmi_*/intake_*)を除外するのに使う。
bool isManualRefeedingCriterion(String id) =>
    !id.startsWith('bmi_') && !id.startsWith('intake_');

/// 選択フラグ（基準id集合）から NICE リスク階層を判定。
/// - extreme該当 → extreme
/// - major≥1 または minor≥2 → high
/// - それ以外 → none
RefeedingTier refeedingTierFromFlags(Set<String> flags) {
  final extreme = kRefeedingCriteria
      .where((c) => c.group == 'extreme')
      .any((c) => flags.contains(c.id));
  if (extreme) return RefeedingTier.extreme;
  final major = kRefeedingCriteria
      .where((c) => c.group == 'major')
      .where((c) => flags.contains(c.id))
      .length;
  final minor = kRefeedingCriteria
      .where((c) => c.group == 'minor')
      .where((c) => flags.contains(c.id))
      .length;
  if (major >= 1 || minor >= 2) return RefeedingTier.high;
  return RefeedingTier.none;
}

/// BMI / 絶食日数から自動で立つ NICE 基準フラグ集合。
/// 手動選択フラグ（体重減・低電解質・アルコール/薬物歴）とは独立で、
/// UI では読み取り専用チップとして表示する。
/// bmi<14→bmi_lt14, bmi<16→bmi_lt16, bmi<18.5→bmi_lt18_5,
/// days>15→intake_gt15d, days>10→intake_lt_gt10d, days>5→intake_lt_gt5d。
Set<String> autoRefeedingFlags({double? bmi, int? daysNoIntake}) {
  final out = <String>{};
  if (bmi != null) {
    if (bmi < 14) out.add('bmi_lt14');
    if (bmi < 16) out.add('bmi_lt16');
    if (bmi < 18.5) out.add('bmi_lt18_5');
  }
  if (daysNoIntake != null) {
    if (daysNoIntake > 15) out.add('intake_gt15d');
    if (daysNoIntake > 10) out.add('intake_lt_gt10d');
    if (daysNoIntake > 5) out.add('intake_lt_gt5d');
  }
  return out;
}

/// リスク階層に応じた NICE 対処サジェスト本文。
String refeedingActionText(RefeedingTier tier) {
  final monitor = tier == RefeedingTier.extreme ? '・持続心電図モニター' : '';
  return 'チアミン200–300mg/day（糖負荷前〜10日）'
      '・K 2–4 / PO₄ 0.3–0.6 / Mg 0.2–0.4 mmol/kg/day を投与とともに補充'
      '・血清P≥2.0mg/dL維持・K/PO₄/Mg/血糖を頻回モニタ$monitor';
}
