import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/energy.dart';

/// 急性期の各日目標kcal(full nutrition) = 等差ランプ ∧ 係数上限(20/25kcal/kg)。
/// 30kcal/kgは廃止。係数は「day何まで(until)」で指定。
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

  group('等差ランプ＋係数上限 (ユーザー定義のプレビューと一致)', () {
    // 60kg・本来full=30kcal/kg(1800)・full達成=day5・20は〜day2・25は〜day4
    test('day1: 20kcal/kg上限 = 1200', () => expect(k(1), closeTo(1200, 0.5)));
    test('day2: 20上限 = 1200', () => expect(k(2), closeTo(1200, 0.5)));
    test('day3: 25上限 = 1500', () => expect(k(3), closeTo(1500, 0.5)));
    test('day4: 25上限 = 1500', () => expect(k(4), closeTo(1500, 0.5)));
    test('day5: full達成 = 1800', () => expect(k(5), closeTo(1800, 0.5)));
    test('day6: full維持 = 1800', () => expect(k(6), closeTo(1800, 0.5)));
  });

  group('full達成日(f=8)で等差ランプが緩く、min(等差, 係数上限)が効く', () {
    // full達成=day8, 20は〜day2, 25は〜day4。linear=1200+600*(d-1)/7。
    double kk(int d) => k(d, f: 8, u20: 2, u25: 4);
    test('day1: 1200 (20上限=linear起点)', () => expect(kk(1), closeTo(1200, 0.5)));
    test('day2: 20上限で1200 (linear1285.7>1200)',
        () => expect(kk(2), closeTo(1200, 0.5)));
    test('day4: linear1457<25上限1500 → 1457.14',
        () => expect(kk(4), closeTo(1457.14, 1.0)));
    test('day5: 上限解除でlinear=1542.86',
        () => expect(kk(5), closeTo(1542.86, 1.0)));
    test('day8: full 1800', () => expect(kk(8), closeTo(1800, 0.5)));
    test('単調非減少', () {
      for (var d = 1; d < 8; d++) {
        expect(kk(d + 1), greaterThanOrEqualTo(kk(d) - 1e-6));
      }
    });
  });

  group('低目標(realFull < 25kcal/kg)では上限がfullでクランプ', () {
    // full=1000(<25*60=1500), fw=60
    test('day1: min(20*60=1200, full1000)=1000', () {
      expect(k(1, full: 1000), closeTo(1000, 0.5));
    });
    test('day5: full 1000', () => expect(k(5, full: 1000), closeTo(1000, 0.5)));
  });
}
