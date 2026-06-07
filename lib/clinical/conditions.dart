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
