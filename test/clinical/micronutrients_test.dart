import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/infusion.dart' show AlertLevel;
import 'package:nutrition_flutter_app/clinical/micronutrients.dart';

void main() {
  group('aggregateMicro', () {
    test('単位数を掛けて合算', () {
      final totals = aggregateMicro([
        const MicroContribution({
          'elec': {'Na': 10.0, 'K': 5.0, 'P': 2.0},
          'trace': {'Zn': 30.0}
        }, 2),
        const MicroContribution({
          'elec': {'Na': 20.0}
        }, 1),
      ]);
      expect(totals.of('elec', 'Na'), closeTo(40, 0.001)); // 10×2+20
      expect(totals.of('elec', 'K'), closeTo(10, 0.001));
      expect(totals.of('trace', 'Zn'), closeTo(60, 0.001));
    });

    test('micro=null や multiplier=0 は無視', () {
      final totals = aggregateMicro([
        const MicroContribution(null, 3),
        const MicroContribution({
          'elec': {'Na': 50.0}
        }, 0),
      ]);
      expect(totals.isEmpty, isTrue);
    });
  });

  group('microAlerts UL', () {
    test('Na 110 mEq → 食塩6g超アラート（caution）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 110.0}, trace: {}, vit: {}),
      );
      final na = alerts.firstWhere((a) => a.nutrient == 'Na');
      expect(na.level, AlertLevel.caution);
      expect(na.message, contains('食塩'));
    });
    test('Na 130 mEq → danger（7.5g超）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 130.0}, trace: {}, vit: {}),
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'Na').level,
          AlertLevel.danger);
    });
    test('Na 90 mEq → アラートなし', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 90.0}, trace: {}, vit: {}),
      );
      expect(alerts.where((a) => a.nutrient == 'Na'), isEmpty);
    });
    test('Mn UL超過 → danger（神経毒性）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {'Mn': 250.0}, vit: {}),
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'Mn').level,
          AlertLevel.danger);
    });
    test('Mn UL未満でも長期TPNなら caution', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {'Mn': 20.0}, vit: {}),
        longTermTpn: true,
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'Mn').level,
          AlertLevel.caution);
    });
    test('Se UL 性差（女350μg=4.43μmol）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {'Se': 5.0}, vit: {}),
        isMale: false,
      );
      expect(alerts.where((a) => a.nutrient == 'Se'), isNotEmpty);
    });
    test('VitA UL 2700超', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {'A': 3000.0}),
      );
      expect(alerts.where((a) => a.nutrient == 'VitA'), isNotEmpty);
    });
  });
}
