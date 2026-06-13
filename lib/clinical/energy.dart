/// エネルギー必要量モデル（Flutter非依存・純粋関数）。
///
/// 出典:
/// - Harris-Benedict 1919（女性定数は 655。アプリ既存の 665 は +10kcal の既知タイポ）
/// - Mifflin-St Jeor: 男 10W+6.25H−5A+5 / 女 10W+6.25H−5A−161（Medscape）
/// - 簡易式 25–30 kcal/kg/day（ASPEN/SCCM 2016・JSPEN）
/// - 肥満（ASPEN/SCCM 2016）: BMI 30–50 → 実体重×11–14、BMI>50 → IBW×22–25
library;

import 'body_weight.dart';

enum EnergyModel {
  harrisBenedict, // BEE × AF × SF（既定・後方互換）
  mifflinStJeor, // REE × AF × SF
  kcalPerKg, // feedingWeight × kcal/kg（肥満はASPEN自動上書き）
  indirectCalorimetry, // 実測REE × AF
}

extension EnergyModelLabel on EnergyModel {
  String get label {
    switch (this) {
      case EnergyModel.harrisBenedict:
        return 'Harris-Benedict';
      case EnergyModel.mifflinStJeor:
        return 'Mifflin-St Jeor';
      case EnergyModel.kcalPerKg:
        return '簡易式 (kcal/kg)';
      case EnergyModel.indirectCalorimetry:
        return '間接熱量測定';
    }
  }

  String get id {
    switch (this) {
      case EnergyModel.harrisBenedict:
        return 'harrisBenedict';
      case EnergyModel.mifflinStJeor:
        return 'mifflinStJeor';
      case EnergyModel.kcalPerKg:
        return 'kcalPerKg';
      case EnergyModel.indirectCalorimetry:
        return 'indirectCalorimetry';
    }
  }
}

EnergyModel energyModelFromId(String? id) {
  switch (id) {
    case 'mifflinStJeor':
      return EnergyModel.mifflinStJeor;
    case 'kcalPerKg':
      return EnergyModel.kcalPerKg;
    case 'indirectCalorimetry':
      return EnergyModel.indirectCalorimetry;
    case 'harrisBenedict':
    default:
      return EnergyModel.harrisBenedict;
  }
}

/// Harris-Benedict BEE（女性定数 655 でバグ修正済み。男性係数はアプリ既存値を維持）。
double harrisBenedictBee({
  required bool isMale,
  required double weightKg,
  required double heightCm,
  required int age,
}) =>
    isMale
        ? 66 + 13.7 * weightKg + 5 * heightCm - 6.8 * age
        : 655 + 9.6 * weightKg + 1.8 * heightCm - 4.7 * age;

/// Mifflin-St Jeor REE。
double mifflinStJeorRee({
  required bool isMale,
  required double weightKg,
  required double heightCm,
  required int age,
}) =>
    10 * weightKg + 6.25 * heightCm - 5 * age + (isMale ? 5 : -161);

/// 急性期の各日目標kcal(full nutrition)。
/// すべて「realFull に対する割合(frac)」で計算し、target = realFull × frac とする。
///
///   frac(day) = min( rampFrac(day), ceilFrac(day) )
///    ・rampFrac: 真の等差ランプ。day1 = startFrac → full達成日(fullAchieveDay=N) = 1.0 へ毎日線形増加。
///        startFrac = (1/N) を [0.15, 0.30] にクランプ。
///        (Nが大きい/refeedingで長期ランプでも初日は最低15%、短期ランプでも30%まで)。
///    ・ceilFrac: permissive underfeeding 上限。20kcal/kg(day≤kcal20UntilDay)・25kcal/kg(≤kcal25UntilDay)を
///        full比に換算(>fullなら1.0でクランプ)、それ以降は 1.0(上限解除)。
///
/// 目標値(kcal/kg)に依らず初日は startFrac(≤30%)<full で、初日からfullにはならない(構造的保証)。
/// day は栄養開始からの日(1始まり)。Refeeding cap は呼び出し側で別途適用する。
/// 急性期の線形ランプ割合(0〜1)。day1割合を [0.15, 0.30] に補正した線形ランプ。
///   startFrac = (1/N) を [0.15, 0.30] にクランプ → dayN(=fullAchieveDay) で 1.0 へ線形。
///   ※ N≤3 は day1=30%(cap)、N≥7 は day1=15%(floor) になり、厳密な 1/N ではない。
/// 係数上限(20/25kcal/kg)は含まない。カロリーとタンパクの両方で共有する。
double acutePhaseRampFraction({required int day, required int fullAchieveDay}) {
  final f = fullAchieveDay > 1 ? fullAchieveDay : 2;
  final startFrac = (1.0 / f).clamp(0.15, 0.30);
  final t = ((day - 1) / (f - 1)).clamp(0.0, 1.0);
  return startFrac + (1.0 - startFrac) * t;
}

double acutePhaseTargetKcal({
  required int day,
  required double feedingWeightKg,
  required double realFullKcal,
  required int fullAchieveDay,
  required int kcal20UntilDay,
  required int kcal25UntilDay,
}) {
  if (realFullKcal <= 0) return 0;
  final fw = feedingWeightKg;
  // 係数上限を full に対する割合へ換算(本来 full を超えない)
  final ceil20 = (20.0 * fw / realFullKcal).clamp(0.0, 1.0);
  final ceil25 = (25.0 * fw / realFullKcal).clamp(0.0, 1.0);
  // 真の等差ランプ: day1=(1/N を15〜30%にクランプ) → full達成日(N)=1.0。
  final rampFrac =
      acutePhaseRampFraction(day: day, fullAchieveDay: fullAchieveDay);
  // permissive underfeeding 上限
  final double ceilFrac;
  if (day <= kcal20UntilDay) {
    ceilFrac = ceil20;
  } else if (day <= kcal25UntilDay) {
    ceilFrac = ceil25;
  } else {
    ceilFrac = 1.0;
  }
  var frac = rampFrac < ceilFrac ? rampFrac : ceilFrac;
  if (frac > 1.0) frac = 1.0;
  if (frac < 0.0) frac = 0.0;
  return realFullKcal * frac;
}

/// 実際に full(100%)へ到達する最初の日(1始まり)。
/// 設定上の full達成日(傾きの終点)と、係数上限の解除(kcal25UntilDay超)の両方を満たす日。
/// 設定値と実挙動が乖離するため UI で「実到達」として並記する。
int effectiveFullDay({
  required double feedingWeightKg,
  required double realFullKcal,
  required int fullAchieveDay,
  required int kcal20UntilDay,
  required int kcal25UntilDay,
  int maxDay = 90,
}) {
  // 目標未確定(realFull<=0)では実到達日は未定義。設定上のfull達成日を返す(Day1誤表示を避ける)。
  if (realFullKcal <= 0) return fullAchieveDay.clamp(1, maxDay);
  for (var d = 1; d <= maxDay; d++) {
    final k = acutePhaseTargetKcal(
      day: d,
      feedingWeightKg: feedingWeightKg,
      realFullKcal: realFullKcal,
      fullAchieveDay: fullAchieveDay,
      kcal20UntilDay: kcal20UntilDay,
      kcal25UntilDay: kcal25UntilDay,
    );
    if (k >= realFullKcal * 0.995) return d;
  }
  return maxDay;
}

class EnergyResult {
  final double kcal;
  final double feedingWeightKg;
  final double idealWeightKg;
  final double actualWeightKg; // 真の実体重(現体重)
  final double referenceWeightKg; // 栄養計算に用いた参照体重(浮腫/AKIで平時体重に切替)
  final String basisLabel; // 計算根拠（UI表示用）
  const EnergyResult({
    required this.kcal,
    required this.feedingWeightKg,
    required this.idealWeightKg,
    required this.actualWeightKg,
    double? referenceWeightKg,
    required this.basisLabel,
  }) : referenceWeightKg = referenceWeightKg ?? actualWeightKg;
}

/// 目標エネルギー（kcal/day）をモデルに応じて算出。
/// H-B / Mifflin は feedingWeight を式に投入（肥満/過体重で補正）。
/// kcal/kg は肥満をASPEN自動上書き。
EnergyResult targetEnergy({
  required EnergyModel model,
  required bool isMale,
  required double weightKg, // 栄養計算に用いる参照体重(浮腫/AKIで平時体重)
  required double heightCm,
  required int age,
  required double activityFactor,
  required double stressFactor,
  double kcalPerKgValue = 25,
  double? measuredREE,
  double? trueActualWeightKg, // 真の実体重(現体重)。省略時は weightKg と同一。
}) {
  final ibw = idealBodyWeight(isMale: isMale, heightCm: heightCm);
  final bmi = bmiOf(weightKg, heightCm);
  final fw = feedingWeight(actualKg: weightKg, heightCm: heightCm, isMale: isMale);
  final actual = trueActualWeightKg ?? weightKg;

  switch (model) {
    case EnergyModel.harrisBenedict:
      final bee = harrisBenedictBee(
          isMale: isMale, weightKg: fw, heightCm: heightCm, age: age);
      return EnergyResult(
        kcal: bee * activityFactor * stressFactor,
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: actual,
        referenceWeightKg: weightKg,
        basisLabel: 'H-B×AF×SF',
      );
    case EnergyModel.mifflinStJeor:
      final ree = mifflinStJeorRee(
          isMale: isMale, weightKg: fw, heightCm: heightCm, age: age);
      return EnergyResult(
        kcal: ree, // Mifflin REE をそのまま目標とする(AF/SFは用いない)
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: actual,
        referenceWeightKg: weightKg,
        basisLabel: 'Mifflin REE',
      );
    case EnergyModel.kcalPerKg:
      if (bmi >= 30) {
        // 肥満(BMI≥30, ESPEN): 補正体重 × 20–25 kcal/kg（中央22.5）
        final abw = adjustedBodyWeight(actualKg: weightKg, ibwKg: ibw);
        return EnergyResult(
          kcal: abw * 22.5,
          feedingWeightKg: abw,
          idealWeightKg: ibw,
          actualWeightKg: actual,
        referenceWeightKg: weightKg,
          basisLabel: '肥満 補正体重×22.5 (ESPEN)',
        );
      }
      return EnergyResult(
        kcal: fw * kcalPerKgValue,
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: actual,
        referenceWeightKg: weightKg,
        basisLabel: '${kcalPerKgValue.toStringAsFixed(0)} kcal/kg',
      );
    case EnergyModel.indirectCalorimetry:
      final ree = measuredREE ?? 0;
      return EnergyResult(
        kcal: ree, // 実測REEをそのまま目標とする(AF/SFは用いない)
        feedingWeightKg: fw,
        idealWeightKg: ibw,
        actualWeightKg: actual,
        referenceWeightKg: weightKg,
        basisLabel: '実測REE',
      );
  }
}
