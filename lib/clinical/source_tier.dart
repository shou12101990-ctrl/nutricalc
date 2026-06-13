/// ルールの出典ティア（Flutter非依存・純粋）。
///
/// 全ての臨床ルール・制約・アラート・イベント効果に出典ティアを付与し、
/// 「ガイドライン由来の根拠」と「アプリ独自のローカル方針/UXプリセット」を
/// コード経路上で混在させない（handoff §3）。
///
/// UI（§23.4 ソースバッジ）でも origin 表示に用いる。
library;

/// 出典ティア。restrictiveness/信頼度ではなく「根拠の種別」を表す。
enum SourceTier {
  /// ガイドライン上のハード制約（違反不可。例: GIR≤5 mg/kg/min）。
  guidelineHard,

  /// ガイドラインの推奨レンジ（バンド。例: タンパク 1.2–2.0 g/kg/day）。
  guidelineBand,

  /// ガイドライン上の義務（例: refeedingで糖負荷前のチアミン）。
  guidelineObligation,

  /// アプリ独自のローカル臨床方針（ガイドライン非依存）。
  localPolicy,

  /// 可視化・UX用の既定プリセット（例: 既定ENラダー。臨床的強制ではない）。
  uxPreset,

  /// 製剤マスタ由来のメタデータ（組成・剤型など）。
  productMetadata,

  /// ユーザー（医師）の選好（例: お気に入り製剤）。安全/バンドの後でのみ最適化。
  userPreference,

  /// ユーザーが入力した臨床イベント（例: CRRT開始、EN hold）。
  userInputEvent,
}

extension SourceTierMeta on SourceTier {
  /// 機械可読キー（yaml/シリアライズ/テスト用）。handoff §3 の表記に一致。
  String get key => switch (this) {
        SourceTier.guidelineHard => 'guideline_hard',
        SourceTier.guidelineBand => 'guideline_band',
        SourceTier.guidelineObligation => 'guideline_obligation',
        SourceTier.localPolicy => 'local_policy',
        SourceTier.uxPreset => 'ux_preset',
        SourceTier.productMetadata => 'product_metadata',
        SourceTier.userPreference => 'user_preference',
        SourceTier.userInputEvent => 'user_input_event',
      };

  /// UIソースバッジの日本語ラベル（§23.4）。
  String get badgeLabel => switch (this) {
        SourceTier.guidelineHard => 'ガイドライン(必須)',
        SourceTier.guidelineBand => 'ガイドライン',
        SourceTier.guidelineObligation => 'ガイドライン(義務)',
        SourceTier.localPolicy => 'ローカル方針',
        SourceTier.uxPreset => 'UXプリセット',
        SourceTier.productMetadata => '製剤メタデータ',
        SourceTier.userPreference => 'ユーザー選好',
        SourceTier.userInputEvent => 'ユーザーイベント',
      };

  /// ハード制約（違反不可）として扱うべきティアか。
  bool get isHard => this == SourceTier.guidelineHard;

  /// 安全/バンドより後にのみ最適化してよい「選好」ティアか。
  bool get isPreferenceOnly =>
      this == SourceTier.userPreference || this == SourceTier.uxPreset;
}

/// key 文字列 → SourceTier（不明は localPolicy にフォールバックせず例外回避で null）。
SourceTier? sourceTierFromKey(String key) {
  for (final t in SourceTier.values) {
    if (t.key == key) return t;
  }
  return null;
}
