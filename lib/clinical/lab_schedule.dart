/// 採血（モニタリング）提案。Refeedingリスク・CKRT稼働・栄養開始からの日数・
/// 長期PN などの臨床コンテキストから、採血項目・頻度・トリガーを提案する。
/// Flutter非依存・純粋関数。
///
/// 出典: NICE CG32（再栄養5日以内の P/K/Mg 監視）、ESPEN micronutrient GL
///       （CKRT中の Se/Zn/Cu/水溶性ビタミン喪失モニタ）、JSPEN（長期PN監視）。
library;

import 'refeeding.dart';
import 'conditions.dart';

/// 採血提案の1項目。
class LabSuggestion {
  final String panel; // 採血項目群（例: 'P / K / Mg'）
  final String frequency; // 推奨頻度（例: '1日1回（再栄養〜5日）'）
  final String reason; // 理由・トリガー
  final int priority; // 並び順（小さいほど上位）
  const LabSuggestion({
    required this.panel,
    required this.frequency,
    required this.reason,
    this.priority = 100,
  });
}

/// 臨床コンテキストから採血提案リストを生成（priority昇順）。
/// - [refeedingTier]: Refeedingリスク階層（high/extreme で P/K/Mg を高頻度）。
/// - [ckrtActive]: CKRT(CRRT/PIRRT)稼働中（微量元素/水溶性ビタミン喪失モニタ）。
/// - [daysSinceNutritionStart]: 栄養開始からの日数（null=計画ビュー/不明。両期間を併記）。
/// - [pnHeavyMaxDay]: PN主体が遷延している最終Day（絶食起算・>=7 で長期PN監視を追加）。
List<LabSuggestion> labSchedule({
  RefeedingTier refeedingTier = RefeedingTier.none,
  bool ckrtActive = false,
  int? daysSinceNutritionStart,
  int? pnHeavyMaxDay,
}) {
  final out = <LabSuggestion>[];

  // ── Refeedingリスク: P/K/Mg（再栄養5日以内が最高リスク） ──
  if (refeedingTier != RefeedingTier.none) {
    final extreme = refeedingTier == RefeedingTier.extreme;
    // daysが不明(計画ビュー)なら両期間を併記。確定していればその期の頻度のみ。
    final String freq;
    if (daysSinceNutritionStart == null) {
      freq = extreme
          ? '再栄養〜5日は1日1–2回（超高リスク）、6日目以降は状態安定まで2–3日毎'
          : '再栄養〜5日は1日1回、6日目以降は状態安定まで2–3日毎';
    } else if (daysSinceNutritionStart <= 5) {
      freq = extreme ? '再栄養〜5日は1日1–2回（超高リスク）' : '再栄養〜5日は1日1回';
    } else {
      freq = '6日目以降は状態安定まで2–3日毎';
    }
    out.add(LabSuggestion(
      panel: 'P / K / Mg',
      frequency: freq,
      reason: 'Refeeding症候群の電解質シフト監視。'
          '${refeedingTier.label}。再栄養5日以内が発症の最高リスク期。',
      priority: 0,
    ));
    out.add(LabSuggestion(
      panel: '血糖',
      frequency: '再栄養初期は頻回（高血糖・インスリン需要の変化）',
      reason: '糖負荷に伴う高血糖・低リン化の併発を監視。',
      priority: 5,
    ));
  }

  // ── CKRT稼働: 微量元素・水溶性ビタミン・栄養指標 ──
  if (ckrtActive) {
    out.add(LabSuggestion(
      panel: CkrtObligation.monitor.join(' / '),
      frequency: '週1回（CKRT稼働中は継続）',
      reason: 'CKRTで喪失しやすい微量元素・水溶性ビタミンと栄養/炎症指標を監視'
          '（CKRT obligation）。高優先: ${CkrtObligation.highPriority.join("・")}。',
      priority: 10,
    ));
    out.add(LabSuggestion(
      panel: 'Cu（血清銅）',
      frequency: 'CKRT ${CkrtObligation.cuReviewAfterDays}日以降に評価',
      reason: '長期CKRTでは銅欠乏に注意（過剰補充も避け、血中銅で要評価）。',
      priority: 12,
    ));
  }

  // ── 長期PN主体: 電解質・微量元素・PN関連肝障害 ──
  if (pnHeavyMaxDay != null && pnHeavyMaxDay >= 7) {
    out.add(LabSuggestion(
      panel: 'P / Mg / 微量元素 / 肝胆道系(AST・ALT・T-Bil・ALP)',
      frequency: '週1回',
      reason: '長期PN・PN主体の遷延（Day$pnHeavyMaxDay 時点）。'
          '電解質・微量元素の過不足とPN関連肝障害(IFALD)を監視。',
      priority: 20,
    ));
  }

  // ── ベースライン（常に提示） ──
  out.add(const LabSuggestion(
    panel: '電解質(Na/K/Cl) / 腎機能(BUN/Cre) / 血糖',
    frequency: '臨床状態に応じて（最低 数日毎）',
    reason: '栄養投与中の基本モニタ。',
    priority: 90,
  ));

  out.sort((a, b) => a.priority.compareTo(b.priority));
  return out;
}
