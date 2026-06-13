/// 経腸栄養(EN)の開始/遅延判断サポート（ESPEN ICU 2019 / ASPEN-SCCM 2016）。
/// 遅延・回避すべき状況と、早期ENが原則支持される状況をチェックリスト化し、
/// 選択フラグから推奨（避ける/慎重/早期開始支持/標準）を返す。純粋関数。
///
/// 出典: ESPEN ICU 2019（早期EN原則、ただし uncontrolled shock 等では遅延）、
///       ASPEN/SCCM 2016。
library;

/// EN判断の推奨区分。
enum EnTimingRecommendation { avoid, startEarly, startStandard }

extension EnTimingRecommendationLabel on EnTimingRecommendation {
  String get label {
    switch (this) {
      case EnTimingRecommendation.avoid:
        return 'EN遅延/回避を考慮';
      case EnTimingRecommendation.startEarly:
        return '早期EN開始を支持';
      case EnTimingRecommendation.startStandard:
        return '標準的にEN開始可';
    }
  }
}

/// EN判断の1基準。group: 'avoid'（遅延/回避）/ 'early'（早期EN支持）。
class EnTimingCriterion {
  final String id;
  final String label;
  final String group;
  const EnTimingCriterion({
    required this.id,
    required this.label,
    required this.group,
  });
}

/// EN遅延/回避・早期支持の基準リスト（id はUI/保存/判定で共有）。
const List<EnTimingCriterion> kEnTimingCriteria = [
  // ── 遅延/回避すべき状況（avoid） ──
  EnTimingCriterion(
      id: 'uncontrolled_shock',
      label: 'コントロール不良のショック（循環不安定）',
      group: 'avoid'),
  EnTimingCriterion(
      id: 'hypoperfusion', label: '組織灌流目標が未達', group: 'avoid'),
  EnTimingCriterion(
      id: 'ugi_bleeding', label: '活動性の上部消化管出血', group: 'avoid'),
  EnTimingCriterion(
      id: 'bowel_ischemia', label: '明らかな腸管虚血', group: 'avoid'),
  EnTimingCriterion(
      id: 'high_output_fistula',
      label: '高出力腸瘻（遠位アクセス不能）',
      group: 'avoid'),
  EnTimingCriterion(
      id: 'acs', label: '腹部コンパートメント症候群', group: 'avoid'),
  EnTimingCriterion(
      id: 'grv_high', label: '胃残量 GRV > 500 mL/6h', group: 'avoid'),
  // ── 早期ENが原則支持される状況（early） ──
  EnTimingCriterion(id: 'ecmo', label: 'ECMO管理中', group: 'early'),
  EnTimingCriterion(id: 'tbi', label: '外傷性脳損傷', group: 'early'),
  EnTimingCriterion(id: 'stroke', label: '脳卒中', group: 'early'),
  EnTimingCriterion(id: 'sci', label: '脊髄損傷', group: 'early'),
  EnTimingCriterion(
      id: 'severe_pancreatitis', label: '重症急性膵炎', group: 'early'),
  EnTimingCriterion(id: 'gi_surgery', label: '消化管術後', group: 'early'),
  EnTimingCriterion(
      id: 'aaa_surgery', label: '腹部大動脈術後', group: 'early'),
  EnTimingCriterion(
      id: 'abdominal_trauma_continuity',
      label: '消化管連続性が確認された腹部外傷',
      group: 'early'),
  EnTimingCriterion(
      id: 'neuromuscular_blockade', label: '筋弛緩薬投与中', group: 'early'),
  EnTimingCriterion(id: 'prone', label: '腹臥位管理中', group: 'early'),
  EnTimingCriterion(id: 'open_abdomen', label: 'open abdomen', group: 'early'),
  EnTimingCriterion(id: 'diarrhea', label: '下痢', group: 'early'),
];

/// id → 基準。
EnTimingCriterion? enTimingCriterionById(String id) {
  for (final c in kEnTimingCriteria) {
    if (c.id == id) return c;
  }
  return null;
}

/// 選択フラグから EN 開始/遅延の推奨を判定。
/// - avoid基準が1つでも該当 → avoid（遅延/回避を優先・安全側）。
/// - そうでなく early基準が該当 → startEarly。
/// - いずれも無し → startStandard。
EnTimingRecommendation enTimingRecommendation(Set<String> flags) {
  final hasAvoid = kEnTimingCriteria
      .where((c) => c.group == 'avoid')
      .any((c) => flags.contains(c.id));
  if (hasAvoid) return EnTimingRecommendation.avoid;
  final hasEarly = kEnTimingCriteria
      .where((c) => c.group == 'early')
      .any((c) => flags.contains(c.id));
  if (hasEarly) return EnTimingRecommendation.startEarly;
  return EnTimingRecommendation.startStandard;
}

/// 推奨に応じた対処サジェスト本文。
String enTimingActionText(EnTimingRecommendation r) {
  switch (r) {
    case EnTimingRecommendation.avoid:
      return 'EN開始を遅延/回避を考慮。ショック制御・組織灌流の確保・'
          '活動性出血や腸管虚血の解除を優先し、改善後（ショック制御・GI可用性・'
          'EN耐性が得られたら）少量から開始。それまでは必要に応じPN/最小限EN。';
    case EnTimingRecommendation.startEarly:
      return '早期EN（48時間以内）が原則支持される病態。'
          '禁忌がなければ少量から早期に開始し、忍容性をみて漸増。';
    case EnTimingRecommendation.startStandard:
      return '明らかな遅延/回避因子なし。標準的に早期ENを検討（少量から開始）。';
  }
}
