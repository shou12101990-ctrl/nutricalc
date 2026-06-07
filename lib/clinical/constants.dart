/// 臨床栄養エンジン 物理定数・換算・安全閾値（Flutter非依存・純粋定数）。
///
/// 出典:
/// - GIR上限: ESPEN ICU 2019/2023（糖質 ≤5 mg/kg/min）、ASPEN（重症 <4 mg/kg/min 目標）
/// - 脂質速度: 成人LCT クリアランス <0.11 g/kg/h、ICU 1日量 ≤1.0（上限1.5）g/kg/day（ESPEN ICU、添付文書）
/// - 食塩↔Na: NaCl分子量 58.44 → 1 g食塩 = 17.11 mEq Na、1 mEq Na = 0.05844 g食塩
/// - 原子量: IUPAC標準原子量
library;

class ClinicalConst {
  ClinicalConst._();

  // ── GIR（糖負荷速度）mg/kg/min ──
  static const double girWarnMgKgMin = 4.0; // 重症時の注意域（ASPEN）
  static const double girLimitMgKgMin = 5.0; // ハード上限（ESPEN ICU）

  // ── 脂質負荷速度 ──
  static const double lipidRateWarnGKgH = 0.10; // 注意（成人クリアランス）
  static const double lipidRateLimitGKgH = 0.125; // ハード上限（添付文書）
  static const double lipidDayWarnGKgD = 1.0; // ICU目標
  static const double lipidDayLimitGKgD = 1.5; // 上限（ESPEN ICU）

  // ── 原子量 (g/mol) ──
  static const Map<String, double> atomicWeight = {
    'Na': 22.99,
    'K': 39.10,
    'Ca': 40.08,
    'Mg': 24.31,
    'P': 30.97,
    'Cl': 35.45,
    'Zn': 65.38,
    'Fe': 55.85,
    'Mn': 54.94,
    'Cu': 63.55,
    'I': 126.90,
    'Se': 78.97,
  };

  /// 2価イオン（mEq換算で×2）
  static const Set<String> divalentCations = {'Ca', 'Mg'};

  // ── 食塩 ↔ Na 換算 ──
  static const double naClMolWeight = 58.44;
  static const double saltGramToNaMEq = 17.11; // 1 g 食塩 = 17.11 mEq Na
  static const double naMEqToSaltGram = 0.05844; // 1 mEq Na = 0.05844 g 食塩
  static const double salt6gNaMEq = 102.7; // 食塩6 g（高血圧/CKD治療目標）
  static const double salt7_5gNaMEq = 128.3; // 食塩7.5 g（厚労省 男性目標量）

  /// Na mEq → 食塩 g 相当
  static double naMEqToSaltGrams(double mEq) => mEq * naMEqToSaltGram;
}
