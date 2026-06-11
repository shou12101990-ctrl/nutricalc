import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/main.dart';

/// 高用量チアミン(B1)自動加注の本数ロジック。
/// 絶食≥5日 + 糖質投与 + 初期10日 + B1<200mg のとき、目標200mgへ到達する本数を返す。
void main() {
  int u({
    int fastingDays = 5,
    int feedingDay = 1,
    bool carbPresent = true,
    double currentB1Mg = 0,
    double b1PerUnitMg = 100,
    bool refeedingRisk = false,
    bool alcoholUse = false,
  }) =>
      NutritionCalculator.thiamineUnitsToAdd(
        fastingDays: fastingDays,
        feedingDay: feedingDay,
        carbPresent: carbPresent,
        currentB1Mg: currentB1Mg,
        b1PerUnitMg: b1PerUnitMg,
        refeedingRisk: refeedingRisk,
        alcoholUse: alcoholUse,
      );

  group('thiamineUnitsToAdd', () {
    test('絶食5日+糖質+B1=0 → 100mg製剤2本(=200mg)', () => expect(u(), 2));
    test('絶食4日(<5) → 0', () => expect(u(fastingDays: 4), 0));
    test('糖質なし → 0', () => expect(u(carbPresent: false), 0));
    test('初期10日超(feedingDay11) → 0', () => expect(u(feedingDay: 11), 0));
    test('feedingDay10は対象(=2本)', () => expect(u(feedingDay: 10), 2));
    test('既にB1≥200mg → 0', () => expect(u(currentB1Mg: 200), 0));
    test('B1既に50mg → 不足150mgで2本', () => expect(u(currentB1Mg: 50), 2));
    test('B1製剤量0 → 0(ゼロ割回避)', () => expect(u(b1PerUnitMg: 0), 0));
    test('上限10本でクランプ', () => expect(u(b1PerUnitMg: 1), 10));
    // thiamine_gate: 絶食<5日でも refeedingリスク/アルコールでゲート成立
    test('gate: 絶食0日でもrefeedingリスクで2本', () =>
        expect(u(fastingDays: 0, refeedingRisk: true), 2));
    test('gate: 絶食0日でもアルコール多飲で2本', () =>
        expect(u(fastingDays: 0, alcoholUse: true), 2));
    test('gate: いずれも無し(絶食0日)なら0', () => expect(u(fastingDays: 0), 0));
  });
}
