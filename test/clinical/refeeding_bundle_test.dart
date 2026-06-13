import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/refeeding.dart';
import 'package:nutrition_flutter_app/clinical/refeeding_bundle.dart';

void main() {
  group('buildRefeedingBundle（§10/§24.3）', () {
    test('高リスク → cap ramp 10→15→20→full + B1 + モニタ必須(§24.3-1)', () {
      final b = buildRefeedingBundle(tier: RefeedingTier.high, fullKcalPerKg: 25);
      expect(b.isActive, isTrue);
      expect(b.kcalPerKgRamp.first, 10);
      expect(b.kcalPerKgRamp.last, 25);
      expect(b.thiamineRequired, isTrue);
      expect(b.monitor.alertIfMissingLabs, isTrue); // ベースライン欠落でアラート(§24.3-4)
      expect(b.mviTraceMaintenanceRequired, isTrue); // §24.3-6
    });

    test('超高リスク → 5 kcal/kgから開始(§24.3-2)', () {
      final b =
          buildRefeedingBundle(tier: RefeedingTier.extreme, fullKcalPerKg: 25);
      expect(b.kcalPerKgRamp.first, 5);
      expect(b.monitor.highRiskFirst72h.contains('心電図'), isTrue);
    });

    test('cap_includes に AA/dextrose/propofol/KRT液が含まれる(§24.3-3, §10)', () {
      final b = buildRefeedingBundle(tier: RefeedingTier.high);
      expect(b.capIncludes.contains('amino_acid_solution_calories'), isTrue);
      expect(b.capIncludes.contains('dextrose_iv_fluids'), isTrue);
      expect(b.capIncludes.contains('propofol_if_entered'), isTrue);
      expect(b.capIncludes.contains('krt_solution_calories_if_entered'), isTrue);
    });

    test('電解質補充は P/K/Mg', () {
      final b = buildRefeedingBundle(tier: RefeedingTier.high);
      expect(b.electrolyteRepletion, ['phosphate', 'potassium', 'magnesium']);
    });

    test('リスク無し → 非アクティブ・B1不要・full即時', () {
      final b = buildRefeedingBundle(tier: RefeedingTier.none, fullKcalPerKg: 25);
      expect(b.isActive, isFalse);
      expect(b.thiamineRequired, isFalse);
      expect(b.kcalPerKgRamp, [25]);
      expect(b.monitor.alertIfMissingLabs, isFalse);
    });
  });
}
