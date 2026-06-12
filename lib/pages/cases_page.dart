part of '../main.dart';

Future<void> showPatientEditDialog(
    BuildContext context, AppState state, PatientCase current,
    {VoidCallback? onSaved}) async {
  double activity = current.activityFactor;
  double stress = current.stressFactor;
  double protein = current.proteinGoalPerKg;
  String energyModel = current.energyModel;
  double kcalPerKgValue = current.kcalPerKgValue ?? 25;
  final reeCtrl =
      TextEditingController(text: current.measuredREE?.toStringAsFixed(0) ?? '');
  final patientIdCtrl = TextEditingController(text: current.patientId);
  final caseCodeCtrl = TextEditingController(text: current.caseCode);
  final memoCtrl = TextEditingController(text: current.memo);
  final selectedTags = current.conditionTags.toSet();
  // Refeedingリスク: 手動選択した NICE 基準フラグ（BMI/絶食以外）。
  final refeedingManualFlags = current.refeedingFlags.toSet();
  bool refeedingExpanded = current.refeedingFlags.isNotEmpty;
  DateTime? fastingDate = current.fastingDate != null
      ? DateTime.tryParse(current.fastingDate!)
      : null;
  int bedIdx =
      (int.tryParse(current.currentBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1)
          .clamp(1, 8);
  final admEntry =
      current.bedHistory.where((b) => b.fromBed == null).firstOrNull;
  // 入室日(編集可)。入室レコードの changedAt を初期値にする。
  DateTime? admissionDate =
      admEntry == null ? null : DateTime.tryParse(admEntry.changedAt);

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('患者情報編集'),
        content: SizedBox(
          width: (MediaQuery.of(context).size.width - 80).clamp(280.0, 400.0),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名前/症例名 (編集可)
                TextField(
                  controller: caseCodeCtrl,
                  decoration: const InputDecoration(
                    labelText: '名前 / 症例名',
                    prefixIcon: Icon(Icons.person, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                // 患者ID (任意・編集可)
                TextField(
                  controller: patientIdCtrl,
                  decoration: const InputDecoration(
                    labelText: '患者ID (任意)',
                    hintText: 'カルテ番号など',
                    prefixIcon: Icon(Icons.badge_outlined, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                // 入室日 (編集可・四角枠ボタン) | 絶食開始日 (横並び・mm/dd)
                Row(children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await _quickPickDate(
                          context, admissionDate ?? DateTime.now());
                      if (picked != null) {
                        setLocal(() => admissionDate = picked);
                      }
                    },
                    icon: Icon(Icons.login,
                        size: 14, color: Colors.green.shade600),
                    label: Text(
                      admissionDate == null
                          ? '入室 —'
                          : '入室 ${admissionDate!.month}/${admissionDate!.day}',
                      style: TextStyle(
                          fontSize: 13, color: Colors.green.shade700),
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: Colors.green.shade300),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await _quickPickDate(
                            context, fastingDate ?? DateTime.now());
                        if (picked != null) {
                          setLocal(() => fastingDate = picked);
                        }
                      },
                      child: Row(children: [
                        Icon(Icons.no_meals,
                            size: 16,
                            color: fastingDate == null
                                ? Colors.grey.shade600
                                : Colors.red.shade400),
                        const SizedBox(width: 2),
                        Text(
                          fastingDate == null
                              ? '絶食 未設定'
                              : '絶食 ${fastingDate!.month}/${fastingDate!.day}',
                          style: TextStyle(
                              fontSize: 13,
                              color: fastingDate == null
                                  ? Colors.grey
                                  : Colors.red.shade400),
                        ),
                        if (fastingDate != null)
                          IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setLocal(() => fastingDate = null),
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.calendar_today, size: 14),
                          ),
                      ]),
                    ),
                  ),
                ]),
                const Divider(height: 16),
                // ベッド (編集可・移動を反映)
                Row(children: [
                  Icon(Icons.bed, size: 18, color: Colors.blueGrey.shade600),
                  const SizedBox(width: 6),
                  Text('ベッド ${bedIdx.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 14)),
                ]),
                Slider(
                  value: bedIdx.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: bedIdx.toString().padLeft(2, '0'),
                  onChanged: (v) => setLocal(() => bedIdx = v.toInt()),
                ),
                // エネルギー式
                ..._energyModelFields(
                  energyModel: energyModel,
                  kcalPerKgValue: kcalPerKgValue,
                  reeCtrl: reeCtrl,
                  onModel: (v) => setLocal(() => energyModel = v),
                  onKcalPerKg: (v) => setLocal(() => kcalPerKgValue = v),
                ),
                // AF/SFはHarris-Benedictのみ。簡易式/Mifflin/間接熱量測定では非表示
                if (energyModel == 'harrisBenedict') ...[
                const SizedBox(height: 8),
                // AF / SF (横並び)
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      initialValue: activity,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: '活動係数 (AF)', isDense: true),
                      items: [
                        for (var i = 0; i < 7; i++)
                          _factorItem(1.0 + i * 0.1, _afHints)
                      ],
                      selectedItemBuilder: (context) => [
                        for (var i = 0; i < 7; i++)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: Text((1.0 + i * 0.1).toStringAsFixed(1))),
                      ],
                      onChanged: (v) =>
                          setLocal(() => activity = v ?? activity),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      initialValue: stress,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: '侵害係数 (SF)', isDense: true),
                      items: [
                        for (var i = 0; i < 13; i++)
                          _factorItem(0.9 + i * 0.1, _sfHints)
                      ],
                      selectedItemBuilder: (context) => [
                        for (var i = 0; i < 13; i++)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: Text((0.9 + i * 0.1).toStringAsFixed(1))),
                      ],
                      onChanged: (v) => setLocal(() => stress = v ?? stress),
                    ),
                  ),
                ]),
                ],
                const SizedBox(height: 8),
                // 目標タンパク
                DropdownButtonFormField<double>(
                  initialValue: double.parse(protein.toStringAsFixed(1)),
                  decoration: const InputDecoration(
                      labelText: '目標タンパク (g/kg/day)', isDense: true),
                  items: [for (var i = 6; i <= 20; i++) i * 0.1]
                      .map((v) => DropdownMenuItem(
                          value: double.parse(v.toStringAsFixed(1)),
                          child: Text(v.toStringAsFixed(1))))
                      .toList(),
                  onChanged: (v) => setLocal(() => protein = v ?? protein),
                ),
                Builder(builder: (_) {
                  final w = _proteinSuggestion(selectedTags, protein);
                  return w ?? const SizedBox.shrink();
                }),
                const SizedBox(height: 12),
                // 病態タグ (常時展開)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('病態タグ',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in ConditionCatalog.all)
                      FilterChip(
                        label: Text(c.label,
                            style: const TextStyle(fontSize: 12)),
                        selected: selectedTags.contains(c.id),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onSelected: (sel) => setLocal(() {
                          if (sel) {
                            selectedTags.add(c.id);
                          } else {
                            selectedTags.remove(c.id);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                // Refeedingリスク評価(NICE) — 折りたたみ
                _buildRefeedingSection(
                  context: context,
                  weightKg: current.weightKg,
                  heightCm: current.heightCm,
                  fastingDate: fastingDate,
                  manualFlags: refeedingManualFlags,
                  expanded: refeedingExpanded,
                  onToggleExpand: () => setLocal(
                      () => refeedingExpanded = !refeedingExpanded),
                  onToggleFlag: (id, sel) => setLocal(() {
                    if (sel) {
                      refeedingManualFlags.add(id);
                    } else {
                      refeedingManualFlags.remove(id);
                    }
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: memoCtrl,
                  decoration: const InputDecoration(
                      labelText: 'メモ（合併症・コメントなど）',
                      hintText: '例: 糖尿病、CKDステージ3'),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    ),
  );
  if (saved != true) return;
  current.activityFactor = activity;
  current.stressFactor = stress;
  current.proteinGoalPerKg = protein;
  current.energyModel = energyModel;
  current.kcalPerKgValue = kcalPerKgValue;
  current.measuredREE = double.tryParse(reeCtrl.text.trim());
  current.patientId = patientIdCtrl.text.trim();
  if (caseCodeCtrl.text.trim().isNotEmpty) {
    current.caseCode = caseCodeCtrl.text.trim();
  }
  current.memo = memoCtrl.text.trim();
  // 入室日(入室レコードの changedAt)を更新
  if (admEntry != null && admissionDate != null) {
    admEntry.changedAt =
        admissionDate!.toIso8601String().split('T').first;
  }
  current.conditionTags = ConditionCatalog.all
      .map((c) => c.id)
      .where(selectedTags.contains)
      .toList();
  // 手動選択したRefeeding基準（手動候補のidに限定して保存・カタログ順を維持）。
  current.refeedingFlags = cr.kRefeedingCriteria
      .map((c) => c.id)
      .where(_isManualRefeedingFlag)
      .where(refeedingManualFlags.contains)
      .toList();
  current.fastingDate = fastingDate == null
      ? null
      : '${fastingDate!.year}-${fastingDate!.month.toString().padLeft(2, '0')}-${fastingDate!.day.toString().padLeft(2, '0')}';
  final newBed = bedIdx.toString().padLeft(2, '0');
  if (newBed != current.currentBed) {
    current.bedHistory.insert(
      0,
      BedAssignment(
        changedAt: DateTime.now().toIso8601String().split('T').first,
        fromBed: current.currentBed,
        toBed: newBed,
        note: 'ベッド移動',
      ),
    );
    current.currentBed = newBed;
  }
  await state.persist();
  onSaved?.call();
}

/// 手動入力すべきRefeeding基準か（BMI/絶食日数から自動で立つ基準=自動扱い、それ以外=手動）。
bool _isManualRefeedingFlag(String id) =>
    !id.startsWith('bmi_') && !id.startsWith('intake_');

/// 絶食開始日→現在の日数（null/未来は0）。Refeeding自動フラグの絶食日数に使う。
int _refeedingFastingDays(DateTime? fastingDate) {
  if (fastingDate == null) return 0;
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day)
      .difference(
          DateTime(fastingDate.year, fastingDate.month, fastingDate.day))
      .inDays;
  return d < 0 ? 0 : d;
}

/// 患者編集ダイアログの「Refeedingリスク評価(NICE)」折りたたみセクション。
/// - 自動フラグ(BMI/絶食日数由来)は読み取り専用チップ。
/// - 手動フラグ(体重減/低電解質/アルコール・薬物歴)は FilterChip でトグル。
/// - 自動∪手動を refeedingTierFromFlags で評価し tier と対処を色付き表示。
Widget _buildRefeedingSection({
  required BuildContext context,
  required double weightKg,
  required double heightCm,
  required DateTime? fastingDate,
  required Set<String> manualFlags,
  required bool expanded,
  required VoidCallback onToggleExpand,
  required void Function(String id, bool selected) onToggleFlag,
}) {
  final bmi = cbw.bmiOf(weightKg, heightCm);
  final days = _refeedingFastingDays(fastingDate);
  final autoFlags = cr.autoRefeedingFlags(bmi: bmi, daysNoIntake: days);
  // 評価は 自動 ∪ 手動。
  final allFlags = {...autoFlags, ...manualFlags};
  final tier = cr.refeedingTierFromFlags(allFlags);
  final tierColor = switch (tier) {
    cr.RefeedingTier.extreme => Colors.red.shade700,
    cr.RefeedingTier.high => Colors.orange.shade800,
    cr.RefeedingTier.none => Colors.green.shade700,
  };
  final manualCriteria =
      cr.kRefeedingCriteria.where((c) => _isManualRefeedingFlag(c.id)).toList();

  return Container(
    decoration: BoxDecoration(
      border: Border.all(color: Colors.grey.shade300),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ヘッダ（折りたたみトグル＋tierバッジ）
        InkWell(
          onTap: onToggleExpand,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: tierColor),
              const SizedBox(width: 4),
              const Expanded(
                child: Text('Refeedingリスク評価 (NICE)',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: tierColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: tierColor.withOpacity(0.5)),
                ),
                child: Text(tier.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: tierColor,
                        fontWeight: FontWeight.bold)),
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: Colors.grey.shade600),
            ]),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 自動で立つ基準（読み取り専用）
                Text('自動判定（BMI ${bmi.toStringAsFixed(1)} / 絶食 $days日）',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                const SizedBox(height: 4),
                if (autoFlags.isEmpty)
                  Text('該当なし',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500))
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final c in cr.kRefeedingCriteria
                          .where((c) => autoFlags.contains(c.id)))
                        Chip(
                          label: Text('${c.label}(自動)',
                              style: const TextStyle(fontSize: 11)),
                          backgroundColor: Colors.blueGrey.shade50,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          side: BorderSide(color: Colors.blueGrey.shade200),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                // 手動基準（トグル）
                Text('手動入力（体重減・電解質・既往歴）',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final c in manualCriteria)
                      FilterChip(
                        label: Text(c.label,
                            style: const TextStyle(fontSize: 11)),
                        selected: manualFlags.contains(c.id),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onSelected: (sel) => onToggleFlag(c.id, sel),
                      ),
                  ],
                ),
                if (tier != cr.RefeedingTier.none) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: tierColor.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: tierColor.withOpacity(0.3)),
                    ),
                    child: Text(cr.refeedingActionText(tier),
                        style: TextStyle(
                            fontSize: 11, color: tierColor, height: 1.4)),
                  ),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}

/// TOP画面の患者カード（折りたたみトグル付き）
class _CaseCard extends StatefulWidget {
  const _CaseCard({
    required this.item,
    required this.state,
    required this.refresh,
    required this.onDischarge,
  });
  final PatientCase item;
  final AppState state;
  final VoidCallback refresh;
  final VoidCallback onDischarge;

  @override
  State<_CaseCard> createState() => _CaseCardState();
}

class _CaseCardState extends State<_CaseCard> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final state = widget.state;
    final refresh = widget.refresh;
    void openBuilder() {
      state.selectedCaseId = item.id;
      refresh();
      Navigator.of(context).push(MaterialPageRoute(
          builder: (c) => BuilderPage(state: state, refresh: refresh)));
    }

    final admission =
        item.bedHistory.where((b) => b.fromBed == null).firstOrNull;
    final admDate = admission == null
        ? ''
        : (() {
            final p = DateTime.tryParse(admission.changedAt);
            return p == null
                ? admission.changedAt
                : '${p.year}/${p.month.toString().padLeft(2, '0')}/${p.day.toString().padLeft(2, '0')}';
          })();

    return GestureDetector(
      onHorizontalDragEnd: (_) => openBuilder(),
      child: Card(
        child: InkWell(
          onTap: openBuilder,
          onLongPress: openBuilder,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => showPatientEditDialog(context, state, item,
                        onSaved: refresh),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.person, size: 16),
                            const SizedBox(width: 2),
                            Text(item.caseCode,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold)),
                            if (item.patientId.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text('ID:${item.patientId}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                            const SizedBox(width: 10),
                            const Icon(Icons.bed, size: 16, color: Colors.grey),
                            const SizedBox(width: 2),
                            Text(item.currentBed,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold)),
                            if (admDate.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Icon(Icons.login,
                                  size: 14, color: Colors.green.shade400),
                              const SizedBox(width: 2),
                              Text(admDate,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.green.shade400)),
                            ],
                            if (item.fastingDate != null) ...[
                              const SizedBox(width: 10),
                              Icon(Icons.no_meals,
                                  size: 14, color: Colors.red.shade300),
                              const SizedBox(width: 2),
                              Text(() {
                                final p = DateTime.tryParse(item.fastingDate!);
                                return p == null
                                    ? item.fastingDate!
                                    : '${p.month}/${p.day}';
                              }(),
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.red.shade300)),
                            ],
                          ],
                        ),
                        ...[
                          const SizedBox(height: 2),
                          Text(item.patientInfoLine,
                              style: const TextStyle(fontSize: 14)),
                          if (item.memo.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(item.memo,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.grey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                FilledButton.tonal(
                    onPressed: openBuilder, child: const Text('計算')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: widget.onDischarge, child: const Text('退室')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CasesPage extends StatelessWidget {
  const CasesPage({super.key, required this.state, required this.refresh});
  final AppState state;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const Text('患者一覧',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    Text('(${state.cases.length}人)',
                        style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
                FilledButton(
                  onPressed: () => _openCaseDialog(context),
                  child: const Text('新規入室'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...state.cases.map((item) => _caseCard(item, context)),
      ],
    );
  }

  Widget _caseCard(PatientCase item, BuildContext context) {
    return _CaseCard(
      item: item,
      state: state,
      refresh: refresh,
      onDischarge: () => _dischargeCase(context, item),
    );
  }

  Future<void> _openCaseDialog(BuildContext context) async {
    final patientId = TextEditingController();
    final age = TextEditingController(text: '60');
    final height = TextEditingController(text: '150');
    final weight = TextEditingController(text: '50');

    // 空きベッドを自動検出 (1〜8)
    final usedBeds = state.cases.map((c) => int.tryParse(c.currentBed) ?? 0).toSet();
    int bedIndex = List.generate(8, (i) => i + 1).firstWhere(
      (b) => !usedBeds.contains(b),
      orElse: () => 1,
    );

    double activity = 1.2;
    double stress = 1.6;
    double protein = 1.5;
    String energyModel = 'kcalPerKg';
    double kcalPerKgValue = 25;
    final reeCtrl = TextEditingController();
    Sex sex = Sex.male;
    // 絶食開始日 デフォルト=入室日-3日
    DateTime? fastingDate =
        DateTime.now().subtract(const Duration(days: 3));
    final List<String> selectedTags = []; // 病態タグ
    bool showConditions = false; // 病態追加の展開状態

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final bedPad = bedIndex.toString().padLeft(2, '0');
          final isConflict = state.cases.any((c) => c.currentBed == bedPad);
          return AlertDialog(
          title: const Text('新規入室'),
          content: SizedBox(
            // ダイアログ幅を固定し、病態チップ展開時も横に広がらず縦に折り返す
            width: (MediaQuery.of(context).size.width - 80)
                .clamp(280.0, 400.0),
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 患者ID (ベッド番号の上・任意)
                    TextField(
                      controller: patientId,
                      decoration: const InputDecoration(
                        labelText: '患者ID (任意)',
                        hintText: 'カルテ番号など',
                        prefixIcon: Icon(Icons.badge_outlined, size: 18),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('ベッド: $bedPad',
                            style: const TextStyle(fontSize: 16)),
                        if (isConflict) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.orange),
                            ),
                            child: const Text('使用中',
                                style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
                          ),
                        ],
                      ],
                    ),
                    Slider(
                        value: bedIndex.toDouble(),
                        min: 1,
                        max: 8,
                        divisions: 7,
                        label: bedPad,
                        onChanged: (v) => setLocal(() => bedIndex = v.toInt())),
                    if (isConflict)
                      const Text(
                        'このベッドは既に使用中です。\n続行するとベッドが重複します。',
                        style: TextStyle(fontSize: 12, color: Colors.deepOrange),
                      ),
                    // 絶食開始日 (ベッド番号の下)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(Icons.no_meals,
                          size: 22,
                          color: fastingDate == null
                              ? Colors.grey.shade600
                              : Colors.red.shade400),
                      title: Text(
                        fastingDate == null
                            ? '絶食開始日: 未設定'
                            : '絶食開始日: ${fastingDate!.year}/${fastingDate!.month.toString().padLeft(2, '0')}/${fastingDate!.day.toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 14,
                            color: fastingDate == null
                                ? Colors.grey
                                : Colors.red.shade400),
                      ),
                      trailing: fastingDate != null
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () =>
                                  setLocal(() => fastingDate = null))
                          : const Icon(Icons.calendar_today, size: 18),
                      onTap: () async {
                        final picked = await _quickPickDate(
                            context, fastingDate ?? DateTime.now());
                        if (picked != null) {
                          setLocal(() => fastingDate = picked);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 年齢・身長・体重 (横並び)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                          controller: age,
                          decoration: const InputDecoration(
                              labelText: '年齢',
                              suffixText: '歳',
                              isDense: true),
                          keyboardType: TextInputType.number),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                          controller: height,
                          decoration: const InputDecoration(
                              labelText: '身長',
                              suffixText: 'cm',
                              isDense: true),
                          keyboardType: TextInputType.number),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                          controller: weight,
                          decoration: const InputDecoration(
                              labelText: '体重',
                              suffixText: 'kg',
                              isDense: true),
                          keyboardType: TextInputType.number),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 性別
                Row(
                  children: [
                    ChoiceChip(
                        label: const Text('男性'),
                        selected: sex == Sex.male,
                        onSelected: (_) => setLocal(() => sex = Sex.male)),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('女性'),
                        selected: sex == Sex.female,
                        onSelected: (_) => setLocal(() => sex = Sex.female)),
                  ],
                ),
                const SizedBox(height: 8),
                // エネルギー式
                ..._energyModelFields(
                  energyModel: energyModel,
                  kcalPerKgValue: kcalPerKgValue,
                  reeCtrl: reeCtrl,
                  onModel: (v) => setLocal(() => energyModel = v),
                  onKcalPerKg: (v) => setLocal(() => kcalPerKgValue = v),
                ),
                // AF/SFはHarris-Benedictのみ。簡易式/Mifflin/間接熱量測定では非表示
                if (energyModel == 'harrisBenedict') ...[
                const SizedBox(height: 8),
                // 活動係数・侵害係数 (横並び)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<double>(
                        initialValue: activity,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: '活動係数', isDense: true),
                        items: [
                          for (var i = 0; i < 7; i++)
                            _factorItem(1.0 + i * 0.1, _afHints)
                        ],
                        selectedItemBuilder: (context) => [
                          for (var i = 0; i < 7; i++)
                            Align(
                                alignment: Alignment.centerLeft,
                                child:
                                    Text((1.0 + i * 0.1).toStringAsFixed(1))),
                        ],
                        onChanged: (v) =>
                            setLocal(() => activity = v ?? activity),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<double>(
                        initialValue: stress,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: '侵害係数', isDense: true),
                        items: [
                          for (var i = 0; i < 13; i++)
                            _factorItem(0.9 + i * 0.1, _sfHints)
                        ],
                        selectedItemBuilder: (context) => [
                          for (var i = 0; i < 13; i++)
                            Align(
                                alignment: Alignment.centerLeft,
                                child:
                                    Text((0.9 + i * 0.1).toStringAsFixed(1))),
                        ],
                        onChanged: (v) =>
                            setLocal(() => stress = v ?? stress),
                      ),
                    ),
                  ],
                ),
                ],
                const SizedBox(height: 8),
                // 目標タンパク (ドロップダウン)
                DropdownButtonFormField<double>(
                  initialValue: double.parse(protein.toStringAsFixed(1)),
                  decoration: const InputDecoration(
                      labelText: '目標タンパク (g/kg/day)', isDense: true),
                  items: [for (var i = 6; i <= 20; i++) i * 0.1]
                      .map((v) => DropdownMenuItem(
                          value: double.parse(v.toStringAsFixed(1)),
                          child: Text(v.toStringAsFixed(1))))
                      .toList(),
                  onChanged: (v) => setLocal(() => protein = v ?? protein),
                ),
                Builder(builder: (_) {
                  final w = _proteinSuggestion(selectedTags, protein);
                  return w ?? const SizedBox.shrink();
                }),
                const SizedBox(height: 8),
                // 病態追加 (目標タンパクの下) — タップで展開
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        setLocal(() => showConditions = !showConditions),
                    icon: Icon(
                        showConditions
                            ? Icons.expand_less
                            : Icons.add_circle_outline,
                        size: 18,
                        color: Colors.teal.shade700),
                    label: Text(
                        selectedTags.isEmpty
                            ? '病態を追加'
                            : '病態 ${selectedTags.length}件選択中',
                        style: TextStyle(
                            fontSize: 13, color: Colors.teal.shade700)),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: Colors.teal.shade200),
                    ),
                  ),
                ),
                if (showConditions) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in ConditionCatalog.all)
                        FilterChip(
                          label: Text(c.label,
                              style: const TextStyle(fontSize: 12)),
                          selected: selectedTags.contains(c.id),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onSelected: (sel) => setLocal(() {
                            if (sel) {
                              selectedTags.add(c.id);
                            } else {
                              selectedTags.remove(c.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル')),
            FilledButton(
              onPressed: () async {
                final item = PatientCase(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  patientId: patientId.text.trim(),
                  caseCode: (() {
                    final nums = state.cases
                        .map((c) => int.tryParse(c.caseCode.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
                        .toList();
                    final next = nums.isEmpty ? 1 : nums.reduce((a, b) => a > b ? a : b) + 1;
                    return next.toString().padLeft(2, '0');
                  })(),
                  currentBed: bedIndex.toString().padLeft(2, '0'),
                  age: int.tryParse(age.text) ?? 60,
                  heightCm: double.tryParse(height.text) ?? 150,
                  weightKg: double.tryParse(weight.text) ?? 50,
                  sex: sex,
                  activityFactor: activity,
                  stressFactor: stress,
                  proteinGoalPerKg: protein,
                  createdAt: DateTime.now().toIso8601String(),
                  bedHistory: [
                    BedAssignment(
                      changedAt:
                          DateTime.now().toIso8601String().split('T').first,
                      fromBed: null,
                      toBed: bedIndex.toString().padLeft(2, '0'),
                      note: '初期登録',
                    ),
                  ],
                  regimenItems: [],
                  selectedProtocolId: 'five_day',
                  zeroMenuConfig: ZeroMenuConfig.defaultConfig(),
                  conditionTags: List.of(selectedTags),
                  energyModel: energyModel,
                  kcalPerKgValue: kcalPerKgValue,
                  measuredREE: double.tryParse(reeCtrl.text.trim()),
                );
                // 絶食開始日 (設定されていれば反映)
                if (fastingDate != null) {
                  item.fastingDate =
                      '${fastingDate!.year}-${fastingDate!.month.toString().padLeft(2, '0')}-${fastingDate!.day.toString().padLeft(2, '0')}';
                }
                await state.addCase(item);
                refresh();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('追加'),
            ),
          ],
        );  // AlertDialog
        },  // StatefulBuilder builder
      ),
    );
  }

  /// Phase 3-②: 症例名 (caseCode) を編集
  Future<void> _editCaseCode(BuildContext context, PatientCase item) async {
    final codeCtrl = TextEditingController(text: item.caseCode);

    // 入室レコードを取得
    final admissionEntry = item.bedHistory.where((b) => b.fromBed == null).firstOrNull;
    DateTime admissionDate = (admissionEntry != null
            ? DateTime.tryParse(admissionEntry.changedAt)
            : null) ??
        DateTime.now();
    DateTime? fastingDate = item.fastingDate != null
        ? DateTime.tryParse(item.fastingDate!)
        : null;
    int bedIdx = int.tryParse(item.currentBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
    bedIdx = bedIdx.clamp(1, 8);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('患者情報を編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: codeCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '症例名 / 匿名化ID',
                    hintText: '例: 01 / 佐藤さん など',
                  ),
                ),
                const SizedBox(height: 12),
                // 絶食日
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.no_meals,
                      size: 24,
                      color: fastingDate == null
                          ? Colors.grey.shade600
                          : Colors.red.shade400),
                  title: Text(
                    fastingDate == null
                        ? '絶食日: 未設定'
                        : '絶食日: ${fastingDate!.year}/${fastingDate!.month.toString().padLeft(2, '0')}/${fastingDate!.day.toString().padLeft(2, '0')}',
                    style: TextStyle(
                        color: fastingDate == null ? Colors.grey : null),
                  ),
                  trailing: fastingDate != null
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setLocal(() => fastingDate = null),
                        )
                      : null,
                  onTap: () async {
                    final picked = await _quickPickDate(
                        ctx, fastingDate ?? admissionDate);
                    if (picked != null) setLocal(() => fastingDate = picked);
                  },
                ),
                // 入室日時
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bed),
                  title: Text(
                    '入室日: ${admissionDate.year}/${admissionDate.month.toString().padLeft(2, '0')}/${admissionDate.day.toString().padLeft(2, '0')}',
                  ),
                  onTap: () async {
                    final picked = await _quickPickDate(ctx, admissionDate);
                    if (picked != null) setLocal(() => admissionDate = picked);
                  },
                ),
                const SizedBox(height: 8),
                // ベッド番号
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ベッド番号: ${bedIdx.toString().padLeft(2, '0')}'),
                    Slider(
                      value: bedIdx.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: bedIdx.toString().padLeft(2, '0'),
                      onChanged: (v) => setLocal(() => bedIdx = v.toInt()),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );

    if (saved != true) return;

    // 症例名を更新
    if (codeCtrl.text.trim().isNotEmpty) item.caseCode = codeCtrl.text.trim();

    // 絶食日を更新（ローカル年月日で保存 — toIso8601StringはUTC日付になるため使わない）
    item.fastingDate = fastingDate == null ? null
        : '${fastingDate!.year}-${fastingDate!.month.toString().padLeft(2, '0')}-${fastingDate!.day.toString().padLeft(2, '0')}';

    // ベッド番号を更新
    final newBed = bedIdx.toString().padLeft(2, '0');
    item.currentBed = newBed;

    // 入室レコードの日付・ベッド番号を更新
    final admIdx = item.bedHistory.indexWhere((b) => b.fromBed == null);
    if (admIdx >= 0) {
      item.bedHistory[admIdx] = BedAssignment(
        changedAt: admissionDate.toIso8601String().split('T').first,
        fromBed: null,
        toBed: newBed,
        note: item.bedHistory[admIdx].note,
      );
    }

    await state.persist();
    refresh();
  }

  /// Phase 3-③: ベッド履歴エントリをクリックして日付とベッド番号を一括編集
  Future<void> _editBedHistoryEntry(BuildContext context, PatientCase item,
      int index, AppState state, VoidCallback refresh) async {
    final entry = item.bedHistory[index];
    final isAdmission = entry.fromBed == null;
    DateTime selectedDate =
        DateTime.tryParse(entry.changedAt) ?? DateTime.now();
    int bedIdx =
        int.tryParse(entry.toBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
    bedIdx = bedIdx.clamp(1, 8);
    final noteCtrl = TextEditingController(text: entry.note);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(isAdmission ? '入室記録を編集' : 'ベッド移動を編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(
                      '日付: ${selectedDate.year}/${selectedDate.month.toString().padLeft(2, '0')}/${selectedDate.day.toString().padLeft(2, '0')}'),
                  onTap: () async {
                    final picked = await _quickPickDate(context, selectedDate);
                    if (picked != null) setLocal(() => selectedDate = picked);
                  },
                ),
                const SizedBox(height: 8),
                Text('ベッド番号: ${bedIdx.toString().padLeft(2, '0')}'),
                Slider(
                  value: bedIdx.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: bedIdx.toString().padLeft(2, '0'),
                  onChanged: (v) => setLocal(() => bedIdx = v.toInt()),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: 'メモ (任意)'),
                ),
              ],
            ),
          ),
          actions: [
            if (!isAdmission)
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('このベッド移動記録を削除'),
                      content: const Text('履歴から削除します。よろしいですか？'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('キャンセル')),
                        FilledButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('削除')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    item.bedHistory.removeAt(index);
                    await state.persist();
                    if (context.mounted) Navigator.pop(context, true);
                    refresh();
                  }
                },
                child:
                    const Text('この記録を削除', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );

    if (saved != true) return;
    final newBed = bedIdx.toString().padLeft(2, '0');
    item.bedHistory[index] = BedAssignment(
      changedAt: selectedDate.toIso8601String().split('T').first,
      fromBed: entry.fromBed,
      toBed: newBed,
      note: noteCtrl.text.trim(),
    );
    // 最新のエントリ (index 0) の場合は currentBed も同期
    if (index == 0) {
      item.currentBed = newBed;
    }
    await state.persist();
    refresh();
  }

  /// Phase 3-③: ベッド移動を追加する (旧「ベッド移動」ボタンの代替)
  Future<void> _addBedHistoryEntry(BuildContext context, PatientCase item,
      AppState state, VoidCallback refresh) async {
    DateTime selectedDate = DateTime.now();
    int bedIdx =
        int.tryParse(item.currentBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
    bedIdx = bedIdx.clamp(1, 8);
    final noteCtrl = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('ベッド移動を追加'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(
                      '日付: ${selectedDate.year}/${selectedDate.month.toString().padLeft(2, '0')}/${selectedDate.day.toString().padLeft(2, '0')}'),
                  onTap: () async {
                    final picked = await _quickPickDate(context, selectedDate);
                    if (picked != null) setLocal(() => selectedDate = picked);
                  },
                ),
                const SizedBox(height: 8),
                Text('移動先ベッド: ${bedIdx.toString().padLeft(2, '0')}'),
                Slider(
                  value: bedIdx.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: bedIdx.toString().padLeft(2, '0'),
                  onChanged: (v) => setLocal(() => bedIdx = v.toInt()),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: 'メモ (任意)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('追加')),
          ],
        ),
      ),
    );

    if (saved != true) return;
    final newBed = bedIdx.toString().padLeft(2, '0');
    if (newBed == item.currentBed) {
      // 同じベッドなら追加しない
      return;
    }
    item.bedHistory.insert(
      0,
      BedAssignment(
        changedAt: selectedDate.toIso8601String().split('T').first,
        fromBed: item.currentBed,
        toBed: newBed,
        note: noteCtrl.text.trim(),
      ),
    );
    item.currentBed = newBed;
    await state.persist();
    refresh();
  }

  Future<void> _dischargeCase(BuildContext context, PatientCase item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退室確認'),
        content: Text('${item.displayLabel} を退室させますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退室')),
        ],
      ),
    );

    if (confirm == true) {
      await state.removeCase(item.id);
      refresh();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${item.displayLabel} を退室しました')));
      }
    }
  }

  Future<void> _selectBed(BuildContext context, PatientCase item,
      AppState state, VoidCallback refresh) async {
    // ベッド番号は数字のみの保存だが、旧データや ICU-xx 形式も考慮
    int idx =
        int.tryParse(item.currentBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
    idx = idx.clamp(1, 8);
    final picked = await showDialog<int?>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('ベッドを選択'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(idx.toString().padLeft(2, '0')),
              Slider(
                  value: idx.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  label: idx.toString().padLeft(2, '0'),
                  onChanged: (v) => setLocal(() => idx = v.toInt())),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(context, idx),
                child: const Text('選択')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final target = picked.toString().padLeft(2, '0');
    final conflict =
        state.cases.any((e) => e.id != item.id && e.currentBed == target);
    if (conflict) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ベッド重複'),
          content: Text('選択した $target は既に他の症例で使用されています。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('閉じる'))
          ],
        ),
      );
      return;
    }
    final prev = item.currentBed;
    if (prev != target) {
      item.bedHistory.insert(
        0,
        BedAssignment(
            changedAt: DateTime.now().toIso8601String().split('T').first,
            fromBed: prev,
            toBed: target,
            note: '選択で移動'),
      );
      item.currentBed = target;
      await state.persist();
      refresh();
    }
  }
}
