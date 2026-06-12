import 'bed_assignment.dart';
import 'regimen_item.dart';
import 'sex.dart';
import 'zero_menu_config.dart';

/// 患者症例（1ベッド1患者）。入力・処方・設定・履歴を保持する。
class PatientCase {
  PatientCase({
    required this.id,
    required this.caseCode,
    required this.currentBed,
    required this.age,
    required this.heightCm,
    required this.weightKg,
    required this.sex,
    required this.activityFactor,
    required this.stressFactor,
    required this.proteinGoalPerKg,
    required this.createdAt,
    required this.bedHistory,
    required this.regimenItems,
    required this.selectedProtocolId,
    required this.zeroMenuConfig,
    this.autoDesignConfig,
    this.energyModel = 'harrisBenedict',
    this.kcalPerKgValue,
    this.measuredREE,
    this.memo = '',
    this.patientId = '',
    List<String>? conditionTags,
    List<String>? refeedingFlags,
  })  : conditionTags = conditionTags ?? [],
        refeedingFlags = refeedingFlags ?? [];

  final String id;
  String caseCode;
  String patientId; // 患者ID(カルテ番号など・任意・編集可)
  String currentBed;
  int age;
  double heightCm;
  double weightKg;
  Sex sex;
  double activityFactor;
  double stressFactor;
  double proteinGoalPerKg;
  final String createdAt;
  final List<BedAssignment> bedHistory;
  final List<RegimenItem> regimenItems;
  String selectedProtocolId;
  ZeroMenuConfig zeroMenuConfig;
  Map<String, dynamic>? autoDesignConfig; // Day別投与設計の保存
  String memo; // 合併症・コメントなど
  String? fastingDate; // 絶食開始日 (ISO date string, null=未設定)
  List<String> conditionTags; // 病態タグ (ConditionCatalog の id 群)
  List<String> refeedingFlags; // 手動選択したRefeedingリスク基準id (NICE・kRefeedingCriteria)
  String energyModel; // 'harrisBenedict'|'mifflinStJeor'|'kcalPerKg'|'indirectCalorimetry'
  double? kcalPerKgValue; // 簡易式の kcal/kg/day
  double? measuredREE; // 間接熱量測定の実測REE (kcal/day)

  String get displayLabel => '$caseCode / $currentBed';

  /// プロトコルIDを旧スキーマから新スキーマへマイグレーションする (Phase 4-③)
  static String _migrateProtocolId(String? oldId) {
    switch (oldId) {
      case 'icu_5day':
        return 'five_day';
      case 'standard_4day':
        return 'four_day';
      case 'cautious_refeeding':
        return 'cautious';
      case null:
        return 'five_day';
      default:
        // 新IDか未知のIDとりあえずそのまま返すが、不明なら five_day にフォールバック
        const known = {'three_day', 'four_day', 'five_day', 'cautious'};
        return known.contains(oldId) ? oldId : 'five_day';
    }
  }

  String get sexLabel => sex == Sex.male ? 'M' : 'F';

  /// BMI = 体重kg / 身長m^2（NutritionCalculator.bmi と同一式・単一の出所）。
  double get bmi => weightKg / ((heightCm / 100) * (heightCm / 100));

  String get patientInfoLine =>
      '${age}歳, $sexLabel, ${heightCm.toStringAsFixed(0)}cm, ${weightKg.toStringAsFixed(1)}kg, BMI ${bmi.toStringAsFixed(1)}';

  Map<String, dynamic> toMap() => {
        'id': id,
        'caseCode': caseCode,
        'patientId': patientId,
        'currentBed': currentBed,
        'age': age,
        'heightCm': heightCm,
        'weightKg': weightKg,
        'sex': sex.name,
        'activityFactor': activityFactor,
        'stressFactor': stressFactor,
        'proteinGoalPerKg': proteinGoalPerKg,
        'createdAt': createdAt,
        'bedHistory': bedHistory.map((e) => e.toMap()).toList(),
        'regimenItems': regimenItems.map((e) => e.toMap()).toList(),
        'selectedProtocolId': selectedProtocolId,
        'zeroMenuConfig': zeroMenuConfig.toMap(),
        'autoDesignConfig': autoDesignConfig,
        'memo': memo,
        'fastingDate': fastingDate,
        'conditionTags': conditionTags,
        'refeedingFlags': refeedingFlags,
        'energyModel': energyModel,
        'kcalPerKgValue': kcalPerKgValue,
        'measuredREE': measuredREE,
      };

  factory PatientCase.fromMap(Map<String, dynamic> map) => PatientCase(
        id: map['id'] as String,
        caseCode: map['caseCode'] as String,
        patientId: (map['patientId'] as String?) ?? '',
        currentBed: map['currentBed'] as String,
        age: map['age'] as int,
        heightCm: (map['heightCm'] as num).toDouble(),
        weightKg: (map['weightKg'] as num).toDouble(),
        sex: (map['sex'] as String) == 'male' ? Sex.male : Sex.female,
        activityFactor: (map['activityFactor'] as num).toDouble(),
        stressFactor: (map['stressFactor'] as num).toDouble(),
        proteinGoalPerKg: (map['proteinGoalPerKg'] as num).toDouble(),
        createdAt: map['createdAt'] as String,
        bedHistory: ((map['bedHistory'] ?? []) as List)
            .map((e) => BedAssignment.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
        regimenItems: ((map['regimenItems'] ?? []) as List)
            .map((e) => RegimenItem.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
        selectedProtocolId: PatientCase._migrateProtocolId(
            map['selectedProtocolId'] as String?),
        zeroMenuConfig: map['zeroMenuConfig'] == null
            ? ZeroMenuConfig.defaultConfig()
            : ZeroMenuConfig.fromMap(
                Map<String, dynamic>.from(map['zeroMenuConfig'])),
        autoDesignConfig: map['autoDesignConfig'] == null
            ? null
            : Map<String, dynamic>.from(map['autoDesignConfig']),
        memo: (map['memo'] as String?) ?? '',
        conditionTags: (map['conditionTags'] as List?)
            ?.map((e) => e.toString())
            .toList(),
        refeedingFlags: (map['refeedingFlags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        energyModel: (map['energyModel'] as String?) ?? 'harrisBenedict',
        kcalPerKgValue: (map['kcalPerKgValue'] as num?)?.toDouble(),
        measuredREE: (map['measuredREE'] as num?)?.toDouble(),
      )..fastingDate = map['fastingDate'] as String?;
}
