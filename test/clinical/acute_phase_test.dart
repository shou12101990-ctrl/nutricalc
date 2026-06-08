import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/energy.dart';

/// 急性期の各日目標kcal(full nutrition)。
/// frac(day)=min(等差ランプ, 係数上限) を realFull に掛ける割合計算。
/// 初日は startFraction(<1) で必ず full 未満(構造的保証)。30kcal/kgは廃止。
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
        kcal25UntilDay: u25,
      );

  group('ユーザー定義プレビュー(60kg・full30kcal/kg=1800・達成day5・20〜day2・25〜day4)', () {
    test('day1: 20上限 1200', () => expect(k(1), closeTo(1200, 0.5)));
    test('day2: 20上限 1200', () => expect(k(2), closeTo(1200, 0.5)));
    test('day3: 25上限 1500', () => expect(k(3), closeTo(1500, 0.5)));
    test('day4: 25上限 1500', () => expect(k(4), closeTo(1500, 0.5)));
    test('day5: full達成 1800', () => expect(k(5), closeTo(1800, 0.5)));
    test('day6: full維持 1800', () => expect(k(6), closeTo(1800, 0.5)));
  });

  group('【回帰】初日からfullにならない(あらゆる目標値で day1 < full)', () {
    for (final kpk in [15.0, 18.0, 20.0, 22.5, 25.0, 30.0, 35.0]) {
      test('目標${kpk}kcal/kg: day1 < full', () {
        const fw = 60.0;
        final full = kpk * fw;
        final d1 = k(1, fw: fw, full: full, f: 5, u20: 2, u25: 4);
        expect(d1, lessThan(full),
            reason: '目標${kpk}kcal/kgで初日がfull($full)になった: $d1');
        // 達成日(day5)では full に到達
        final d5 = k(5, fw: fw, full: full, f: 5, u20: 2, u25: 4);
        expect(d5, closeTo(full, full * 0.001));
      });
    }
    test('低目標(20kcal/kg=1200): day1=70%=840(初日full回避)', () {
      expect(k(1, full: 1200), closeTo(840, 1.0));
      expect(k(5, full: 1200), closeTo(1200, 0.5));
    });
  });

  group('単調非減少・full達成日でfull', () {
    test('full達成=day8でも単調非減少しday8でfull', () {
      double kk(int d) => k(d, f: 8, u20: 2, u25: 4);
      for (var d = 1; d < 8; d++) {
        expect(kk(d + 1), greaterThanOrEqualTo(kk(d) - 1e-6));
      }
      expect(kk(8), closeTo(1800, 0.5));
      expect(kk(1), lessThan(1800));
    });
  });
}
