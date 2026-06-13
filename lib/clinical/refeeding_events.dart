/// Refeeding症候群(RS)の発症後イベント検出（ASPEN 2020 consensus / NICE）。
/// 再栄養開始後（特に5日以内）の血清 P / K / Mg の低下割合と臓器障害から
/// mild / moderate / severe を分類する。Flutter非依存・純粋関数。
///
/// 出典: da Silva ら ASPEN consensus 2020（P/K/Mg いずれか1つ以上の
///       10–20% / 20–30% / >30% 低下＝mild / moderate / severe。
///       低下による臓器障害 or チアミン欠乏徴候は severe）。
library;

/// RS重症度。
enum RsSeverity { none, mild, moderate, severe }

extension RsSeverityLabel on RsSeverity {
  String get label {
    switch (this) {
      case RsSeverity.none:
        return '所見なし';
      case RsSeverity.mild:
        return '軽症RS';
      case RsSeverity.moderate:
        return '中等症RS';
      case RsSeverity.severe:
        return '重症RS';
    }
  }
}

/// 1電解質の baseline → current 低下割合(%)。
/// baseline<=0 や上昇(current>=baseline)は 0% を返す。
double electrolyteDropPercent(double baseline, double current) {
  if (baseline <= 0) return 0;
  final drop = (baseline - current) / baseline * 100;
  return drop < 0 ? 0 : drop;
}

/// 低下割合(%) → RS重症度。10–20%=mild, 20–30%=moderate, ≥30%=severe。
RsSeverity rsSeverityFromDrop(double dropPercent) {
  if (dropPercent >= 30) return RsSeverity.severe;
  if (dropPercent >= 20) return RsSeverity.moderate;
  if (dropPercent >= 10) return RsSeverity.mild;
  return RsSeverity.none;
}

/// 1電解質の baseline/current ペア（未測定は null）。
class RsLab {
  final double? baseline;
  final double? current;
  const RsLab({this.baseline, this.current});

  bool get hasBoth => baseline != null && current != null;
  double get dropPercent =>
      hasBoth ? electrolyteDropPercent(baseline!, current!) : 0;
}

/// RS総合評価結果。
class RsAssessment {
  final RsSeverity severity;
  final Map<String, double> dropPercents; // 'P'/'K'/'Mg' → 低下%（測定済みのみ）
  final bool organDysfunction;
  const RsAssessment({
    required this.severity,
    required this.dropPercents,
    required this.organDysfunction,
  });

  bool get hasFinding => severity != RsSeverity.none;
}

/// P / K / Mg の baseline/current と臓器障害から総合 RS 評価。
/// - 各電解質の低下% → 最大の重症度を採用。
/// - 低下に起因する臓器障害ありなら severe へ引き上げ（ASPEN consensus）。
RsAssessment assessRefeedingSyndrome({
  RsLab? phosphate,
  RsLab? potassium,
  RsLab? magnesium,
  bool organDysfunction = false,
}) {
  final drops = <String, double>{};
  void add(String key, RsLab? lab) {
    if (lab != null && lab.hasBoth) drops[key] = lab.dropPercent;
  }

  add('P', phosphate);
  add('K', potassium);
  add('Mg', magnesium);

  var severity = RsSeverity.none;
  for (final d in drops.values) {
    final s = rsSeverityFromDrop(d);
    if (s.index > severity.index) severity = s;
  }
  // 低下に伴う臓器障害は severe（ただし最低でも何らかの低下/低値を伴う臨床判断下）。
  if (organDysfunction && severity != RsSeverity.none) {
    severity = RsSeverity.severe;
  } else if (organDysfunction && drops.isEmpty) {
    // 採血未入力でも臓器障害を医師が認めれば severe 扱い（安全側）。
    severity = RsSeverity.severe;
  }

  return RsAssessment(
    severity: severity,
    dropPercents: drops,
    organDysfunction: organDysfunction,
  );
}

/// RS重症度に応じた対処サジェスト本文（電解質補正・栄養減速・モニタ）。
String rsActionText(RsSeverity severity) {
  switch (severity) {
    case RsSeverity.none:
      return '電解質の有意な低下なし。再栄養5日以内は P/K/Mg を継続モニタ。';
    case RsSeverity.mild:
      return 'P/K/Mg を経口/静注で補正しつつ栄養はそのまま継続可。'
          'チアミン併用・電解質を頻回(最低1日1回)モニタ。';
    case RsSeverity.moderate:
      return 'P/K/Mg を積極補正し、エネルギーを50%程度に減速して再増量は緩徐に。'
          'チアミン200–300mg/day・心電図/バイタルを監視。';
    case RsSeverity.severe:
      return 'エネルギーを大幅減速（必要時いったん中断）し、P/K/Mg を静注で集中補正。'
          '血清P≥2.0mg/dL維持・持続心電図/循環モニタ・チアミン高用量・ICU管理を考慮。';
  }
}
