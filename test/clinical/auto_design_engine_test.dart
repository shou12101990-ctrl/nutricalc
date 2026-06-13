import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/clinical/auto_design_engine.dart';
import 'package:nutrition_flutter_app/clinical/clinical_event.dart';
import 'package:nutrition_flutter_app/clinical/refeeding.dart';
import 'package:nutrition_flutter_app/clinical/source_tier.dart';

void main() {
  group('PhaseTemplateEngine', () {
    test('preserves fixed EN ramp and oral rehabilitation ladder', () {
      final days = const PhaseTemplateEngine().buildTimeline(
        rampDays: 5,
        enStartDay: 6,
        oralRehabStartDay: 13,
      );

      expect(days.map((d) => d.enDoseCode).take(12).toList(), [
        '0',
        '0',
        '0',
        '0',
        '0',
        'r10',
        'r20',
        'r30',
        'r40',
        'p3',
        'p6',
        'p6',
      ]);
      expect(days[12].mode, TemplateRouteMode.oral);
      expect(days[12].mealSlots, 1);
      expect(days[13].mealSlots, 2);
      expect(days[14].mealSlots, 3);
      expect(days[15].mealPacPerSlot, 2);
      expect(days.every((d) => d.sourceTier == SourceTier.uxPreset), isTrue);
    });
  });

  group('ClinicalEventOverlayAdapter', () {
    test('EN hold changes only the derived day and keeps template intact', () {
      const template = PhaseTemplateDay(
        day: 8,
        mode: TemplateRouteMode.tpnEn,
        enDoseCode: 'r30',
        mealSlots: 0,
        mealPacPerSlot: 0,
        targetPercent: 80,
      );
      final result = const ClinicalEventOverlayAdapter().derive(
        template: template,
        events: const [
          ClinicalEvent(
            id: 'hold',
            type: ClinicalEventType.enHold,
            startDay: 8,
            endDay: 10,
            parameters: {'hold_rate_ml_h': 20},
          ),
        ],
      );

      expect(result.templatePlan.enDoseCode, 'r30');
      expect(result.derivedPlan.enDoseCode, 'r20');
      expect(result.alerts.single.ruleId, 'EN_HOLD_OVERLAY');
    });
  });

  group('ClinicalStateNormalizer', () {
    test(
        'uses usual/pre-hospital weight for AKI only when current weight is higher',
        () {
      const normalizer = ClinicalStateNormalizer();

      final overloaded = normalizer.normalize(
        conditionTags: {'aki'},
        actualWeightKg: 70,
        usualOrPrehospitalWeightKg: 50,
      );
      final weightLoss = normalizer.normalize(
        conditionTags: {'aki'},
        actualWeightKg: 48,
        usualOrPrehospitalWeightKg: 50,
      );
      final edema = normalizer.normalize(
        conditionTags: {'edema'},
        actualWeightKg: 70,
        usualOrPrehospitalWeightKg: 50,
      );

      expect(overloaded.referenceWeightKg, 50);
      expect(weightLoss.referenceWeightKg, 48);
      expect(edema.referenceWeightKg, 50);
    });
  });

  group('EnergyTargetBuilder', () {
    test('initial ICU energy is band-based and does not chase exact full kcal',
        () {
      final band = const EnergyTargetBuilder().build(
        const EnergyTargetInput(
          day: 2,
          referenceWeightKg: 60,
          estimatedFullKcal: 1800,
        ),
      );

      expect(band.ruleId, 'ENERGY_INITIAL_ICU_BAND');
      expect(band.hardMaxKcal, 1500);
      expect(band.greenMaxKcal, 1260);
      expect(band.classify(1250), BandLevel.green);
      expect(band.classify(1600), BandLevel.hardViolation);
    });

    test('measured EE after day 3 uses 80-100% green band', () {
      final band = const EnergyTargetBuilder().build(
        const EnergyTargetInput(
          day: 4,
          referenceWeightKg: 60,
          estimatedFullKcal: 1800,
          measuredEnergyExpenditureKcal: 1900,
        ),
      );

      expect(band.ruleId, 'ENERGY_MEASURED_EE_AFTER_DAY3');
      expect(band.greenMinKcal, 1520);
      expect(band.greenMaxKcal, 1900);
    });

    test('high refeeding risk caps day 1 at 10 kcal/kg', () {
      final band = const EnergyTargetBuilder().build(
        const EnergyTargetInput(
          day: 1,
          referenceWeightKg: 50,
          estimatedFullKcal: 1500,
          refeedingRiskTier: RefeedingTier.high,
          feedingDay: 1,
        ),
      );

      expect(band.hardMaxKcal, 500);
      expect(band.classify(600), BandLevel.hardViolation);
    });
  });

  group('ProteinTargetBuilder', () {
    test('stable non-dialysis CKD uses 0.6-0.8 g/kg/day', () {
      final band = const ProteinTargetBuilder().build(
        const ProteinTargetInput(conditionTags: {'renal'}),
      );

      expect(band.ruleId, 'PROTEIN_STABLE_CKD_NO_KRT');
      expect(band.minGPerKg, 0.6);
      expect(band.maxGPerKg, 0.8);
      expect(band.requiresReview, isTrue);
    });

    test('SLED uses CRRT-like 1.5-1.7 and suppresses CKD restriction', () {
      final band = const ProteinTargetBuilder().build(
        const ProteinTargetInput(
          conditionTags: {'renal', 'critical'},
          activeRrt: RrtModality.sled,
        ),
      );

      expect(band.ruleId, 'PROTEIN_SLED_PIKRT_LIKE');
      expect(band.minGPerKg, 1.5);
      expect(band.maxGPerKg, 1.7);
      expect(band.suppressesStableCkdRestriction, isTrue);
    });

    test('CRRT uses 1.5-1.7 and is not reduced to delay KRT', () {
      final band = const ProteinTargetBuilder().build(
        const ProteinTargetInput(
          conditionTags: {'renal'},
          activeRrt: RrtModality.crrt,
        ),
      );

      expect(band.ruleId, 'PROTEIN_CRRT_CKRT');
      expect(band.designGPerKg, 1.6);
    });
  });

  group('Micronutrients', () {
    test('PN without MVI/trace creates maintenance alerts', () {
      final result = const MicronutrientMaintenanceEngine().assess(
        const MicronutrientCoverageInput(pnActive: true),
        3,
      );

      expect(result.vitamins, MicronutrientCoverageStatus.red);
      expect(result.traceElements, MicronutrientCoverageStatus.red);
      expect(
        result.alerts.map((a) => a.ruleId),
        containsAll(
            ['PN_MVI_MAINTENANCE_MISSING', 'PN_TRACE_MAINTENANCE_MISSING']),
      );
    });

    test('partial EN is amber instead of exact micronutrient point matching',
        () {
      final result = const MicronutrientMaintenanceEngine().assess(
        const MicronutrientCoverageInput(
          enActive: true,
          enFormulaVolumeMl: 500,
          enFullVolumeMl: 1500,
        ),
        2,
      );

      expect(result.vitamins, MicronutrientCoverageStatus.amber);
      expect(result.traceElements, MicronutrientCoverageStatus.amber);
      expect(result.alerts.single.ruleId, 'PARTIAL_MICRONUTRIENT_COVERAGE');
    });

    test('CRRT >=14 days creates loss-risk and copper review obligations', () {
      final obligations =
          const MicronutrientAdditionalObligationEngine().evaluate(
        const MicronutrientObligationInput(
          activeRrt: RrtModality.crrt,
          activeRrtDurationDays: 14,
        ),
      );

      expect(
        obligations.map((o) => o.ruleId),
        containsAll([
          'THIAMINE_ADDITIONAL',
          'SELENIUM_ADDITIONAL_CONSIDER',
          'ZINC_ADDITIONAL_CONSIDER',
          'COPPER_MONITORING_REVIEW',
          'CRRT_WATER_SOLUBLE_LOSS_RISK',
        ]),
      );
    });

    test('cholestasis activates manganese toxicity guard', () {
      final obligations = const MicronutrientToxicityGuard().evaluate(
        const MicronutrientToxicityGuardInput(cholestasis: true),
      );

      expect(obligations.single.ruleId, 'MANGANESE_TOXICITY_GUARD');
    });
  });

  group('Candidate filtering and band optimizer', () {
    test('NOMI-style enteral block rejects favorite EN product', () {
      final result = const ProductCandidateFilter().filter(
        const [
          AutoDesignProductCandidate(
            id: 'fav_en',
            name: 'Favorite EN',
            route: CandidateRoute.enteral,
            favorite: true,
          ),
          AutoDesignProductCandidate(
            id: 'pn',
            name: 'PN',
            route: CandidateRoute.parenteral,
          ),
        ],
        const ProductFilterContext(enteralDisabled: true),
      );

      expect(result.accepted.map((p) => p.id), ['pn']);
      expect(result.rejectedReasons['fav_en'], contains('disabled'));
    });

    test('favorites are preferences and never beat hard violations', () {
      const optimizer = BandBasedOptimizer();
      final best = optimizer.chooseBest(const [
        CandidatePlan(
          id: 'favorite_unsafe',
          hasHardViolation: true,
          usesFavoriteCompatibleProduct: true,
          bandLevels: [BandLevel.green],
        ),
        CandidatePlan(
          id: 'plain_green',
          bandLevels: [BandLevel.green],
          packageCount: 3,
        ),
      ]);

      expect(best?.id, 'plain_green');
      expect(
          optimizer
              .score(const CandidatePlan(
                id: 'bad',
                bandLevels: [BandLevel.hardViolation],
              ))
              .rejected,
          isTrue);
    });
  });

  group('AutoDesignEngine facade', () {
    test('build returns target bands with inclusive green and hard boundary',
        () {
      final result = const AutoDesignEngine().build(
        const AutoDesignInput(
          weightKg: 60,
          conditionTags: {'critical'},
          rampDays: 5,
          enStartDay: 6,
          totalDays: 6,
          estimatedFullKcal: 1800,
          nonNutritionalCaloriesStatus: OptionalCaloriesStatus.notIncluded,
        ),
      );

      final energy = result.energyTargets.first;
      expect(energy.classify(energy.greenMinKcal), BandLevel.green);
      expect(energy.classify(energy.greenMaxKcal), BandLevel.green);
      expect(energy.classify(energy.greenMaxKcal + 1), BandLevel.amber);
      expect(energy.classify(energy.hardMaxKcal + 1), BandLevel.hardViolation);

      final protein = result.proteinTargets.first;
      expect(protein.classify(protein.minGPerKg), BandLevel.green);
      expect(protein.classify(protein.maxGPerKg), BandLevel.green);
      expect(protein.classify(protein.maxGPerKg * 1.15 + 0.01), BandLevel.red);
    });

    test('build alerts can be aggregated deterministically by day', () {
      final result = const AutoDesignEngine().build(
        const AutoDesignInput(
          weightKg: 50,
          conditionTags: {'critical'},
          rampDays: 5,
          enStartDay: 2,
          totalDays: 4,
          estimatedFullKcal: 1500,
          nonNutritionalCaloriesStatus: OptionalCaloriesStatus.notIncluded,
          events: [
            ClinicalEvent(
              id: 'crrt',
              type: ClinicalEventType.rrtStart,
              startDay: 2,
              rrtModality: RrtModality.crrt,
            ),
            ClinicalEvent(
              id: 'hold',
              type: ClinicalEventType.enHold,
              startDay: 3,
              endDay: 3,
              parameters: {'hold_rate_ml_h': 15},
            ),
          ],
        ),
      );

      final byDay = <int, List<StructuredNutritionAlert>>{};
      for (final alert in result.alerts) {
        (byDay[alert.day] ??= <StructuredNutritionAlert>[]).add(alert);
      }

      expect(byDay.keys, containsAll([2, 3]));
      expect(
        byDay[2]!.map((a) => a.ruleId),
        contains('OVERLAY_INFO'),
      );
      expect(
        byDay[3]!.map((a) => a.ruleId),
        containsAll(['EN_HOLD_OVERLAY', 'OVERLAY_INFO']),
      );
      expect(
        byDay[3]!.where((a) => a.severity == RuleSeverity.info),
        isNotEmpty,
      );
    });

    test('build resolves template, derived days, targets, alerts, obligations',
        () {
      final result = const AutoDesignEngine().build(
        const AutoDesignInput(
          weightKg: 50,
          conditionTags: {'renal', 'critical'},
          rampDays: 5,
          enStartDay: 2,
          totalDays: 4,
          estimatedFullKcal: 1500,
          refeedingTier: RefeedingTier.high,
          events: [
            ClinicalEvent(
              id: 'crrt',
              type: ClinicalEventType.rrtStart,
              startDay: 2,
              rrtModality: RrtModality.crrt,
            ),
            ClinicalEvent(
              id: 'hold',
              type: ClinicalEventType.enHold,
              startDay: 3,
              endDay: 3,
              parameters: {'hold_rate_ml_h': 15},
            ),
          ],
          micronutrientCoverageInput:
              MicronutrientCoverageInput(pnActive: true),
          micronutrientObligationInput: MicronutrientObligationInput(),
        ),
      );

      expect(result.templateDays, hasLength(8));
      expect(result.derivedDays[2].templatePlan.enDoseCode, 'r20');
      expect(result.derivedDays[2].derivedPlan.enDoseCode, 'r15');
      expect(result.energyTargets.first.hardMaxKcal, 500);
      expect(result.proteinTargets[1].ruleId, 'PROTEIN_CRRT_CKRT');
      expect(
        result.alerts.map((a) => a.ruleId),
        containsAll([
          'EN_HOLD_OVERLAY',
          'PN_MVI_MAINTENANCE_MISSING',
          'PN_TRACE_MAINTENANCE_MISSING',
        ]),
      );
      expect(
        result.obligations.map((o) => o.ruleId),
        containsAll([
          'THIAMINE_ADDITIONAL',
          'SELENIUM_ADDITIONAL_CONSIDER',
          'ZINC_ADDITIONAL_CONSIDER',
          'CRRT_WATER_SOLUBLE_LOSS_RISK',
        ]),
      );
      expect(result.sourceBadges, contains('UXプリセット'));
      expect(result.sourceBadges, contains('ユーザーイベント'));
      expect(result.sourceBadges, contains('ガイドライン'));
    });
  });
}
