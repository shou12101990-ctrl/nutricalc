import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/energy.dart';

/// 急性期 各日目標kcal = min(真の等差ランプ, 係数上限)。
/// 等差ランプ: day1 = (1/N)を[15%,30%]にクランプ → 毎日線形で full達成日(N) に100%。
void main() {
  double k(int day,
          {double fw = 60,
          double full = 1800,
          int f = 5,
          int u20 = 2,
          int u25 = 4}) =>
      acutePhaseTargetKcal(
          day: day,
          feedingWeightKg: fw,
          realFullKcal: full,
          fullAchieveDay: f,
          kcal20UntilDay: u20,
          kcal25UntilDay: u25);

  group('プレビュー(60kg/full1800/N=5/20〜day2/25〜day4): 毎日等差で増加', () {
    test('day1=360(20%)', () => expect(k(1), closeTo(360, 0.5)));
    test('day2=720(40%)', () => expect(k(2), closeTo(720, 0.5)));
    test('day3=1080(60%)', () => expect(k(3), closeTo(1080, 0.5)));
    test('day4=1440(80%)', () => expect(k(4), closeTo(1440, 0.5)));
    test('day5=1800(full)', () => expect(k(5), closeTo(1800, 0.5)));
  });

  group('GenSpark再現(50kg/full1500/N=5/20〜day3/25〜day12)', () {
    double g(int d) => k(d, fw: 50, full: 1500, f: 5, u20: 3, u25: 12);
    test('day1=300', () => expect(g(1), closeTo(300, 0.5)));
    test('day2=600', () => expect(g(2), closeTo(600, 0.5)));
    test('day3=900', () => expect(g(3), closeTo(900, 0.5)));
    test('day4=1200', () => expect(g(4), closeTo(1200, 0.5)));
    test('day5=1250(25上限)', () => expect(g(5), closeTo(1250, 0.5)));
    test('day12=1250(25上限継続)', () => expect(g(12), closeTo(1250, 0.5)));
    test('day13=1500(上限解除でfull)', () => expect(g(13), closeTo(1500, 0.5)));
  });

  group('day1割合 = (1/N)を[15%,30%]にクランプ', () {
    test('N=5 → 20%', () => expect(k(1, f: 5) / 1800, closeTo(0.20, 0.001)));
    test('N=4 → 25%', () => expect(k(1, f: 4) / 1800, closeTo(0.25, 0.001)));
    test('N=3 → 30%(上限cap)', () => expect(k(1, f: 3) / 1800, closeTo(0.30, 0.001)));
    test('N=7 → 15%(下限floor)',
        () => expect(k(1, f: 7) / 1800, closeTo(0.15, 0.001)));
    test('N=12 → 15%(下限floor)',
        () => expect(k(1, f: 12) / 1800, closeTo(0.15, 0.001)));
  });

  group('【回帰】初日<full(全目標域15〜35kcal/kg)・達成日でfull・単調非減少', () {
    for (final kpk in [15.0, 18.0, 20.0, 22.5, 25.0, 30.0, 35.0]) {
      test('目標${kpk}kcal/kg', () {
        const fw = 60.0;
        final full = kpk * fw;
        expect(k(1, fw: fw, full: full), lessThan(full),
            reason: '目標${kpk}で初日full');
        expect(k(5, fw: fw, full: full), closeTo(full, full * 0.001));
      });
    }
    test('単調非減少(N=8)', () {
      double m(int d) => k(d, f: 8, u20: 2, u25: 6);
      for (var d = 1; d < 8; d++) {
        expect(m(d + 1), greaterThanOrEqualTo(m(d) - 1e-6));
      }
    });
  });

  group('タンパクの等差ランプ(acutePhaseRampFraction: 係数上限なし)', () {
    test('N=5: day1=20%→ day5=100% を毎日等差', () {
      expect(acutePhaseRampFraction(day: 1, fullAchieveDay: 5),
          closeTo(0.20, 0.001));
      expect(acutePhaseRampFraction(day: 2, fullAchieveDay: 5),
          closeTo(0.40, 0.001));
      expect(acutePhaseRampFraction(day: 3, fullAchieveDay: 5),
          closeTo(0.60, 0.001));
      expect(acutePhaseRampFraction(day: 5, fullAchieveDay: 5),
          closeTo(1.00, 0.001));
    });
    test('day1割合は[15%,30%]にクランプ(N=12→15%, N=3→30%)', () {
      expect(acutePhaseRampFraction(day: 1, fullAchieveDay: 12),
          closeTo(0.15, 0.001));
      expect(acutePhaseRampFraction(day: 1, fullAchieveDay: 3),
          closeTo(0.30, 0.001));
    });
    test('単調非減少', () {
      for (var d = 1; d < 8; d++) {
        expect(acutePhaseRampFraction(day: d + 1, fullAchieveDay: 8),
            greaterThanOrEqualTo(
                acutePhaseRampFraction(day: d, fullAchieveDay: 8) - 1e-9));
      }
    });
  });

  group('effectiveFullDay(設定上のfull達成と実到達日の分離)', () {
    test('60kg/full1800/N=5/25〜day4 → 実到達day5', () {
      expect(
          effectiveFullDay(
              feedingWeightKg: 60,
              realFullKcal: 1800,
              fullAchieveDay: 5,
              kcal20UntilDay: 2,
              kcal25UntilDay: 4),
          5);
    });
    test('50kg/full1500/N=5/25〜day12 → 実到達day13(係数上限が支配)', () {
      expect(
          effectiveFullDay(
              feedingWeightKg: 50,
              realFullKcal: 1500,
              fullAchieveDay: 5,
              kcal20UntilDay: 3,
              kcal25UntilDay: 12),
          13);
    });
  });
}
