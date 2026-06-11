/// 電解質・微量元素・ビタミンの日次集計と耐容上限(UL)アラート。
/// Flutter非依存・純粋関数。
///
/// 内部単位: elec Na/K/Cl/Ca/Mg = mEq, P = mmol / trace = μmol / vit = 各標準単位
/// 出典: 日本人の食事摂取基準2025（耐容上限量）/ 厚労省 食塩目標量 /
///       ASPEN 2019・JSPEN（静脈栄養必要量）/ 食品安全委員会（Mn神経毒性）
library;

import 'constants.dart';
import 'infusion.dart' show AlertLevel;

/// 微量元素のEN/PN標準量（ESPEN micronutrient GL 2022）。
/// 単位はアプリのマスタ単位 μmol/day に整合（元のmg/µg値は label に併記）。
class TraceStandard {
  final String element; // 'Zn' 等(マスタtraceキー)
  final double enMinUmol, enMaxUmol; // EN 1500kcalあたり
  final double pnMinUmol, pnMaxUmol; // PN標準
  final String original; // 元単位の表記(mg/µg)
  final String highNote; // 高要求/欠乏時の扱い
  const TraceStandard({
    required this.element,
    required this.enMinUmol,
    required this.enMaxUmol,
    required this.pnMinUmol,
    required this.pnMaxUmol,
    required this.original,
    required this.highNote,
  });
}

/// ESPEN標準（μmol換算: μg/原子量 or mg×1000/原子量）。Cr/Moはマスタ未収載=参照値。
const List<TraceStandard> kTraceStandards = [
  TraceStandard(
    element: 'Cr',
    enMinUmol: 0.7, enMaxUmol: 2.9, // 35–150 µg
    pnMinUmol: 0.2, pnMaxUmol: 0.3, // 10–15 µg
    original: 'EN 35–150 µg / PN 10–15 µg',
    highNote: 'インスリン抵抗性で追加検討',
  ),
  TraceStandard(
    element: 'Cu',
    enMinUmol: 15.7, enMaxUmol: 47.2, // 1–3 mg
    pnMinUmol: 4.7, pnMaxUmol: 7.9, // 0.3–0.5 mg
    original: 'EN 1–3 mg / PN 0.3–0.5 mg',
    highNote: '重度欠乏ではIV 4–8 mg/day(63–126 μmol)を検討',
  ),
  TraceStandard(
    element: 'Mn',
    enMinUmol: 36, enMaxUmol: 55, // 2–3 mg
    pnMinUmol: 1.0, pnMaxUmol: 1.0, // 55 µg
    original: 'EN 2–3 mg / PN 55 µg',
    highNote: '胆汁うっ滞/肝不全/長期PNでは過剰注意(Mn-free切替)',
  ),
  TraceStandard(
    element: 'Mo',
    enMinUmol: 0.5, enMaxUmol: 2.6, // 50–250 µg
    pnMinUmol: 0.20, pnMaxUmol: 0.26, // 19–25 µg
    original: 'EN 50–250 µg / PN 19–25 µg',
    highNote: '通常は標準補充',
  ),
  TraceStandard(
    element: 'Se',
    enMinUmol: 0.63, enMaxUmol: 1.90, // 50–150 µg
    pnMinUmol: 0.76, pnMaxUmol: 1.27, // 60–100 µg
    original: 'EN 50–150 µg / PN 60–100 µg',
    highNote: '血漿Se<0.4 µmol/Lなら100 µg/day(1.27 μmol)開始, 欠乏・高要求で最大200 µg/day(2.53 μmol)',
  ),
  TraceStandard(
    element: 'Zn',
    enMinUmol: 153, enMaxUmol: 306, // 10–20 mg
    pnMinUmol: 45.9, pnMaxUmol: 76.5, // 3–5 mg
    original: 'EN 10–20 mg / PN 3–5 mg',
    highNote: '消化管損失で最大12 mg/day IV(184 μmol), 熱傷で30–35 mg/day IVを2–3週',
  ),
];

/// element名 → 標準。未収載は null。
TraceStandard? traceStandardOf(String element) {
  for (final t in kTraceStandards) {
    if (t.element == element) return t;
  }
  return null;
}

/// 1製剤の組成寄与（micro=その製剤1単位の組成, multiplier=単位数 or 投与比）。
class MicroContribution {
  final Map<String, dynamic>? micro;
  final double multiplier;
  const MicroContribution(this.micro, this.multiplier);
}

/// 集計結果（section→栄養素→合計）。
class MicroTotals {
  final Map<String, double> elec;
  final Map<String, double> trace;
  final Map<String, double> vit;
  const MicroTotals({required this.elec, required this.trace, required this.vit});

  double of(String section, String key) {
    switch (section) {
      case 'elec':
        return elec[key] ?? 0;
      case 'trace':
        return trace[key] ?? 0;
      case 'vit':
        return vit[key] ?? 0;
      default:
        return 0;
    }
  }

  bool get isEmpty => elec.isEmpty && trace.isEmpty && vit.isEmpty;
}

MicroTotals aggregateMicro(Iterable<MicroContribution> items) {
  final elec = <String, double>{};
  final trace = <String, double>{};
  final vit = <String, double>{};

  void add(Map<String, double> into, dynamic section, double mult) {
    if (section is! Map) return;
    section.forEach((k, v) {
      final num? val = v is num ? v : num.tryParse(v.toString());
      if (val == null) return;
      into[k.toString()] = (into[k.toString()] ?? 0) + val.toDouble() * mult;
    });
  }

  for (final it in items) {
    final m = it.micro;
    if (m == null || it.multiplier == 0) continue;
    add(elec, m['elec'], it.multiplier);
    add(trace, m['trace'], it.multiplier);
    add(vit, m['vit'], it.multiplier);
  }
  return MicroTotals(elec: elec, trace: trace, vit: vit);
}

class MicroAlert {
  final String nutrient; // 表示名
  final AlertLevel level;
  final String message;
  final double value;
  const MicroAlert({
    required this.nutrient,
    required this.level,
    required this.message,
    required this.value,
  });
}

String _f(double v, [int d = 1]) => v.toStringAsFixed(d);

/// 日次集計から UL 超過＋病態別ガイダンスのアラートを生成。
/// isMale: ULの性差(Zn/Se)。longTermTpn: Mn神経毒性。
/// cholestasis/liver: Mn-free切替・Cu減量。renal: Cr/Mn蓄積。crrt: Se/B1喪失補充。
/// giLoss: Zn喪失補充。glucoseLoad+wernickeRisk: チアミン×糖負荷の安全インターロック。
List<MicroAlert> microAlerts(
  MicroTotals t, {
  bool isMale = true,
  bool longTermTpn = false,
  bool cholestasis = false,
  bool liver = false,
  bool renal = false,
  bool crrt = false,
  bool giLoss = false,
  bool glucoseLoad = false,
  bool wernickeRisk = false,
}) {
  final out = <MicroAlert>[];

  // ── Na（食塩負荷）──
  // カットオフ: 食塩7 g/日(HTなし成人の目標値)超で黄、9.6 g/日(日本人平均摂取量)以上で赤。
  final na = t.of('elec', 'Na');
  if (na > ClinicalConst.salt7gNaMEq) {
    final saltG = ClinicalConst.naMEqToSaltGrams(na);
    final isDanger = na >= ClinicalConst.salt9_6gNaMEq;
    out.add(MicroAlert(
      nutrient: 'Na',
      level: isDanger ? AlertLevel.danger : AlertLevel.caution,
      value: na,
      message: 'Na ${_f(na)} mEq/日 = 食塩 ${_f(saltG)} g/日 相当、'
          '${isDanger ? '日本人の平均食塩摂取量(9.6 g/日)以上' : 'HTなし成人の目標値(7 g/日)を超過'}',
    ));
  }

  // ── K ──
  final k = t.of('elec', 'K');
  if (k > 100) {
    out.add(MicroAlert(
      nutrient: 'K',
      level: AlertLevel.caution,
      value: k,
      message:
          'K ${_f(k)} mEq/日 が上限(100 mEq)を超過。投与速度≤20 mEq/h・濃度≤40 mEq/Lを厳守し心電図監視を',
    ));
  }

  // ── Ca（UL 2500 mg ≒ 124.8 mEq）──
  final ca = t.of('elec', 'Ca');
  if (ca > 124.8) {
    out.add(MicroAlert(
      nutrient: 'Ca',
      level: AlertLevel.caution,
      value: ca,
      message: 'Ca ${_f(ca)} mEq/日 が耐容上限(2500 mg≒125 mEq)を超過。P製剤との配合変化に注意',
    ));
  }

  // ── P（UL 3000 mg ≒ 96.9 mmol）──
  final p = t.of('elec', 'P');
  if (p > 96.9) {
    out.add(MicroAlert(
      nutrient: 'P',
      level: AlertLevel.caution,
      value: p,
      message: 'P ${_f(p)} mmol/日 が耐容上限(3000 mg≒97 mmol)を超過',
    ));
  }

  // ── Mg（腎機能低下時の注意・mEq>20）──
  final mg = t.of('elec', 'Mg');
  if (mg > 20) {
    out.add(MicroAlert(
      nutrient: 'Mg',
      level: AlertLevel.caution,
      value: mg,
      message: 'Mg ${_f(mg)} mEq/日、腎機能低下例では高Mg血症に注意',
    ));
  }

  // ── Zn（UL 男45/女35 mg → 688/535 μmol）──
  final zn = t.of('trace', 'Zn');
  final znUl = isMale ? 688.0 : 535.0;
  if (zn > znUl) {
    out.add(MicroAlert(
      nutrient: 'Zn',
      level: AlertLevel.caution,
      value: zn,
      message: 'Zn ${_f(zn)} μmol/日 が耐容上限(${isMale ? 45 : 35} mg)を超過',
    ));
  }

  // ── Cu（UL 7 mg → 110.1 μmol）──
  final cu = t.of('trace', 'Cu');
  if (cu > 110.1) {
    out.add(MicroAlert(
      nutrient: 'Cu',
      level: AlertLevel.caution,
      value: cu,
      message: 'Cu ${_f(cu)} μmol/日 が耐容上限(7 mg)を超過',
    ));
  }

  // ── Mn（UL 11 mg → 200.2 μmol／長期TPN・胆汁うっ滞で神経毒性）──
  final mn = t.of('trace', 'Mn');
  if (mn > 200.2) {
    out.add(MicroAlert(
      nutrient: 'Mn',
      level: AlertLevel.danger,
      value: mn,
      message:
          'Mn ${_f(mn)} μmol/日 が耐容上限(11 mg)を超過。胆汁うっ滞・長期TPNで神経毒性(淡蒼球蓄積)、減量/中止を検討',
    ));
  } else if ((cholestasis || liver) && mn > 0) {
    out.add(MicroAlert(
      nutrient: 'Mn',
      level: AlertLevel.danger,
      value: mn,
      message:
          'Mn含有製剤を胆汁うっ滞/肝障害で投与中。胆汁排泄低下で淡蒼球に蓄積(パーキンソン様)。Mn-free製剤(ボルビサール)へ切替を。胆道閉塞ではMn製剤禁忌',
    ));
  } else if (longTermTpn && mn > 0) {
    out.add(MicroAlert(
      nutrient: 'Mn',
      level: AlertLevel.caution,
      value: mn,
      message:
          'Mn含有製剤を長期TPNで継続中。胆汁うっ滞・肝障害例では神経毒性リスク、定期的な減量/中止の検討を',
    ));
  }

  // ── I（UL 3000 μg → 23.6 μmol）──
  final iodine = t.of('trace', 'I');
  if (iodine > 23.6) {
    out.add(MicroAlert(
      nutrient: 'I',
      level: AlertLevel.caution,
      value: iodine,
      message: 'I ${_f(iodine, 2)} μmol/日 が耐容上限(3000 μg)を超過',
    ));
  }

  // ── Se（UL 男450/女350 μg → 5.70/4.43 μmol）──
  final se = t.of('trace', 'Se');
  final seUl = isMale ? 5.70 : 4.43;
  if (se > seUl) {
    out.add(MicroAlert(
      nutrient: 'Se',
      level: AlertLevel.caution,
      value: se,
      message: 'Se ${_f(se, 2)} μmol/日 が耐容上限(${isMale ? 450 : 350} μg)を超過',
    ));
  }

  // ── ビタミンA（UL 2700 μgRAE）──
  final va = t.of('vit', 'A');
  if (va > 2700) {
    out.add(MicroAlert(
      nutrient: 'VitA',
      level: AlertLevel.caution,
      value: va,
      message: 'ビタミンA ${_f(va)} μgRAE/日 が耐容上限(2700)を超過、肝障害・高Ca血症に注意',
    ));
  }

  // ── ビタミンD（UL 100 μg=4000 IU）──
  final vd = t.of('vit', 'D');
  if (vd > 100) {
    out.add(MicroAlert(
      nutrient: 'VitD',
      level: AlertLevel.caution,
      value: vd,
      message: 'ビタミンD ${_f(vd)} μg/日 が耐容上限(100 μg=4000 IU)を超過、高Ca血症に注意',
    ));
  }

  // ── 病態別ガイダンス（過剰回避・不足の再評価）──
  final cuCtx = t.of('trace', 'Cu');
  if ((cholestasis || liver) && cuCtx > 0 && cuCtx <= 110.1) {
    out.add(MicroAlert(
      nutrient: 'Cu',
      level: AlertLevel.caution,
      value: cuCtx,
      message:
          'Cuは胆汁排泄。胆汁うっ滞/肝障害では減量しモニタ(血清Cu・セルロプラスミン)。ただし欠乏回避のためゼロにはしない',
    ));
  }
  if (renal && !crrt) {
    out.add(const MicroAlert(
      nutrient: 'Cr/Mn',
      level: AlertLevel.caution,
      value: 0,
      message:
          '腎不全(非透析): Cr/Mnは蓄積側。Crは輸液汚染で充足し追加不要、複合微量元素は減量し血中濃度をモニタ',
    ));
  }
  if (crrt) {
    out.add(const MicroAlert(
      nutrient: 'CRRT',
      level: AlertLevel.caution,
      value: 0,
      message:
          'CKRT稼働中: 水溶性ビタミン・微量元素の喪失を想定し、標準MVI+traceに想定喪失分を上乗せ。'
          'モニタ Se/Zn/Cu/VitC/葉酸/B1/CRP/Alb(高優先 B1/Se/Zn)。>2週はCu欠乏に注意し血中銅測定',
    ));
  }
  if (giLoss) {
    out.add(MicroAlert(
      nutrient: 'Zn',
      level: AlertLevel.caution,
      value: t.of('trace', 'Zn'),
      message:
          '高排出消化管/下痢でZn喪失。腸液+12mg/L・便/ストマ+17mg/Lを上乗せ、Mg/K/Naも補充',
    ));
  }
  if (glucoseLoad && wernickeRisk && t.of('vit', 'B1') < 3.0) {
    out.add(MicroAlert(
      nutrient: 'B1',
      level: AlertLevel.danger,
      value: t.of('vit', 'B1'),
      message:
          '糖負荷に対しビタミンB1が不足(≥3mg必要、高リスクは100–300mgを糖の前〜同時に)。Wernicke脳症・乳酸アシドーシスのリスク',
    ));
  }

  return out;
}
