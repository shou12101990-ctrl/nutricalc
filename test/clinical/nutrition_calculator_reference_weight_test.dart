import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/nutrition_calculator.dart';
import 'package:nutrition_flutter_app/models/models.dart';

void main() {
  PatientCase patient({
    required double weightKg,
    double? usualWeightKg,
    List<String> conditionTags = const [],
  }) {
    return PatientCase.fromMap({
      'id': 'case-reference-weight',
      'caseCode': 'CASE-RW',
      'currentBed': '01',
      'age': 70,
      'heightCm': 170.0,
      'weightKg': weightKg,
      'sex': 'male',
      'activityFactor': 1.0,
      'stressFactor': 1.0,
      'proteinGoalPerKg': 1.2,
      'createdAt': '2026-06-13T00:00:00.000Z',
      'bedHistory': [],
      'regimenItems': [],
      'selectedProtocolId': 'five_day',
      'zeroMenuConfig': {
        'targetKcal': 1500,
        'npcNRatio': 150,
        'lipidGramPerKg': 0.4,
        'glucoseProductName': '70% グルコース',
      },
      'energyModel': 'kcalPerKg',
      'kcalPerKgValue': 25,
      'conditionTags': conditionTags,
      if (usualWeightKg != null) 'usualWeightKg': usualWeightKg,
    });
  }

  test('AKIで現体重が平時体重を明らかに上回る場合は平時体重を栄養計算に使う', () {
    final c = patient(
      weightKg: 70,
      usualWeightKg: 50,
      conditionTags: ['aki'],
    );

    expect(NutritionCalculator.referenceWeightKg(c), 50);
    expect(NutritionCalculator.targetEnergy(c), closeTo(1250, 0.01));
    expect(NutritionCalculator.targetProtein(c), closeTo(45, 0.01));
  });

  test('溢水・浮腫タグでも平時体重を栄養計算に使う', () {
    final fluidOverload = patient(
      weightKg: 70,
      usualWeightKg: 50,
      conditionTags: ['fluid_overload'],
    );
    final edema = patient(
      weightKg: 70,
      usualWeightKg: 50,
      conditionTags: ['edema'],
    );

    expect(NutritionCalculator.referenceWeightKg(fluidOverload), 50);
    expect(NutritionCalculator.referenceWeightKg(edema), 50);
  });

  test('参照体重タグがない場合は平時体重が登録されても現体重を維持する', () {
    final c = patient(weightKg: 70, usualWeightKg: 50);

    expect(NutritionCalculator.referenceWeightKg(c), 70);
    expect(NutritionCalculator.targetEnergy(c), closeTo(1750, 0.01));
    expect(NutritionCalculator.targetProtein(c), closeTo(84, 0.01));
  });

  test('AKIでも現体重が平時体重を上回らない場合は過大栄養回避のため現体重を維持する', () {
    final c = patient(
      weightKg: 48,
      usualWeightKg: 50,
      conditionTags: ['aki'],
    );

    expect(NutritionCalculator.referenceWeightKg(c), 48);
    expect(NutritionCalculator.targetEnergy(c), closeTo(1200, 0.01));
  });
}
