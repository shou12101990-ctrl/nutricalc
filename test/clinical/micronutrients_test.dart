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

    test('複数ソースの同一栄養素は加算（重複ではなく正しい合算）', () {
      // EN + 維持輸液 + trace mix が各々 Na/Mg を持つ場合、ソース横断で合算される
      final t = aggregateMicro([
        const MicroContribution({
          'elec': {'Na': 30.0, 'Mg': 4.0}
        }, 1), // EN
        const MicroContribution({
          'elec': {'Na': 50.0}
        }, 1), // 維持輸液
        const MicroContribution({
          'elec': {'Mg': 8.0}
        }, 1), // trace mix
      ]);
      expect(t.of('elec', 'Na'), closeTo(80, 0.001));
      expect(t.of('elec', 'Mg'), closeTo(12, 0.001));
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
    test('Na 130 mEq → 食塩7g超アラート（caution）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 130.0}, trace: {}, vit: {}),
      );
      final na = alerts.firstWhere((a) => a.nutrient == 'Na');
      expect(na.level, AlertLevel.caution);
      expect(na.message, contains('食塩'));
    });
    test('Na 170 mEq → danger（平均摂取量9.6g以上）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 170.0}, trace: {}, vit: {}),
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'Na').level,
          AlertLevel.danger);
    });
    test('Na 100 mEq → アラートなし（食塩7g未満）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {'Na': 100.0}, trace: {}, vit: {}),
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

  group('microAlerts 病態別ガイダンス', () {
    test('胆汁うっ滞 + Mn含有 → danger（Mn-free切替）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {'Mn': 20.0}, vit: {}),
        cholestasis: true,
      );
      final mn = alerts.firstWhere((a) => a.nutrient == 'Mn');
      expect(mn.level, AlertLevel.danger);
      expect(mn.message, contains('Mn-free'));
    });
    test('肝障害 + Cu含有 → caution（減量・モニタ）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {'Cu': 5.0}, vit: {}),
        liver: true,
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'Cu').level,
          AlertLevel.caution);
    });
    test('腎不全(非CRRT) → Cr/Mn蓄積ガイダンス', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {}),
        renal: true,
      );
      expect(alerts.where((a) => a.nutrient == 'Cr/Mn'), isNotEmpty);
    });
    test('腎不全 + CRRT → 蓄積でなく補充側（CRRTアラート, Cr/Mnは出さない）', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {}),
        renal: true,
        crrt: true,
      );
      expect(alerts.where((a) => a.nutrient == 'CRRT'), isNotEmpty);
      expect(alerts.where((a) => a.nutrient == 'Cr/Mn'), isEmpty);
    });
    test('高排出消化管 → Zn補充ガイダンス', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {}),
        giLoss: true,
      );
      final zn = alerts.firstWhere((a) => a.nutrient == 'Zn');
      expect(zn.message, contains('12mg/L'));
    });
    test('糖負荷 + Wernickeリスク + B1なし → B1 danger', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {}),
        glucoseLoad: true,
        wernickeRisk: true,
      );
      expect(alerts.firstWhere((a) => a.nutrient == 'B1').level,
          AlertLevel.danger);
    });
    test('糖負荷 + B1 3mg投与済み → B1アラートなし', () {
      final alerts = microAlerts(
        const MicroTotals(elec: {}, trace: {}, vit: {'B1': 3.0}),
        glucoseLoad: true,
        wernickeRisk: true,
      );
      expect(alerts.where((a) => a.nutrient == 'B1'), isEmpty);
    });
  });
}
