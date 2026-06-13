/// ICU nutrition auto-design foundation modules.
///
/// This is the complementary layer around clinical_event.dart/event_overlay.dart:
/// target bands, micronutrient obligations, candidate filtering, band scoring,
/// and explanation helpers. It stays Flutter-free and deterministic.
library;

import 'dart:math' as math;

import 'clinical_event.dart';
import 'conditions.dart' as conditions;
import 'event_overlay.dart';
import 'micronutrient_obligations.dart' as micronutrients;
import 'refeeding.dart';
import 'source_tier.dart';

enum RuleSeverity { hard, major, soft, info }

enum BandLevel { green, amber, red, hardViolation }

class StructuredNutritionAlert {
  final String ruleId;
  final SourceTier sourceTier;
  final RuleSeverity severity;
  final int day;
  final String? eventId;
  final String metric;
  final Object? actual;
  final Object? expected;
  final Object? originalTemplateValue;
  final Object? derivedValue;
  final String explanation;
  final String? suggestedRepair;
  final bool autoRepaired;
  final String? repairReason;

  const StructuredNutritionAlert({
    required this.ruleId,
    required this.sourceTier,
    required this.severity,
    required this.day,
    required this.metric,
    required this.explanation,
    this.eventId,
    this.actual,
    this.expected,
    this.originalTemplateValue,
    this.derivedValue,
    this.suggestedRepair,
    this.autoRepaired = false,
    this.repairReason,
  });
}

enum TemplateRouteMode { tpn, tpnEn, en, oral, npo, pnOnly }

extension TemplateRouteModeMeta on TemplateRouteMode {
  String get key => switch (this) {
        TemplateRouteMode.tpn => 'TPN',
        TemplateRouteMode.tpnEn => 'TPN+EN',
        TemplateRouteMode.en => 'EN',
        TemplateRouteMode.oral => 'ORAL',
        TemplateRouteMode.npo => 'NPO',
        TemplateRouteMode.pnOnly => 'PN_ONLY',
      };

  bool get hasEnteral =>
      this == TemplateRouteMode.tpnEn || this == TemplateRouteMode.en;
  bool get hasOral => this == TemplateRouteMode.oral;
}

class PhaseTemplateDay {
  final int day;
  final TemplateRouteMode mode;
  final String enDoseCode;
  final int mealSlots;
  final int mealPacPerSlot;
  final double targetPercent;
  final SourceTier sourceTier;

  const PhaseTemplateDay({
    required this.day,
    required this.mode,
    required this.enDoseCode,
    required this.mealSlots,
    required this.mealPacPerSlot,
    required this.targetPercent,
    this.sourceTier = SourceTier.uxPreset,
  });

  double get enRateMlH {
    if (!enDoseCode.startsWith('r')) return 0;
    return double.tryParse(enDoseCode.substring(1)) ?? 0;
  }

  int get enPac {
    if (!enDoseCode.startsWith('p')) return 0;
    return int.tryParse(enDoseCode.substring(1)) ?? 0;
  }

  PhaseTemplateDay copyWith({
    TemplateRouteMode? mode,
    String? enDoseCode,
    int? mealSlots,
    int? mealPacPerSlot,
    double? targetPercent,
    SourceTier? sourceTier,
  }) =>
      PhaseTemplateDay(
        day: day,
        mode: mode ?? this.mode,
        enDoseCode: enDoseCode ?? this.enDoseCode,
        mealSlots: mealSlots ?? this.mealSlots,
        mealPacPerSlot: mealPacPerSlot ?? this.mealPacPerSlot,
        targetPercent: targetPercent ?? this.targetPercent,
        sourceTier: sourceTier ?? this.sourceTier,
      );
}

class PhaseTemplateEngine {
  static const enRampSequence = ['r10', 'r20', 'r30', 'r40', 'p3', 'p6', 'p6'];
  static const enRampDays = 7;
  static const mealRampDays = 6;
  static const mealLadder = [
    [1, 1],
    [2, 1],
    [3, 1],
    [3, 2],
  ];

  const PhaseTemplateEngine();

  List<PhaseTemplateDay> buildTimeline({
    required int rampDays,
    required int enStartDay,
    required int? oralRehabStartDay,
    int? totalDays,
  }) {
    final enEnd = enStartDay + enRampDays - 1;
    final mealEnd =
        oralRehabStartDay == null ? 0 : oralRehabStartDay + mealRampDays - 1;
    final n = math.max(totalDays ?? 0, math.max(enEnd, mealEnd)).toInt();
    return List.generate(n, (i) {
      final day = i + 1;
      final targetPercent = day <= rampDays
          ? (day * 100.0 / rampDays).clamp(0.0, 100.0).toDouble()
          : 100.0;
      if (oralRehabStartDay != null && day >= oralRehabStartDay) {
        final idx =
            (day - oralRehabStartDay).clamp(0, mealLadder.length - 1).toInt();
        return PhaseTemplateDay(
          day: day,
          mode: TemplateRouteMode.oral,
          enDoseCode: '0',
          mealSlots: mealLadder[idx][0],
          mealPacPerSlot: mealLadder[idx][1],
          targetPercent: targetPercent,
        );
      }
      if (day < enStartDay) {
        return PhaseTemplateDay(
          day: day,
          mode: TemplateRouteMode.tpn,
          enDoseCode: '0',
          mealSlots: 0,
          mealPacPerSlot: 0,
          targetPercent: targetPercent,
        );
      }
      final step = (day - enStartDay).clamp(0, enRampDays - 1).toInt();
      return PhaseTemplateDay(
        day: day,
        mode: step == enRampDays - 1
            ? TemplateRouteMode.en
            : TemplateRouteMode.tpnEn,
        enDoseCode: enRampSequence[step],
        mealSlots: 0,
        mealPacPerSlot: 0,
        targetPercent: targetPercent,
      );
    });
  }
}

enum OptionalCaloriesStatus { unknown, notIncluded, included }

class ClinicalState {
  final Set<String> conditionTags;
  final double actualWeightKg;
  final double referenceWeightKg;
  final String referenceWeightExplanation;
  final RrtModality? activeRrt;
  final int? activeRrtDurationDays;
  final OptionalCaloriesStatus krtFluidCaloriesStatus;
  final double? krtSolutionCaloriesKcalDay;

  const ClinicalState({
    required this.conditionTags,
    required this.actualWeightKg,
    required this.referenceWeightKg,
    required this.referenceWeightExplanation,
    this.activeRrt,
    this.activeRrtDurationDays,
    this.krtFluidCaloriesStatus = OptionalCaloriesStatus.unknown,
    this.krtSolutionCaloriesKcalDay,
  });
}

class ClinicalStateNormalizer {
  const ClinicalStateNormalizer();

  ClinicalState normalize({
    required Set<String> conditionTags,
    required double actualWeightKg,
    double? usualOrPrehospitalWeightKg,
    int day = 1,
    List<ClinicalEvent> events = const [],
    OptionalCaloriesStatus krtFluidCaloriesStatus =
        OptionalCaloriesStatus.unknown,
    double? krtSolutionCaloriesKcalDay,
  }) {
    final activeRrt = activeRrtModalityOnDay(events, day) ??
        _fallbackRrtFromTags(conditionTags);
    final duration = _activeRrtDurationDays(events, day, activeRrt);
    final fluidOverload = conditionTags.contains('fluid_overload') ||
        events.any((e) =>
            e.type == ClinicalEventType.fluidOverload && e.isActiveOnDay(day));
    final preferUsual = (fluidOverload ||
            conditionTags.contains('aki') ||
            conditionTags.contains('edema')) &&
        usualOrPrehospitalWeightKg != null &&
        usualOrPrehospitalWeightKg > 0 &&
        actualWeightKg - usualOrPrehospitalWeightKg > 1.0;
    final ref = preferUsual ? usualOrPrehospitalWeightKg : actualWeightKg;
    final reason = preferUsual
        ? 'usual/pre-hospital weight is used because AKI, edema, or fluid overload is active'
        : 'actual body weight is used';
    return ClinicalState(
      conditionTags: conditionTags,
      actualWeightKg: actualWeightKg,
      referenceWeightKg: ref,
      referenceWeightExplanation: reason,
      activeRrt: activeRrt,
      activeRrtDurationDays: duration,
      krtFluidCaloriesStatus: krtFluidCaloriesStatus,
      krtSolutionCaloriesKcalDay: krtSolutionCaloriesKcalDay,
    );
  }

  RrtModality? _fallbackRrtFromTags(Set<String> tags) {
    if (tags.contains('crrt')) return RrtModality.crrt;
    if (tags.contains('sled')) return RrtModality.sled;
    if (tags.contains('renal_dialysis') || tags.contains('irrt')) {
      return RrtModality.irrt;
    }
    return null;
  }

  int? _activeRrtDurationDays(
      List<ClinicalEvent> events, int day, RrtModality? activeRrt) {
    if (activeRrt == null) return null;
    final starts = events
        .where((e) =>
            e.type == ClinicalEventType.rrtStart &&
            e.rrtModality == activeRrt &&
            e.startDay <= day)
        .toList()
      ..sort((a, b) => b.startDay.compareTo(a.startDay));
    if (starts.isEmpty) return null;
    return day - starts.first.startDay + 1;
  }
}

class EventDerivedDay {
  final PhaseTemplateDay templatePlan;
  final PhaseTemplateDay derivedPlan;
  final DayOverlay overlay;
  final List<StructuredNutritionAlert> alerts;

  const EventDerivedDay({
    required this.templatePlan,
    required this.derivedPlan,
    required this.overlay,
    this.alerts = const [],
  });
}

class ClinicalEventOverlayAdapter {
  const ClinicalEventOverlayAdapter();

  EventDerivedDay derive({
    required PhaseTemplateDay template,
    required List<ClinicalEvent> events,
    bool rrtCalorieUnknown = true,
  }) {
    final overlay = resolveDayOverlay(
      events,
      template.day,
      rrtCalorieUnknown: rrtCalorieUnknown,
    );
    var derived = template;
    final alerts = <StructuredNutritionAlert>[];

    if (overlay.enteralBlocked) {
      derived = derived.copyWith(
        mode: TemplateRouteMode.pnOnly,
        enDoseCode: '0',
        mealSlots: 0,
        mealPacPerSlot: 0,
      );
      alerts.add(StructuredNutritionAlert(
        ruleId: 'ENTERAL_ROUTE_BLOCKED',
        sourceTier: SourceTier.guidelineHard,
        severity: RuleSeverity.hard,
        day: template.day,
        metric: 'route',
        originalTemplateValue: template.mode.key,
        derivedValue: derived.mode.key,
        explanation:
            'Active event blocks enteral/oral route; base template is preserved and only the derived day is changed.',
      ));
    } else if (overlay.route == RouteEffect.holdEn) {
      final event = overlay.activeEvents.firstWhere(
        (e) => e.type == ClinicalEventType.enHold,
        orElse: () => ClinicalEvent(
          id: '_en_hold',
          type: ClinicalEventType.enHold,
          startDay: template.day,
        ),
      );
      final holdRate =
          (event.parameters['hold_rate_ml_h'] as num?)?.toDouble() ?? 20;
      derived = derived.copyWith(
        mode: TemplateRouteMode.tpnEn,
        enDoseCode: 'r${holdRate.round()}',
        mealSlots: 0,
        mealPacPerSlot: 0,
      );
      alerts.add(StructuredNutritionAlert(
        ruleId: 'EN_HOLD_OVERLAY',
        sourceTier: event.sourceTier,
        severity: RuleSeverity.info,
        day: template.day,
        eventId: event.id,
        metric: 'en_rate',
        originalTemplateValue: template.enDoseCode,
        derivedValue: derived.enDoseCode,
        explanation:
            'EN is held at the entered rate while the future fixed template remains intact.',
      ));
    } else if (overlay.route == RouteEffect.reduceEn) {
      derived = derived.copyWith(
        mode: TemplateRouteMode.tpnEn,
        enDoseCode: 'r${math.min(template.enRateMlH, 20).round()}',
        mealSlots: 0,
        mealPacPerSlot: 0,
      );
    }

    for (final note in overlay.notes) {
      alerts.add(StructuredNutritionAlert(
        ruleId: 'OVERLAY_INFO',
        sourceTier: SourceTier.guidelineObligation,
        severity: RuleSeverity.info,
        day: template.day,
        metric: 'event_overlay',
        explanation: note,
      ));
    }

    return EventDerivedDay(
      templatePlan: template,
      derivedPlan: derived,
      overlay: overlay,
      alerts: alerts,
    );
  }
}

class EnergyTargetBand {
  final String ruleId;
  final SourceTier sourceTier;
  final int day;
  final double referenceWeightKg;
  final double greenMinKcal;
  final double greenMaxKcal;
  final double amberMinKcal;
  final double amberMaxKcal;
  final double hardMaxKcal;
  final double includedNonNutritionalKcal;
  final List<StructuredNutritionAlert> alerts;
  final String explanation;

  const EnergyTargetBand({
    required this.ruleId,
    required this.sourceTier,
    required this.day,
    required this.referenceWeightKg,
    required this.greenMinKcal,
    required this.greenMaxKcal,
    required this.amberMinKcal,
    required this.amberMaxKcal,
    required this.hardMaxKcal,
    this.includedNonNutritionalKcal = 0,
    this.alerts = const [],
    required this.explanation,
  });

  BandLevel classify(double kcal) {
    if (kcal > hardMaxKcal + 1e-9) return BandLevel.hardViolation;
    if (kcal >= greenMinKcal - 1e-9 && kcal <= greenMaxKcal + 1e-9) {
      return BandLevel.green;
    }
    if (kcal >= amberMinKcal - 1e-9 && kcal <= amberMaxKcal + 1e-9) {
      return BandLevel.amber;
    }
    return BandLevel.red;
  }
}

class EnergyTargetInput {
  final int day;
  final double referenceWeightKg;
  final double estimatedFullKcal;
  final double? measuredEnergyExpenditureKcal;
  final RefeedingTier refeedingRiskTier;
  final int feedingDay;
  final OptionalCaloriesStatus nonNutritionalCaloriesStatus;
  final double nonNutritionalCaloriesKcal;
  final double? eventEnergyCapKcal;

  const EnergyTargetInput({
    required this.day,
    required this.referenceWeightKg,
    required this.estimatedFullKcal,
    this.measuredEnergyExpenditureKcal,
    this.refeedingRiskTier = RefeedingTier.none,
    this.feedingDay = 1,
    this.nonNutritionalCaloriesStatus = OptionalCaloriesStatus.unknown,
    this.nonNutritionalCaloriesKcal = 0,
    this.eventEnergyCapKcal,
  });
}

class EnergyTargetBuilder {
  const EnergyTargetBuilder();

  EnergyTargetBand build(EnergyTargetInput input) {
    final w = input.referenceWeightKg;
    final alerts = <StructuredNutritionAlert>[];
    late double greenMin;
    late double greenMax;
    late double amberMin;
    late double amberMax;
    late double hardMax;
    late String ruleId;
    late String explanation;

    if (input.measuredEnergyExpenditureKcal != null && input.day > 3) {
      final measured = input.measuredEnergyExpenditureKcal!;
      ruleId = 'ENERGY_MEASURED_EE_AFTER_DAY3';
      greenMin = measured * 0.80;
      greenMax = measured;
      amberMin = math.min(12 * w, greenMin);
      amberMax = measured * 1.10;
      hardMax = measured * 1.10;
      explanation =
          'After day 3, measured EE is handled as an 80-100% green band.';
    } else {
      ruleId = 'ENERGY_INITIAL_ICU_BAND';
      amberMin = 12 * w;
      amberMax = 25 * w;
      final permissiveMax = input.day <= 10
          ? math.min(input.estimatedFullKcal * 0.70, amberMax)
          : math.min(input.estimatedFullKcal, amberMax);
      greenMin = math.min(amberMin, permissiveMax);
      greenMax = math.max(greenMin, permissiveMax);
      hardMax = amberMax;
      explanation =
          'Initial ICU energy is a band; exact kcal chasing is secondary to avoiding overfeeding.';
    }

    if (input.refeedingRiskTier == RefeedingTier.high ||
        input.refeedingRiskTier == RefeedingTier.extreme) {
      final fullKcalPerKg = w > 0 ? input.estimatedFullKcal / w : 0.0;
      final cap = refeedingCapKcalPerKg(
            input.refeedingRiskTier,
            input.feedingDay,
            fullKcalPerKg,
          ) *
          w;
      hardMax = math.min(hardMax, cap);
      greenMax = math.min(greenMax, hardMax);
      amberMax = math.min(amberMax, hardMax);
      explanation = '$explanation Refeeding cap is active.';
    }

    if (input.eventEnergyCapKcal != null) {
      hardMax = math.min(hardMax, input.eventEnergyCapKcal!);
      greenMax = math.min(greenMax, hardMax);
      amberMax = math.min(amberMax, hardMax);
      explanation = '$explanation Clinical event cap is active.';
    }

    if (input.nonNutritionalCaloriesStatus == OptionalCaloriesStatus.unknown) {
      alerts.add(StructuredNutritionAlert(
        ruleId: 'NON_NUTRITIONAL_CALORIES_UNKNOWN',
        sourceTier: SourceTier.guidelineObligation,
        severity: RuleSeverity.info,
        day: input.day,
        metric: 'non_nutritional_calories',
        actual: 'unknown',
        expected:
            'propofol/dextrose fluids/KRT solution calories entered if present',
        explanation:
            'Non-nutritional calories are not included because they were not entered.',
      ));
    }

    return EnergyTargetBand(
      ruleId: ruleId,
      sourceTier: SourceTier.guidelineBand,
      day: input.day,
      referenceWeightKg: w,
      greenMinKcal: greenMin,
      greenMaxKcal: greenMax,
      amberMinKcal: amberMin,
      amberMaxKcal: amberMax,
      hardMaxKcal: hardMax,
      includedNonNutritionalKcal: input.nonNutritionalCaloriesKcal,
      alerts: alerts,
      explanation: explanation,
    );
  }
}

class ProteinTargetBand {
  final String ruleId;
  final SourceTier sourceTier;
  final double minGPerKg;
  final double maxGPerKg;
  final double designGPerKg;
  final bool progressive;
  final bool requiresReview;
  final bool suppressesStableCkdRestriction;
  final String basis;

  const ProteinTargetBand({
    required this.ruleId,
    required this.sourceTier,
    required this.minGPerKg,
    required this.maxGPerKg,
    required this.designGPerKg,
    this.progressive = false,
    this.requiresReview = false,
    this.suppressesStableCkdRestriction = false,
    required this.basis,
  });

  BandLevel classify(double actualGPerKg) {
    if (actualGPerKg >= minGPerKg - 1e-9 && actualGPerKg <= maxGPerKg + 1e-9) {
      return BandLevel.green;
    }
    if (actualGPerKg >= minGPerKg * 0.85 && actualGPerKg <= maxGPerKg * 1.15) {
      return BandLevel.amber;
    }
    return BandLevel.red;
  }
}

class ProteinTargetInput {
  final Set<String> conditionTags;
  final RrtModality? activeRrt;
  final int day;
  final int fullAchieveDay;

  const ProteinTargetInput({
    this.conditionTags = const {},
    this.activeRrt,
    this.day = 1,
    this.fullAchieveDay = 7,
  });
}

class ProteinTargetBuilder {
  const ProteinTargetBuilder();

  ProteinTargetBand build(ProteinTargetInput input) {
    final tags = input.conditionTags;
    final critical = tags.contains('critical');
    final ckd = tags.contains('renal');
    final aki = tags.contains('aki');

    if (input.activeRrt != null) {
      final band = input.activeRrt!.proteinBand;
      return ProteinTargetBand(
        ruleId: switch (input.activeRrt!) {
          RrtModality.irrt => 'PROTEIN_IRRT',
          RrtModality.sled => 'PROTEIN_SLED_PIKRT_LIKE',
          RrtModality.crrt => 'PROTEIN_CRRT_CKRT',
        },
        sourceTier: SourceTier.guidelineBand,
        minGPerKg: band.min,
        maxGPerKg: band.max,
        designGPerKg: (band.min + band.max) / 2,
        suppressesStableCkdRestriction:
            input.activeRrt!.suppressesStableCkdRestriction,
        basis: '${input.activeRrt!.key} active',
      );
    }

    if ((ckd || aki) && critical) {
      return const ProteinTargetBand(
        ruleId: 'PROTEIN_RENAL_ACUTE_CRITICAL_NO_KRT',
        sourceTier: SourceTier.guidelineBand,
        minGPerKg: 1.0,
        maxGPerKg: 1.3,
        designGPerKg: 1.3,
        progressive: true,
        basis: 'AKI/CKD with acute or critical illness, no KRT',
      );
    }
    if (aki) {
      return ProteinTargetBand(
        ruleId: 'PROTEIN_AKI_NO_ACUTE_NO_KRT',
        sourceTier: SourceTier.guidelineBand,
        minGPerKg: 0.8,
        maxGPerKg: 1.0,
        designGPerKg: 0.9,
        requiresReview: ckd,
        basis: ckd ? 'AKI on CKD, stable/no KRT' : 'AKI, stable/no KRT',
      );
    }
    if (ckd) {
      return const ProteinTargetBand(
        ruleId: 'PROTEIN_STABLE_CKD_NO_KRT',
        sourceTier: SourceTier.guidelineBand,
        minGPerKg: 0.6,
        maxGPerKg: 0.8,
        designGPerKg: 0.7,
        requiresReview: true,
        basis: 'Stable non-dialysis CKD, no acute/critical illness, no KRT',
      );
    }
    if (critical) {
      return const ProteinTargetBand(
        ruleId: 'PROTEIN_GENERAL_CRITICAL_ICU',
        sourceTier: SourceTier.guidelineBand,
        minGPerKg: 1.2,
        maxGPerKg: 2.0,
        designGPerKg: 1.3,
        progressive: true,
        basis: 'General critical illness',
      );
    }
    return const ProteinTargetBand(
      ruleId: 'PROTEIN_GENERAL_ICU',
      sourceTier: SourceTier.guidelineBand,
      minGPerKg: 1.0,
      maxGPerKg: 1.5,
      designGPerKg: 1.2,
      basis: 'General adult medical nutrition support',
    );
  }
}

class AutoConstraintSet {
  final double girMaxMgKgMin;
  final double lipidMaxGKgDay;
  final double? fluidMaxMlKgDay;
  final double? energyHardMaxKcal;
  final SourceTier sourceTier;

  const AutoConstraintSet({
    required this.girMaxMgKgMin,
    required this.lipidMaxGKgDay,
    this.fluidMaxMlKgDay,
    this.energyHardMaxKcal,
    this.sourceTier = SourceTier.guidelineHard,
  });
}

class ConstraintBuilder {
  const ConstraintBuilder();

  AutoConstraintSet build({
    required ClinicalState state,
    DayOverlay? overlay,
    EnergyTargetBand? energyTarget,
    double? fluidCapMlKgDay,
  }) {
    final glucoseRestricted =
        conditions.resolveCoeff(state.conditionTags)?.glucoseRestrict ?? false;
    final hasFluidCap = overlay?.fluid == FluidEffect.cap ||
        overlay?.fluid == FluidEffect.strictBalance;
    return AutoConstraintSet(
      girMaxMgKgMin: glucoseRestricted ? 4 : 5,
      lipidMaxGKgDay: 1.5,
      fluidMaxMlKgDay: hasFluidCap ? (fluidCapMlKgDay ?? 30) : null,
      energyHardMaxKcal: energyTarget?.hardMaxKcal,
    );
  }
}

enum MicronutrientCoverageStatus { green, amber, red }

class MicronutrientCoverageInput {
  final bool pnActive;
  final bool enActive;
  final bool oralSupplementActive;
  final bool basePnContainsMvi;
  final bool basePnContainsTrace;
  final bool additiveMviOrdered;
  final bool additiveTraceOrdered;
  final double enFormulaVolumeMl;
  final double enFullVolumeMl;
  final bool oralDietEstimatedComplete;

  const MicronutrientCoverageInput({
    this.pnActive = false,
    this.enActive = false,
    this.oralSupplementActive = false,
    this.basePnContainsMvi = false,
    this.basePnContainsTrace = false,
    this.additiveMviOrdered = false,
    this.additiveTraceOrdered = false,
    this.enFormulaVolumeMl = 0,
    this.enFullVolumeMl = 1500,
    this.oralDietEstimatedComplete = false,
  });

  bool get medicalNutritionSupportActive =>
      pnActive || enActive || oralSupplementActive;
}

class MicronutrientCoverageResult {
  final MicronutrientCoverageStatus vitamins;
  final MicronutrientCoverageStatus traceElements;
  final List<StructuredNutritionAlert> alerts;

  const MicronutrientCoverageResult({
    required this.vitamins,
    required this.traceElements,
    this.alerts = const [],
  });

  bool get isCovered =>
      vitamins == MicronutrientCoverageStatus.green &&
      traceElements == MicronutrientCoverageStatus.green;
}

class MicronutrientMaintenanceEngine {
  const MicronutrientMaintenanceEngine();

  MicronutrientCoverageResult assess(
      MicronutrientCoverageInput input, int day) {
    final enFraction = input.enFullVolumeMl > 0
        ? input.enFormulaVolumeMl / input.enFullVolumeMl
        : 0.0;
    final coverage = micronutrients.assessMaintenanceCoverage(
      pnActive: input.pnActive,
      enActive: input.enActive,
      oralSupplementActive: input.oralSupplementActive,
      pnContainsMvi: input.basePnContainsMvi || input.additiveMviOrdered,
      pnContainsTrace: input.basePnContainsTrace || input.additiveTraceOrdered,
      enFormulaVolumeFraction: enFraction,
      oralDietMicronutrientCompleteness:
          input.oralDietEstimatedComplete ? 1.0 : 0.0,
      daysOnSupport: day,
      fullEnFractionForGreen: 0.8,
    );
    final vitaminStatus = _coverageStatus(coverage.vitamins);
    final traceStatus = _coverageStatus(coverage.traceElements);
    final alerts = <StructuredNutritionAlert>[];
    if (input.pnActive &&
        coverage.vitamins == micronutrients.CoverageBand.red) {
      alerts.add(StructuredNutritionAlert(
        ruleId: 'PN_MVI_MAINTENANCE_MISSING',
        sourceTier: SourceTier.guidelineObligation,
        severity: RuleSeverity.major,
        day: day,
        metric: 'vitamins',
        expected: 'PN MVI or equivalent',
        explanation: coverage.reason,
        suggestedRepair:
            'Attach standard MVI unless the base PN already contains it.',
      ));
    }
    if (input.pnActive &&
        coverage.traceElements == micronutrients.CoverageBand.red) {
      alerts.add(StructuredNutritionAlert(
        ruleId: 'PN_TRACE_MAINTENANCE_MISSING',
        sourceTier: SourceTier.guidelineObligation,
        severity: RuleSeverity.major,
        day: day,
        metric: 'trace_elements',
        expected: 'trace elements or equivalent',
        explanation: coverage.reason,
        suggestedRepair:
            'Attach trace element product unless the base PN already contains it.',
      ));
    }
    if (!input.pnActive && coverage.band == micronutrients.CoverageBand.amber) {
      alerts.add(StructuredNutritionAlert(
        ruleId: 'PARTIAL_MICRONUTRIENT_COVERAGE',
        sourceTier: SourceTier.guidelineObligation,
        severity: RuleSeverity.soft,
        day: day,
        metric: 'micronutrient_coverage',
        actual: enFraction,
        expected: 'full EN formula volume or equivalent',
        explanation: coverage.reason,
      ));
    }

    return MicronutrientCoverageResult(
      vitamins: vitaminStatus,
      traceElements: traceStatus,
      alerts: alerts,
    );
  }

  MicronutrientCoverageStatus _coverageStatus(
      micronutrients.CoverageBand band) {
    return switch (band) {
      micronutrients.CoverageBand.green => MicronutrientCoverageStatus.green,
      micronutrients.CoverageBand.amber => MicronutrientCoverageStatus.amber,
      micronutrients.CoverageBand.red => MicronutrientCoverageStatus.red,
    };
  }
}

class ClinicalObligation {
  final String ruleId;
  final SourceTier sourceTier;
  final String label;
  final String reason;
  final String action;
  final int? reassessHours;

  const ClinicalObligation({
    required this.ruleId,
    required this.sourceTier,
    required this.label,
    required this.reason,
    required this.action,
    this.reassessHours,
  });
}

class MicronutrientObligationInput {
  final RefeedingTier refeedingRiskTier;
  final bool fastingOrPoorIntakeGe5Days;
  final bool dextroseOrHighCarbohydrateStart;
  final bool alcoholUseOrSuspicion;
  final bool severeMalnutrition;
  final RrtModality? activeRrt;
  final int? activeRrtDurationDays;
  final bool highOutputGiLoss;
  final bool majorWoundOrBurn;
  final bool measuredDeficiency;
  final bool longTermPn;

  const MicronutrientObligationInput({
    this.refeedingRiskTier = RefeedingTier.none,
    this.fastingOrPoorIntakeGe5Days = false,
    this.dextroseOrHighCarbohydrateStart = false,
    this.alcoholUseOrSuspicion = false,
    this.severeMalnutrition = false,
    this.activeRrt,
    this.activeRrtDurationDays,
    this.highOutputGiLoss = false,
    this.majorWoundOrBurn = false,
    this.measuredDeficiency = false,
    this.longTermPn = false,
  });
}

class MicronutrientAdditionalObligationEngine {
  const MicronutrientAdditionalObligationEngine();

  List<ClinicalObligation> evaluate(MicronutrientObligationInput input) {
    final highRefeeding = input.refeedingRiskTier == RefeedingTier.high ||
        input.refeedingRiskTier == RefeedingTier.extreme;
    final rrtLoss = input.activeRrt == RrtModality.sled ||
        input.activeRrt == RrtModality.crrt;
    final out = micronutrients
        .additionalMicronutrientObligations(
          highOrExtremeRefeedingRisk: highRefeeding,
          fastingOrPoorIntakeGe5d: input.fastingOrPoorIntakeGe5Days,
          dextroseOrHighCarbStart: input.dextroseOrHighCarbohydrateStart,
          alcoholUseDisorderOrSuspicion: input.alcoholUseOrSuspicion,
          severeMalnutrition: input.severeMalnutrition,
          crrtOrSledActive: rrtLoss,
          highOutputGiLoss: input.highOutputGiLoss,
          majorWoundOrBurn: input.majorWoundOrBurn,
          measuredSeDeficiency: input.measuredDeficiency,
          measuredZnDeficiency: input.measuredDeficiency,
          crrtDurationDays: input.activeRrt == RrtModality.crrt
              ? (input.activeRrtDurationDays ?? 0)
              : 0,
          longTermPn: input.longTermPn,
        )
        .map(_clinicalObligationFromMicro)
        .toList();
    if (input.activeRrt == RrtModality.crrt &&
        !out.any((o) => o.ruleId == 'THIAMINE_ADDITIONAL')) {
      out.add(const ClinicalObligation(
        ruleId: 'THIAMINE_ADDITIONAL',
        sourceTier: SourceTier.guidelineObligation,
        label: 'Thiamine',
        reason:
            'Active CRRT creates high micronutrient loss risk including water-soluble vitamins.',
        action:
            'Ensure thiamine coverage/review alongside other CRRT micronutrient obligations.',
      ));
    }
    if (input.activeRrt == RrtModality.crrt) {
      out.add(const ClinicalObligation(
        ruleId: 'CRRT_WATER_SOLUBLE_LOSS_RISK',
        sourceTier: SourceTier.guidelineObligation,
        label: 'CRRT micronutrient loss risk',
        reason:
            'CRRT increases loss risk for water-soluble vitamins and trace elements.',
        action:
            'Maintain MVI/trace and review vitamin C, folate, selenium, zinc, copper.',
      ));
    }
    return out;
  }

  ClinicalObligation _clinicalObligationFromMicro(
      micronutrients.MicronutrientObligation obligation) {
    return ClinicalObligation(
      ruleId: switch (obligation.nutrient) {
        'thiamine' => 'THIAMINE_ADDITIONAL',
        'selenium' => 'SELENIUM_ADDITIONAL_CONSIDER',
        'zinc' => 'ZINC_ADDITIONAL_CONSIDER',
        'copper' => 'COPPER_MONITORING_REVIEW',
        'manganese' => 'MANGANESE_TOXICITY_GUARD',
        _ => 'MICRONUTRIENT_${obligation.nutrient.toUpperCase()}',
      },
      sourceTier: obligation.sourceTier,
      label: switch (obligation.nutrient) {
        'thiamine' => 'Thiamine',
        'selenium' => 'Selenium',
        'zinc' => 'Zinc',
        'copper' => 'Copper',
        'manganese' => 'Manganese guard',
        _ => obligation.nutrient,
      },
      reason: obligation.reason,
      action: obligation.action,
      reassessHours: obligation.requiresReview ? 72 : null,
    );
  }
}

class MicronutrientToxicityGuardInput {
  final bool cholestasis;
  final bool liverFailure;
  final bool longTermPn;
  final bool elevatedBilirubin;
  final bool hepaticEncephalopathy;

  const MicronutrientToxicityGuardInput({
    this.cholestasis = false,
    this.liverFailure = false,
    this.longTermPn = false,
    this.elevatedBilirubin = false,
    this.hepaticEncephalopathy = false,
  });
}

class MicronutrientToxicityGuard {
  const MicronutrientToxicityGuard();

  List<ClinicalObligation> evaluate(MicronutrientToxicityGuardInput input) {
    final guard = micronutrients.manganeseGuard(
      cholestasis: input.cholestasis,
      liverFailure: input.liverFailure,
      longTermPn: input.longTermPn,
      elevatedBilirubin: input.elevatedBilirubin,
      hepaticEncephalopathy: input.hepaticEncephalopathy,
    );
    if (guard == null) return const [];
    return [
      ClinicalObligation(
        ruleId: 'MANGANESE_TOXICITY_GUARD',
        sourceTier: guard.sourceTier,
        label: 'Manganese guard',
        reason: guard.reason,
        action: guard.action,
        reassessHours: guard.requiresReview ? 72 : null,
      ),
    ];
  }
}

class ClinicalObligationEngine {
  final MicronutrientAdditionalObligationEngine additional;
  final MicronutrientToxicityGuard toxicity;

  const ClinicalObligationEngine({
    this.additional = const MicronutrientAdditionalObligationEngine(),
    this.toxicity = const MicronutrientToxicityGuard(),
  });

  List<ClinicalObligation> evaluate({
    required MicronutrientObligationInput additionalInput,
    required MicronutrientToxicityGuardInput toxicityInput,
  }) =>
      [
        ...additional.evaluate(additionalInput),
        ...toxicity.evaluate(toxicityInput),
      ];
}

enum CandidateRoute { enteral, parenteral, oral, additive }

class AutoDesignProductCandidate {
  final String id;
  final String name;
  final CandidateRoute route;
  final bool favorite;
  final bool semiSolidNative;
  final bool thickenedWithAdditive;
  final bool canBeThickened;
  final bool mnFreeTrace;
  final Set<String> diseaseTags;

  const AutoDesignProductCandidate({
    required this.id,
    required this.name,
    required this.route,
    this.favorite = false,
    this.semiSolidNative = false,
    this.thickenedWithAdditive = false,
    this.canBeThickened = false,
    this.mnFreeTrace = false,
    this.diseaseTags = const {},
  });

  bool get isEnteralOrOral =>
      route == CandidateRoute.enteral || route == CandidateRoute.oral;
}

class ProductFilterContext {
  final bool enteralDisabled;
  final bool dysphagia;
  final bool reflux;
  final bool mnFreeTraceRequired;

  const ProductFilterContext({
    this.enteralDisabled = false,
    this.dysphagia = false,
    this.reflux = false,
    this.mnFreeTraceRequired = false,
  });
}

class ProductFilterResult {
  final List<AutoDesignProductCandidate> accepted;
  final Map<String, String> rejectedReasons;

  const ProductFilterResult({
    required this.accepted,
    required this.rejectedReasons,
  });
}

class ProductCandidateFilter {
  const ProductCandidateFilter();

  ProductFilterResult filter(
    List<AutoDesignProductCandidate> products,
    ProductFilterContext context,
  ) {
    final accepted = <AutoDesignProductCandidate>[];
    final rejected = <String, String>{};
    for (final p in products) {
      if (context.enteralDisabled && p.isEnteralOrOral) {
        rejected[p.id] = 'Enteral/oral route is disabled by active event.';
        continue;
      }
      if (context.dysphagia &&
          p.isEnteralOrOral &&
          !p.semiSolidNative &&
          !p.thickenedWithAdditive) {
        rejected[p.id] = 'Dysphagia requires semi-solid or thickened delivery.';
        continue;
      }
      if (context.reflux &&
          p.isEnteralOrOral &&
          !p.semiSolidNative &&
          !p.thickenedWithAdditive &&
          !p.canBeThickened) {
        rejected[p.id] =
            'Reflux risk prefers semi-solid/thickened or lower-volume design.';
        continue;
      }
      if (context.mnFreeTraceRequired &&
          p.route == CandidateRoute.additive &&
          p.diseaseTags.contains('trace') &&
          !p.mnFreeTrace) {
        rejected[p.id] = 'Mn-free trace is required.';
        continue;
      }
      accepted.add(p);
    }
    return ProductFilterResult(accepted: accepted, rejectedReasons: rejected);
  }
}

class CandidatePlan {
  final String id;
  final List<BandLevel> bandLevels;
  final bool hasHardViolation;
  final bool usesFavoriteCompatibleProduct;
  final int packageCount;

  const CandidatePlan({
    required this.id,
    this.bandLevels = const [],
    this.hasHardViolation = false,
    this.usesFavoriteCompatibleProduct = false,
    this.packageCount = 0,
  });
}

class BandScore {
  final CandidatePlan plan;
  final bool rejected;
  final double score;

  const BandScore({
    required this.plan,
    required this.rejected,
    required this.score,
  });
}

class BandBasedOptimizer {
  const BandBasedOptimizer();

  BandScore score(CandidatePlan plan) {
    if (plan.hasHardViolation ||
        plan.bandLevels.contains(BandLevel.hardViolation)) {
      return BandScore(
        plan: plan,
        rejected: true,
        score: double.negativeInfinity,
      );
    }
    double score = 0;
    for (final level in plan.bandLevels) {
      switch (level) {
        case BandLevel.green:
          break;
        case BandLevel.amber:
          score -= 10;
          break;
        case BandLevel.red:
          score -= 100;
          break;
        case BandLevel.hardViolation:
          return BandScore(
            plan: plan,
            rejected: true,
            score: double.negativeInfinity,
          );
      }
    }
    if (plan.usesFavoriteCompatibleProduct) score += 10;
    score += math.max(0, 5 - plan.packageCount);
    return BandScore(plan: plan, rejected: false, score: score.toDouble());
  }

  CandidatePlan? chooseBest(List<CandidatePlan> plans) {
    final scored = plans.map(score).where((s) => !s.rejected).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return scored.isEmpty ? null : scored.first.plan;
  }
}

class AutoDesignInput {
  final double weightKg;
  final double? usualOrPrehospitalWeightKg;
  final Set<String> conditionTags;
  final List<ClinicalEvent> events;
  final int rampDays;
  final int enStartDay;
  final int? oralRehabStartDay;
  final int? totalDays;
  final double estimatedFullKcal;
  final Map<int, double> measuredEnergyExpenditureByDay;
  final RefeedingTier refeedingTier;
  final int feedingStartDay;
  final OptionalCaloriesStatus nonNutritionalCaloriesStatus;
  final double nonNutritionalCaloriesKcal;
  final OptionalCaloriesStatus krtFluidCaloriesStatus;
  final double? krtSolutionCaloriesKcalDay;
  final Map<int, double> eventEnergyCapKcalByDay;
  final MicronutrientCoverageInput? micronutrientCoverageInput;
  final MicronutrientObligationInput? micronutrientObligationInput;
  final MicronutrientToxicityGuardInput? toxicityGuardInput;

  const AutoDesignInput({
    required this.weightKg,
    required this.conditionTags,
    required this.rampDays,
    required this.enStartDay,
    required this.estimatedFullKcal,
    this.usualOrPrehospitalWeightKg,
    this.events = const [],
    this.oralRehabStartDay,
    this.totalDays,
    this.measuredEnergyExpenditureByDay = const {},
    this.refeedingTier = RefeedingTier.none,
    this.feedingStartDay = 1,
    this.nonNutritionalCaloriesStatus = OptionalCaloriesStatus.unknown,
    this.nonNutritionalCaloriesKcal = 0,
    this.krtFluidCaloriesStatus = OptionalCaloriesStatus.unknown,
    this.krtSolutionCaloriesKcalDay,
    this.eventEnergyCapKcalByDay = const {},
    this.micronutrientCoverageInput,
    this.micronutrientObligationInput,
    this.toxicityGuardInput,
  });
}

class AutoDesignResult {
  final List<PhaseTemplateDay> templateDays;
  final List<EventDerivedDay> derivedDays;
  final List<EnergyTargetBand> energyTargets;
  final List<ProteinTargetBand> proteinTargets;
  final List<StructuredNutritionAlert> alerts;
  final List<ClinicalObligation> obligations;
  final List<String> sourceBadges;

  const AutoDesignResult({
    required this.templateDays,
    required this.derivedDays,
    required this.energyTargets,
    required this.proteinTargets,
    required this.alerts,
    required this.obligations,
    required this.sourceBadges,
  });
}

class AutoDesignEngine {
  final ClinicalStateNormalizer normalizer;
  final PhaseTemplateEngine templateEngine;
  final ClinicalEventOverlayAdapter overlayAdapter;
  final EnergyTargetBuilder energyBuilder;
  final ProteinTargetBuilder proteinBuilder;
  final MicronutrientMaintenanceEngine micronutrientMaintenance;
  final ClinicalObligationEngine obligationEngine;
  final PlanExplanationBuilder explanationBuilder;

  const AutoDesignEngine({
    this.normalizer = const ClinicalStateNormalizer(),
    this.templateEngine = const PhaseTemplateEngine(),
    this.overlayAdapter = const ClinicalEventOverlayAdapter(),
    this.energyBuilder = const EnergyTargetBuilder(),
    this.proteinBuilder = const ProteinTargetBuilder(),
    this.micronutrientMaintenance = const MicronutrientMaintenanceEngine(),
    this.obligationEngine = const ClinicalObligationEngine(),
    this.explanationBuilder = const PlanExplanationBuilder(),
  });

  AutoDesignResult build(AutoDesignInput input) {
    final totalDays = _totalDays(input);
    final templateDays = templateEngine.buildTimeline(
      rampDays: input.rampDays,
      enStartDay: input.enStartDay,
      oralRehabStartDay: input.oralRehabStartDay,
      totalDays: totalDays,
    );
    final derivedDays = <EventDerivedDay>[];
    final energyTargets = <EnergyTargetBand>[];
    final proteinTargets = <ProteinTargetBand>[];
    final alerts = <StructuredNutritionAlert>[];
    final obligationsByRule = <String, ClinicalObligation>{};

    for (final template in templateDays) {
      final day = template.day;
      final overlay = overlayAdapter.derive(
        template: template,
        events: input.events,
        rrtCalorieUnknown:
            input.krtFluidCaloriesStatus == OptionalCaloriesStatus.unknown,
      );
      derivedDays.add(overlay);
      alerts.addAll(overlay.alerts);

      final state = normalizer.normalize(
        conditionTags: input.conditionTags,
        actualWeightKg: input.weightKg,
        usualOrPrehospitalWeightKg: input.usualOrPrehospitalWeightKg,
        day: day,
        events: input.events,
        krtFluidCaloriesStatus: input.krtFluidCaloriesStatus,
        krtSolutionCaloriesKcalDay: input.krtSolutionCaloriesKcalDay,
      );
      final feedingDay = math.max(1, day - input.feedingStartDay + 1).toInt();
      final energy = energyBuilder.build(EnergyTargetInput(
        day: day,
        referenceWeightKg: state.referenceWeightKg,
        estimatedFullKcal: input.estimatedFullKcal,
        measuredEnergyExpenditureKcal:
            input.measuredEnergyExpenditureByDay[day],
        refeedingRiskTier: input.refeedingTier,
        feedingDay: feedingDay,
        nonNutritionalCaloriesStatus: input.nonNutritionalCaloriesStatus,
        nonNutritionalCaloriesKcal: input.nonNutritionalCaloriesKcal,
        eventEnergyCapKcal: input.eventEnergyCapKcalByDay[day],
      ));
      energyTargets.add(energy);
      alerts.addAll(energy.alerts);

      final protein = proteinBuilder.build(ProteinTargetInput(
        conditionTags: input.conditionTags,
        activeRrt: overlay.overlay.activeRrtModality ?? state.activeRrt,
        day: day,
        fullAchieveDay: input.rampDays,
      ));
      proteinTargets.add(protein);

      if (input.micronutrientCoverageInput != null) {
        final coverage = micronutrientMaintenance.assess(
          input.micronutrientCoverageInput!,
          day,
        );
        alerts.addAll(coverage.alerts);
      }

      final additionalInput = input.micronutrientObligationInput;
      final toxicityInput = input.toxicityGuardInput;
      if (additionalInput != null || toxicityInput != null) {
        final dayObligations = obligationEngine.evaluate(
          additionalInput: _obligationInputForDay(
            additionalInput,
            state,
            input.refeedingTier,
          ),
          toxicityInput:
              toxicityInput ?? const MicronutrientToxicityGuardInput(),
        );
        for (final obligation in dayObligations) {
          obligationsByRule.putIfAbsent(obligation.ruleId, () => obligation);
        }
      }
    }

    final obligations = obligationsByRule.values.toList();
    final tiers = <SourceTier>[
      ...templateDays.map((d) => d.sourceTier),
      ...input.events.map((e) => e.sourceTier),
      ...derivedDays
          .expand((d) => d.overlay.activeEvents.map((e) => e.sourceTier)),
      ...energyTargets.map((e) => e.sourceTier),
      ...proteinTargets.map((p) => p.sourceTier),
      ...alerts.map((a) => a.sourceTier),
      ...obligations.map((o) => o.sourceTier),
    ];

    return AutoDesignResult(
      templateDays: templateDays,
      derivedDays: derivedDays,
      energyTargets: energyTargets,
      proteinTargets: proteinTargets,
      alerts: alerts,
      obligations: obligations,
      sourceBadges: explanationBuilder.sourceBadges(tiers),
    );
  }

  int _totalDays(AutoDesignInput input) {
    var total = input.totalDays ?? 0;
    for (final event in input.events) {
      final eventEnd = event.endDay ?? event.startDay;
      if (eventEnd > total) total = eventEnd;
    }
    return total;
  }

  MicronutrientObligationInput _obligationInputForDay(
    MicronutrientObligationInput? base,
    ClinicalState state,
    RefeedingTier refeedingTier,
  ) {
    if (base == null) {
      return MicronutrientObligationInput(
        refeedingRiskTier: refeedingTier,
        activeRrt: state.activeRrt,
        activeRrtDurationDays: state.activeRrtDurationDays,
      );
    }
    return MicronutrientObligationInput(
      refeedingRiskTier: base.refeedingRiskTier == RefeedingTier.none
          ? refeedingTier
          : base.refeedingRiskTier,
      fastingOrPoorIntakeGe5Days: base.fastingOrPoorIntakeGe5Days,
      dextroseOrHighCarbohydrateStart: base.dextroseOrHighCarbohydrateStart,
      alcoholUseOrSuspicion: base.alcoholUseOrSuspicion,
      severeMalnutrition: base.severeMalnutrition,
      activeRrt: state.activeRrt ?? base.activeRrt,
      activeRrtDurationDays:
          state.activeRrtDurationDays ?? base.activeRrtDurationDays,
      highOutputGiLoss: base.highOutputGiLoss,
      majorWoundOrBurn: base.majorWoundOrBurn,
      measuredDeficiency: base.measuredDeficiency,
      longTermPn: base.longTermPn,
    );
  }
}

class PlanExplanationBuilder {
  const PlanExplanationBuilder();

  List<String> sourceBadges(Iterable<SourceTier> tiers) {
    final seen = <SourceTier>{};
    final out = <String>[];
    for (final tier in tiers) {
      if (seen.add(tier)) out.add(tier.badgeLabel);
    }
    return out;
  }

  String templateVsDerived(EventDerivedDay result) {
    final overlays =
        result.overlay.activeEvents.map((e) => e.type.name).join(', ');
    return 'Template: ${result.templatePlan.mode.key}/${result.templatePlan.enDoseCode}; '
        'Overlays: ${overlays.isEmpty ? 'none' : overlays}; '
        'Derived: ${result.derivedPlan.mode.key}/${result.derivedPlan.enDoseCode}';
  }
}
