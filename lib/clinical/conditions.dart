/// 病態別の処方係数（Flutter非依存・純粋データ＋解決ロジック）。
/// 病態id は main.dart の ConditionCatalog と一致。
///
/// 出典: JSPEN 静脈経腸栄養ガイドライン第3版 / PDNレクチャー特殊病態下TPN /
///       肝硬変診療GL2020 / 日本透析医学会提言 / ASPEN・ESPEN ICU
/// - NPC/N: 健常150–200(中175)、重症~100、腎不全保存期300–500(中350)、透析期~150
/// - 脂質 g/kg/day: 全病態 0.9–1.0 に収束（上限1.0でクランプ）
/// - 糖質制限フラグ: 重症/呼吸/糖尿病で GIR を 4 mg/kg/min に抑える
/// - タンパク g/kg/day: 範囲のみ提示（強制しない＝医師が over-protein 許容可）
library;

class ConditionCoeff {
  final String id;
  final double npcN; // NPC/N比 推奨中央値
  final double lipidGPerKg; // 脂質 g/kg/day 推奨中央値
  final bool glucoseRestrict; // 糖質制限（GIR警告を4にクランプ）
  final double? proteinMinPerKg; // タンパク推奨下限（サジェスト・null=未設定）
  final double? proteinMaxPerKg; // タンパク推奨上限
  const ConditionCoeff({
    required this.id,
    required this.npcN,
    required this.lipidGPerKg,
    required this.glucoseRestrict,
    this.proteinMinPerKg,
    this.proteinMaxPerKg,
  });

  bool get hasProteinRange =>
      proteinMinPerKg != null && proteinMaxPerKg != null;
}

/// 一般ICU成人ベースライン。
const ConditionCoeff kGeneralCoeff = ConditionCoeff(
  id: 'general',
  npcN: 175,
  lipidGPerKg: 0.9,
  glucoseRestrict: false,
);

/// 病態id → 係数。係数を持たない病態（嚥下/吸収障害）はキーに含めない。
const Map<String, ConditionCoeff> kConditionCoeff = {
  'critical': ConditionCoeff(
    id: 'critical',
    npcN: 100,
    lipidGPerKg: 0.9,
    glucoseRestrict: true,
    proteinMinPerKg: 1.2,
    proteinMaxPerKg: 2.0,
  ),
  'renal': ConditionCoeff(
    id: 'renal',
    npcN: 350,
    lipidGPerKg: 0.9,
    glucoseRestrict: false,
    proteinMinPerKg: 0.6,
    proteinMaxPerKg: 0.8,
  ),
  'renal_dialysis': ConditionCoeff(
    id: 'renal_dialysis',
    npcN: 150,
    lipidGPerKg: 0.9,
    glucoseRestrict: false,
    proteinMinPerKg: 1.0,
    proteinMaxPerKg: 1.2,
  ),
  'liver': ConditionCoeff(
    id: 'liver',
    npcN: 150,
    lipidGPerKg: 1.0,
    glucoseRestrict: false,
    proteinMinPerKg: 1.0,
    proteinMaxPerKg: 1.2,
  ),
  'respiratory': ConditionCoeff(
    id: 'respiratory',
    npcN: 175,
    lipidGPerKg: 1.0,
    glucoseRestrict: true,
  ),
  'glucose_intolerance': ConditionCoeff(
    id: 'glucose_intolerance',
    npcN: 175,
    lipidGPerKg: 1.0,
    glucoseRestrict: true,
  ),
  // wound はタンパク範囲のみ（NPC/N等は一般値）
  'wound': ConditionCoeff(
    id: 'wound',
    npcN: 175,
    lipidGPerKg: 0.9,
    glucoseRestrict: false,
    proteinMinPerKg: 1.2,
    proteinMaxPerKg: 1.5,
  ),
};

/// 複数病態の解決結果。
class ResolvedCoeff {
  final double npcN;
  final double lipidGPerKg;
  final bool glucoseRestrict;
  const ResolvedCoeff({
    required this.npcN,
    required this.lipidGPerKg,
    required this.glucoseRestrict,
  });
}

/// 選択病態から係数を解決。係数を持つ病態が無ければ null（=既存値を変更しない）。
/// ルール: NPC/N=最大（最もタンパク節約）／脂質=最小（≤1.0クランプ）／糖質制限=OR。
ResolvedCoeff? resolveCoeff(Iterable<String> conditionIds) {
  final coeffs = <ConditionCoeff>[];
  for (final id in conditionIds) {
    final c = kConditionCoeff[id];
    if (c != null) coeffs.add(c);
  }
  if (coeffs.isEmpty) return null;
  double npcN = coeffs.map((c) => c.npcN).reduce((a, b) => a > b ? a : b);
  double lipid = coeffs.map((c) => c.lipidGPerKg).reduce((a, b) => a < b ? a : b);
  if (lipid > 1.0) lipid = 1.0;
  final restrict = coeffs.any((c) => c.glucoseRestrict);
  return ResolvedCoeff(npcN: npcN, lipidGPerKg: lipid, glucoseRestrict: restrict);
}

/// 選択病態のうちタンパク範囲を持つもの（サジェスト表示用）。
List<ConditionCoeff> proteinRangesFor(Iterable<String> conditionIds) {
  final out = <ConditionCoeff>[];
  for (final id in conditionIds) {
    final c = kConditionCoeff[id];
    if (c != null && c.hasProteinRange) out.add(c);
  }
  return out;
}

/// 複数のタンパク範囲の共通範囲（重なり）。重ならなければ null。
({double min, double max})? intersectedProteinRange(
    Iterable<String> conditionIds) {
  final ranges = proteinRangesFor(conditionIds);
  if (ranges.isEmpty) return null;
  double lo = ranges.map((c) => c.proteinMinPerKg!).reduce((a, b) => a > b ? a : b);
  double hi = ranges.map((c) => c.proteinMaxPerKg!).reduce((a, b) => a < b ? a : b);
  if (lo > hi) return null;
  return (min: lo, max: hi);
}

// ─────────── 腎疾患のタンパク目標（ESPEN腎疾患GL） ───────────
//
// 出典: ESPEN guideline on clinical nutrition in hospitalized patients with
//       acute or chronic kidney disease（腎/AKI/RRT/急性・重症で蛋白目標が変わる）。
// ハードルール: 蛋白制限で RRT 開始を遅らせない（=RRT適応なら蛋白を下げない）。
// 要医師判断: CKD 低蛋白食を入院中も継続するか（非異化・代謝安定時のみ継続可）。

/// RRT（腎代替療法）の種別。
enum RrtType { none, intermittent, continuous }

/// 病態タグ → RRT 種別。crrt=持続(CRRT/PIRRT)、renal_dialysis=間欠/維持透析。
RrtType rrtTypeFromTags(Iterable<String> tags) {
  final t = tags.toSet();
  if (t.contains('crrt')) return RrtType.continuous;
  if (t.contains('renal_dialysis')) return RrtType.intermittent;
  return RrtType.none;
}

/// 腎/AKI/RRT/急性病態を踏まえたタンパク目標。
class ProteinTarget {
  final double minPerKg;
  final double maxPerKg;
  final bool progressive; // min→max へ漸増（RRTなし急性期）
  final bool requiresReview; // 医師判断要（CKD低蛋白食の継続可否 等）
  final String basis; // 根拠ラベル
  const ProteinTarget({
    required this.minPerKg,
    required this.maxPerKg,
    this.progressive = false,
    this.requiresReview = false,
    required this.basis,
  });
  double get midPerKg => (minPerKg + maxPerKg) / 2;

  /// 自動設計で用いる代表値（漸増は到達点=max、範囲は中央値）。
  double get designPerKg => progressive ? maxPerKg : midPerKg;
}

/// ESPEN腎GLのタンパク目標。腎修飾（CKD/AKI/RRT）が無ければ null（=ICU一般値）。
ProteinTarget? renalProteinTarget(Iterable<String> tags) {
  final t = tags.toSet();
  final ckd = t.contains('renal');
  final aki = t.contains('aki');
  final acute = t.contains('critical'); // 急性/重症病態
  final rrt = rrtTypeFromTags(t);
  if (!ckd && !aki && rrt == RrtType.none) return null;

  // RRT がある＝蛋白を下げない（RRT種別が支配）
  if (rrt == RrtType.continuous) {
    return const ProteinTarget(
        minPerKg: 1.5, maxPerKg: 1.7, basis: '重症+CRRT/PIRRT');
  }
  if (rrt == RrtType.intermittent) {
    return const ProteinTarget(
        minPerKg: 1.3, maxPerKg: 1.5, basis: '重症+間欠RRT');
  }
  // RRTなし・急性/重症あり → 1.0→1.3 へ漸増
  if (acute) {
    return const ProteinTarget(
        minPerKg: 1.0,
        maxPerKg: 1.3,
        progressive: true,
        basis: 'AKI/CKD+急性・重症（RRTなし・1.0→1.3漸増）');
  }
  // 急性/重症なし・RRTなし
  if (aki) {
    return ProteinTarget(
        minPerKg: 0.8,
        maxPerKg: 1.0,
        requiresReview: ckd, // AKI on CKD は継続可否を要確認
        basis: 'AKI/AKI on CKD（急性・重症なし）');
  }
  // CKD のみ
  return const ProteinTarget(
      minPerKg: 0.6,
      maxPerKg: 0.8,
      requiresReview: true, // 低蛋白食の継続可否（非異化・代謝安定時のみ）
      basis: 'CKD（急性・重症なし・RRTなし）');
}

// ─────────── CKRT中の微量栄養素 obligation ───────────
//
// 方針: 「B1/Seを2倍」ではなく、active CKRT(CRRT/PIRRT)に紐づけて
// monitor/supplement obligation を立てる(ESPEN micronutrient GL)。
// 終了条件: CKRT終了 / 間欠HD移行 / 検査・臨床的安定+医師判断。

class CkrtObligation {
  /// モニタ対象（採血・臨床評価）。
  static const monitor = [
    'Se', 'Zn', 'Cu', 'VitC', '葉酸', 'B1', 'CRP', 'Alb'
  ];

  /// 高優先の補充対象。Cuは長期(>14日)で欠乏に注意・血中銅測定を推奨。
  static const highPriority = ['B1', 'Se', 'Zn'];
  static const cuReviewAfterDays = 14;

  /// 補充方針: 標準MVI+微量元素をベースに、想定喪失分または施設プロトコルで上乗せ。
  static const policy = '標準MVI+微量元素を継続し、想定喪失分(または施設プロトコル)を上乗せ';

  /// 終了条件（UI表示用）。
  static const stopConditions = [
    'CKRT終了', '間欠透析へ移行', '検査・臨床的安定(医師判断)'
  ];

  /// active CKRT か（crrtタグ=持続RRT稼働中とみなす）。
  static bool appliesTo(Iterable<String> tags) => tags.contains('crrt');
}

// ─────────── グルタミン（ESPEN/ASPEN） ───────────

/// グルタミン推奨。一般ICUは routine 追加しない(null)。
/// 熱傷>20%TBSA: EN 0.3–0.5 g/kg/day を10–15日 / 外傷: EN 0.2–0.3 g/kg/day を5日
/// (創傷治癒不良なら10–15日)。
({double minPerKg, double maxPerKg, String duration, String basis})?
    glutamineRecommendation(Iterable<String> tags) {
  final t = tags.toSet();
  if (t.contains('burn')) {
    return (
      minPerKg: 0.3,
      maxPerKg: 0.5,
      duration: '10–15日',
      basis: '熱傷>20%TBSA'
    );
  }
  if (t.contains('trauma')) {
    return (
      minPerKg: 0.2,
      maxPerKg: 0.3,
      duration: '5日(創傷治癒不良なら10–15日)',
      basis: '外傷ICU'
    );
  }
  return null; // 一般ICU: routine追加しない
}

/// 自動設計で用いる代表タンパク g/kg。腎修飾があればその代表値、無ければ fallback。
double effectiveProteinPerKg(Iterable<String> tags, double fallbackPerKg) =>
    renalProteinTarget(tags)?.designPerKg ?? fallbackPerKg;

/// 表示/評価用タンパク範囲。腎修飾を最優先、無ければ既存の病態範囲共通域。
({double min, double max})? effectiveProteinRange(Iterable<String> tags) {
  final rt = renalProteinTarget(tags);
  if (rt != null) return (min: rt.minPerKg, max: rt.maxPerKg);
  return intersectedProteinRange(tags);
}
