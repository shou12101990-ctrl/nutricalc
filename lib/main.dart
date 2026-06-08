import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';
import 'clinical/constants.dart' as ck;
import 'clinical/body_weight.dart' as cbw;
import 'clinical/energy.dart' as ce;
import 'clinical/protein.dart' as cp;
import 'clinical/conditions.dart' as cc;
import 'clinical/infusion.dart' as ci;
import 'clinical/refeeding.dart' as cr;
import 'clinical/micronutrients.dart' as cm;

/// AF / SF ドロップダウン用の説明ラベル（値の toStringAsFixed(1) をキーにする）
const _afHints = {
  '1.0': '寝たきり体動なし',
  '1.1': '寝たきり体動あり',
  '1.2': '車椅子',
  '1.3': '歩行',
  '1.4': '歩行あり',
  '1.5': '積極的リハ',
  '1.6': '積極的リハ',
};
const _sfHints = {
  '0.9': '',
  '1.0': 'ストレスなし',
  '1.1': '手術 / 癌',
  '1.2': '手術 / 癌 / 感染症',
  '1.3': '手術 / 癌 / 感染症',
  '1.4': '感染症 / 発熱',
  '1.5': '感染症 / 発熱',
  '1.6': '敗血症',
  '1.7': '手術',
  '1.8': '手術',
  '1.9': '熱傷',
  '2.0': '熱傷',
  '2.1': '熱傷',
};

/// AF/SF DropdownMenuItem 生成ヘルパー (数値 + 薄い説明ラベル)
DropdownMenuItem<double> _factorItem(double v, Map<String, String> hints) {
  final key = v.toStringAsFixed(1);
  final hint = hints[key] ?? '';
  return DropdownMenuItem<double>(
    value: double.parse(key),
    child: Row(
      children: [
        Text(key, style: const TextStyle(fontSize: 14)),
        if (hint.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text(hint,
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontWeight: FontWeight.normal)),
        ],
      ],
    ),
  );
}

/// 製品名から容量サフィックス・剤型語を除いた「ベース名」を返す。
/// 例: "ツインパル輸液(500mL)" → "ツインパル", "エルネオパNF1号輸液(1500mL)" → "エルネオパNF1号"
/// 同一ベース名＝同一製剤(容量違い)としてマスタで1項目に集約する。
String productBaseName(String name) {
  var n = name.trim();
  n = n.replaceAll(RegExp(r'「[^」]*」'), ''); // メーカー注記
  n = n.replaceAll(RegExp(r'[\(（][^\)）]*[\)）]'), ''); // (容量) 等
  for (final s in ['配合経腸用液', '配合内用剤', '配合散', '経腸用液', '点滴静注', '注射液', '輸液']) {
    n = n.replaceAll(s, '');
  }
  return n.trim();
}

/// 加注製剤の「何製剤か」表示順（あいうえお順ではなく種別順）
const _additiveTypeOrder = {
  '電解質': ['Na', 'K', 'Cl', 'Ca', 'Mg', 'P', 'HCO3'],
  '微量元素': ['総合', 'Zn', 'Fe', 'Se'],
  'ビタミン': ['総合', 'B群', '単独'],
};

/// あいうえお順ソート用キー: ひらがな→カタカナに統一して五十音順に揃える
/// (英数字→かな→漢字 の順)
String kanaSortKey(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x3041 && r <= 0x3096) {
      buf.writeCharCode(r + 0x60); // ひらがな→カタカナ
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

/// 製剤リストを表示用に整列したコピーを返す。
/// 加注(電解質/微量元素/ビタミン)は種別順、それ以外はあいうえお順。
List<Product> sortProductsForDisplay(List<Product> list, {String? additiveCat}) {
  final sorted = [...list];
  final order = additiveCat != null ? _additiveTypeOrder[additiveCat] : null;
  if (order != null) {
    sorted.sort((a, b) {
      var ra = order.indexOf(a.addType ?? '');
      if (ra < 0) ra = 999;
      var rb = order.indexOf(b.addType ?? '');
      if (rb < 0) rb = 999;
      if (ra != rb) return ra.compareTo(rb);
      return kanaSortKey(a.name).compareTo(kanaSortKey(b.name));
    });
  } else {
    sorted.sort((a, b) => kanaSortKey(a.name).compareTo(kanaSortKey(b.name)));
  }
  return sorted;
}

/// 日付を1タップで選択して即閉じるカレンダーダイアログ
Future<DateTime?> _quickPickDate(BuildContext context, DateTime initial) {
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: CalendarDatePicker(
          initialDate: initial,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
          onDateChanged: (d) => Navigator.pop(ctx, d),
        ),
      ),
    ),
  );
}

/// 患者情報編集ダイアログ（TOP画面・ビルダー画面で共通利用）
/// 患者/入室日は固定表示。絶食開始日・ベッド・AF/SF・目標タンパク・病態タグ・メモを編集。
/// エネルギー式セレクタ（患者編集/新規入室で共用）。
/// kcal/kg選択時は kcal/kg ドロップダウン、間接熱量測定時はREE入力欄を出す。
List<Widget> _energyModelFields({
  required String energyModel,
  required double kcalPerKgValue,
  required TextEditingController reeCtrl,
  required ValueChanged<String> onModel,
  required ValueChanged<double> onKcalPerKg,
}) {
  // 簡易式の目標 kcal/kg: 20–30 を1刻み。保存済みの端数値があっても
  // Dropdownが壊れないよう、現在値も候補に含める。
  final kkItems = <double>{
    for (int i = 20; i <= 30; i++) i.toDouble(),
    kcalPerKgValue,
  }.toList()
    ..sort();
  return [
    DropdownButtonFormField<String>(
      initialValue: energyModel,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'エネルギー式', isDense: true),
      items: const [
        DropdownMenuItem(
            value: 'harrisBenedict', child: Text('Harris-Benedict ×係数')),
        DropdownMenuItem(
            value: 'mifflinStJeor', child: Text('Mifflin-St Jeor ×係数')),
        DropdownMenuItem(value: 'kcalPerKg', child: Text('簡易式 (kcal/kg)')),
        DropdownMenuItem(
            value: 'indirectCalorimetry', child: Text('間接熱量測定 (実測REE)')),
      ],
      onChanged: (v) {
        if (v != null) onModel(v);
      },
    ),
    if (energyModel == 'kcalPerKg') ...[
      const SizedBox(height: 8),
      DropdownButtonFormField<double>(
        initialValue: kcalPerKgValue,
        isExpanded: true,
        decoration:
            const InputDecoration(labelText: '目標 kcal/kg/day', isDense: true),
        items: kkItems
            .map((v) => DropdownMenuItem(
                value: v,
                child: Text(v == v.roundToDouble()
                    ? v.toStringAsFixed(0)
                    : v.toStringAsFixed(1))))
            .toList(),
        onChanged: (v) {
          if (v != null) onKcalPerKg(v);
        },
      ),
    ],
    if (energyModel == 'indirectCalorimetry') ...[
      const SizedBox(height: 8),
      TextField(
        controller: reeCtrl,
        keyboardType: TextInputType.number,
        decoration:
            const InputDecoration(labelText: '実測REE (kcal/day)', isDense: true),
      ),
    ],
  ];
}

/// 過剰栄養アラート（表示のみ・非強制）。
/// H-B / Mifflin など「基礎代謝×活動係数×侵害係数」のモデルで、侵害係数が高く(≥1.5)、
/// 目標が 30 kcal/kg/day を超える場合に、過剰栄養(overfeeding)の可能性を控えめに注意する。
/// 簡易式(kcal/kg)・間接熱量測定は対象外。該当なしは null。
Widget? _energyOverfeedAlert(PatientCase item) {
  final model = item.energyModel;
  if (model != 'harrisBenedict' && model != 'mifflinStJeor') return null;
  final er = NutritionCalculator.targetEnergyResult(item);
  if (er.feedingWeightKg <= 0) return null;
  final kcalPerKg = er.kcal / er.feedingWeightKg;
  if (!(item.stressFactor >= 1.5 && kcalPerKg > 30)) return null;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.orange.shade300),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded,
            size: 14, color: Colors.orange.shade800),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            '約${kcalPerKg.round()} kcal/kg/day と過剰栄養の可能性。'
            '侵害係数が高く H-B×係数は過大評価しがちです。'
            '25–30 kcal/kg（簡易式）も検討してください。',
            style: TextStyle(
                fontSize: 11, color: Colors.orange.shade900, height: 1.3),
          ),
        ),
      ],
    ),
  );
}

/// 病態に基づくタンパク推奨範囲サジェスト（非強制・表示のみ）。該当なしは null。
Widget? _proteinSuggestion(Iterable<String> tags, double currentGoal) {
  final ranges = cc.proteinRangesFor(tags);
  if (ranges.isEmpty) return null;
  final inter = cc.intersectedProteinRange(tags);
  final outside =
      inter != null && (currentGoal < inter.min || currentGoal > inter.max);
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.teal.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.teal.shade200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('💡 推奨タンパク',
            style: TextStyle(
                fontSize: 11,
                color: Colors.teal.shade800,
                fontWeight: FontWeight.bold)),
        for (final c in ranges)
          Text(
            '${ConditionCatalog.labelOf(c.id)}: '
            '${c.proteinMinPerKg}–${c.proteinMaxPerKg} g/kg',
            style: TextStyle(fontSize: 11.5, color: Colors.teal.shade900),
          ),
        if (outside)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '現在値 ${currentGoal.toStringAsFixed(1)} g/kg は推奨範囲外（医師判断で許容可）',
              style: TextStyle(fontSize: 11, color: Colors.deepOrange.shade400),
            ),
          ),
      ],
    ),
  );
}

/// 病態タグ→微量栄養素アラートのコンテキストフラグ。
({
  bool cholestasis,
  bool liver,
  bool renal,
  bool crrt,
  bool giLoss,
  bool wernicke
}) _microFlags(Iterable<String> tags,
    {required double bmi, bool refeedingHigh = false}) {
  final t = tags.toSet();
  return (
    cholestasis: t.contains('cholestasis'),
    liver: t.contains('liver'),
    renal: t.contains('renal'),
    crrt: t.contains('crrt'),
    giLoss: t.contains('gi_loss') || t.contains('malabsorption'),
    wernicke: t.contains('alcohol') || bmi < 16 || refeedingHigh,
  );
}

Future<void> showPatientEditDialog(
    BuildContext context, AppState state, PatientCase current,
    {VoidCallback? onSaved}) async {
  double activity = current.activityFactor;
  double stress = current.stressFactor;
  double protein = current.proteinGoalPerKg;
  String energyModel = current.energyModel;
  double kcalPerKgValue = current.kcalPerKgValue ?? 30;
  final reeCtrl =
      TextEditingController(text: current.measuredREE?.toStringAsFixed(0) ?? '');
  final memoCtrl = TextEditingController(text: current.memo);
  final selectedTags = current.conditionTags.toSet();
  DateTime? fastingDate = current.fastingDate != null
      ? DateTime.tryParse(current.fastingDate!)
      : null;
  int bedIdx =
      (int.tryParse(current.currentBed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1)
          .clamp(1, 8);
  final admEntry =
      current.bedHistory.where((b) => b.fromBed == null).firstOrNull;
  final admDateStr = admEntry == null
      ? '—'
      : (() {
          final p = DateTime.tryParse(admEntry.changedAt);
          return p == null ? admEntry.changedAt : '${p.month}/${p.day}';
        })();

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
                // 患者
                Row(children: [
                  const Icon(Icons.person, size: 16, color: Colors.black54),
                  const SizedBox(width: 2),
                  Text('患者${current.caseCode}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 6),
                // 入室日 | 絶食開始日 (横並び・mm/dd)
                Row(children: [
                  Icon(Icons.login, size: 14, color: Colors.green.shade500),
                  const SizedBox(width: 2),
                  Text('入室 $admDateStr',
                      style: TextStyle(
                          fontSize: 13, color: Colors.green.shade600)),
                  const SizedBox(width: 16),
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
  current.memo = memoCtrl.text.trim();
  current.conditionTags = ConditionCatalog.all
      .map((c) => c.id)
      .where(selectedTags.contains)
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final catalog = await ProductCatalog.load();
  final store = LocalStore();
  final state = await AppState.bootstrap(catalog, store);
  runApp(NutritionApp(state: state));
}

class NutritionApp extends StatelessWidget {
  const NutritionApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'やさしい栄養処方 Nutri Calc β',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
        fontFamily: 'Meiryo',
      ),
      home: HomePage(state: state),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      CasesPage(state: widget.state, refresh: _refresh),
      MasterPage(state: widget.state),
      NotePage(state: widget.state),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('やさしい栄養処方 Nutri Calc β'),
        actions: [
          // 件数はヘッダーではなく患者一覧タイトル横に移動したので非表示
        ],
      ),
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) => setState(() => index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bed_outlined), label: 'ベッド管理'),
          NavigationDestination(
              icon: Icon(Icons.medical_information_outlined), label: '製剤マスタ'),
          NavigationDestination(
              icon: Icon(Icons.notes_outlined), label: 'ノート'),
        ],
      ),
    );
  }

  void _refresh() => setState(() {});
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
    double kcalPerKgValue = 30;
    final reeCtrl = TextEditingController();
    Sex sex = Sex.male;
    DateTime? fastingDate = DateTime.now(); // 絶食開始日(デフォルト=入室日)
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

class BuilderPage extends StatefulWidget {
  const BuilderPage({super.key, required this.state, required this.refresh});
  final AppState state;
  final VoidCallback refresh;

  @override
  State<BuilderPage> createState() => _BuilderPageState();
}

class _BuilderPageState extends State<BuilderPage>
    with TickerProviderStateMixin {
  String category = 'EN';
  // サマリーパネル（個別選択/ゼロmenu）
  double _summaryHeight = 80.0;
  double _snapFrom = 80.0;
  double _snapToTarget = 80.0;
  double _scrollFrom = 0.0;
  double _scrollToTarget = 0.0;
  late AnimationController _snapCtrl;
  final ScrollController _listScroll = ScrollController();
  // 栄養の推移パネル（自動計算タブ）
  static const double _chartPanelMin = 72.0;
  double _chartPanelHeight = 230.0;
  double _chartSnapFrom = 230.0;
  double _chartSnapToTarget = 230.0;
  late AnimationController _chartSnapCtrl;
  final ScrollController _chartScroll = ScrollController();
  // Phase 4-③: 処方ビルダーの2タブ状態 (0: EN/TPN/PPN 選択, 1: ゼロからブレンド)
  int _builderTabIndex = 0;
  bool _builderCardCollapsed = false; // 計算画面の患者カード折りたたみ
  bool _summaryCollapsed = false; // サマリーパネル折りたたみ
  final targetKcalController = TextEditingController(text: '1500');
  final npcnController = TextEditingController(text: '150');
  double _lipidGPerKg = 0.4;
  String glucoseSource = '70% グルコース';
  // ゼロmenu: 2サブタブ (0:本体, 1:加注) と加注製剤リスト(複数可)
  int _zeroSubTab = 0;
  final List<String> _zeroAdditives = [];
  // 個別選択モードの加注（デフォルト空。ゼロmenuの_zeroAdditivesとは独立）
  final List<String> _selectAdditives = [];
  final Set<String> expandedProducts = {};
  double _enRateMlPerHour = 0;
  // TPN/PPN 流量(ml/h)。0 = 「24hかけて」(=総量÷24)、>0 = 固定速度。表示・処方箋用。
  double _tpnRateMlPerHour = 0;
  double _ppnRateMlPerHour = 0;

  @override
  void initState() {
    super.initState();
    // ゼロmenu 加注の既定: 微量元素・ビタミンを標準で1つずつ追加
    final defTrace = widget.state.catalog.byCategory('微量元素').firstOrNull?.name;
    final defVit = widget.state.catalog.byCategory('ビタミン').firstOrNull?.name;
    if (defTrace != null) _zeroAdditives.add(defTrace);
    if (defVit != null) _zeroAdditives.add(defVit);
    // 病態に応じてゼロmenu係数を自動設定（NPC/N・脂質g/kg を中央値に）。病態なしは既定維持。
    final selCase = widget.state.selectedCase;
    if (selCase != null) {
      final rc = cc.resolveCoeff(selCase.conditionTags);
      if (rc != null) {
        npcnController.text = rc.npcN.toStringAsFixed(0);
        _lipidGPerKg = double.parse(rc.lipidGPerKg.toStringAsFixed(1));
      }
    }
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _snapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapCtrl.value);
      setState(() => _summaryHeight = _snapFrom + (_snapToTarget - _snapFrom) * t);
      if (_listScroll.hasClients) {
        final target = (_scrollFrom + (_scrollToTarget - _scrollFrom) * t)
            .clamp(0.0, _listScroll.position.maxScrollExtent);
        _listScroll.jumpTo(target);
      }
    });
    _chartSnapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _chartSnapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_chartSnapCtrl.value);
      setState(() => _chartPanelHeight =
          _chartSnapFrom + (_chartSnapToTarget - _chartSnapFrom) * t);
    });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _chartSnapCtrl.dispose();
    _listScroll.dispose();
    _chartScroll.dispose();
    super.dispose();
  }

  /// 静脈栄養(TPN/PPN)由来のブドウ糖・脂質グラム（GIR/脂質速度の評価用）。
  ({double glucoseG, double lipidG}) _parenteralMacros(PatientCase current) {
    double glu = 0, fat = 0;
    for (final item in current.regimenItems) {
      final p = widget.state.catalog.byId(item.productId);
      if (p == null || item.units <= 0) continue;
      if (p.category == 'TPN' || p.category == 'PPN') {
        glu += (p.carbBase ?? 0) * item.units;
        fat += (p.fatBase ?? 0) * item.units;
      }
    }
    return (glucoseG: glu, lipidG: fat);
  }

  Widget _infusionAlertRow(ci.AlertLevel lv, String text) {
    final color = lv == ci.AlertLevel.danger
        ? Colors.red.shade600
        : Colors.orange.shade800;
    final label = lv == ci.AlertLevel.danger ? '危険' : '注意';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text('$label  $text',
              style: TextStyle(fontSize: 11.5, color: color)),
        ),
      ]),
    );
  }

  /// GIR・脂質負荷速度のアラート群（超過時のみ表示。糖質制限病態はGIR上限4）。
  List<Widget> _infusionAlertList({
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required double weightKg,
    required bool glucoseRestrict,
  }) {
    final rows = <Widget>[];
    if (glucoseGramPerDay > 0 && weightKg > 0) {
      final girVal =
          ci.gir(glucoseGramPerDay: glucoseGramPerDay, weightKg: weightKg);
      final hardLimit =
          glucoseRestrict ? 4.0 : ck.ClinicalConst.girLimitMgKgMin;
      final warnAt = glucoseRestrict ? 3.5 : ck.ClinicalConst.girWarnMgKgMin;
      final lv = ci.girLevel(girVal, warn: warnAt, limit: hardLimit);
      if (lv != ci.AlertLevel.ok) {
        rows.add(_infusionAlertRow(lv,
            'GIR ${girVal.toStringAsFixed(1)} mg/kg/min（上限${hardLimit.toStringAsFixed(0)}）糖負荷過剰、高血糖・脂肪肝に注意'));
      }
    }
    if (lipidGramPerDay > 0 && weightKg > 0) {
      final rate = ci.lipidRatePerHour(
          lipidGramPerDay: lipidGramPerDay, weightKg: weightKg);
      final perDay = ci.lipidPerDayGramPerKg(
          lipidGramPerDay: lipidGramPerDay, weightKg: weightKg);
      final lvRate = ci.lipidRateLevel(rate);
      final lvDay = ci.lipidDayLevel(perDay);
      final lv = lvRate.index >= lvDay.index ? lvRate : lvDay;
      if (lv != ci.AlertLevel.ok) {
        rows.add(_infusionAlertRow(lv,
            '脂質 ${perDay.toStringAsFixed(2)} g/kg/day・${rate.toStringAsFixed(3)} g/kg/h、高TG血症に注意'));
      }
    }
    return rows;
  }

  Widget _infusionAlerts({
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required double weightKg,
    required bool glucoseRestrict,
  }) {
    final rows = _infusionAlertList(
      glucoseGramPerDay: glucoseGramPerDay,
      lipidGramPerDay: lipidGramPerDay,
      weightKg: weightKg,
      glucoseRestrict: glucoseRestrict,
    );
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// サマリー下部のアラート群（GIR/脂質 + 微量栄養素UL + 病態ガイダンス）。
  List<Widget> _summaryAlertWidgets({
    required PatientCase current,
    required double glucoseGramPerDay,
    required double lipidGramPerDay,
    required cm.MicroTotals micro,
  }) {
    final restrict =
        cc.resolveCoeff(current.conditionTags)?.glucoseRestrict ?? false;
    return [
      ..._infusionAlertList(
        glucoseGramPerDay: glucoseGramPerDay,
        lipidGramPerDay: lipidGramPerDay,
        weightKg: current.weightKg,
        glucoseRestrict: restrict,
      ),
      ..._microAlertRows(micro, current,
          glucoseLoad: glucoseGramPerDay > 0),
    ];
  }

  /// 個別選択の全ソース横断 微量栄養素集計。
  /// `_aggregateWithRates` と同一のソース集合(EN/EN補助/TPN/PPN/濃厚流動食/栄養サポート/加注)
  /// と同一の按分係数(投与速度指定時)で集計するため、マクロ集計と整合し各itemは1回のみ計上。
  cm.MicroTotals _microWithRates(PatientCase current) {
    final contributions = <cm.MicroContribution>[];
    int unitsOf(RegimenItem item) => item.hasMealTiming
        ? (item.morning + item.noon + item.evening)
        : item.units;

    // 製剤の実効本数: EN=本数(rate按分対象)、TPN/PPN=units+部分ml/bagVol(per-product ml)。
    double effOf(RegimenItem item, Product p, String categoryKey) {
      if (categoryKey == 'EN') return unitsOf(item).toDouble();
      final bagVol = p.volumeMl ?? 0;
      return item.units + (bagVol > 0 ? item.partialMl / bagVol : 0);
    }

    void addCategory(String categoryKey, double rate) {
      final selected = current.regimenItems.where((item) {
        final p = widget.state.catalog.byId(item.productId);
        if (p == null) return false;
        if (categoryKey == 'EN') {
          if (!(p.category == 'EN' || p.category == 'EN_AUX')) return false;
          return unitsOf(item) > 0;
        }
        if (p.category != categoryKey) return false;
        return item.units > 0 || item.partialMl > 0;
      }).toList();
      if (selected.isEmpty) return;
      double fullIN = 0;
      for (final item in selected) {
        final p = widget.state.catalog.byId(item.productId)!;
        fullIN += (p.volumeMl ?? 0) * effOf(item, p, categoryKey);
      }
      // ENのみ投与速度で按分。TPN/PPNはper-product mlがそのまま日量。
      final factor =
          (categoryKey == 'EN' && rate > 0 && fullIN > 0) ? (rate * 24) / fullIN : 1.0;
      for (final item in selected) {
        final p = widget.state.catalog.byId(item.productId)!;
        contributions.add(
            cm.MicroContribution(p.micro, effOf(item, p, categoryKey) * factor));
      }
    }

    addCategory('EN', _enRateMlPerHour);
    addCategory('TPN', 0);
    addCategory('PPN', 0);
    addCategory('濃厚流動食', 0);
    addCategory('栄養サポート食品', 0);
    for (final name in _selectAdditives) {
      final p = widget.state.catalog.byName(name);
      if (p != null) contributions.add(cm.MicroContribution(p.micro, 1));
    }
    return cm.aggregateMicro(contributions);
  }

  /// 微量栄養素のUL超過＋病態別ガイダンスのアラート行（_infusionAlertRow を流用）。
  List<Widget> _microAlertRows(cm.MicroTotals totals, PatientCase current,
      {bool glucoseLoad = false}) {
    final bmi = cbw.bmiOf(current.weightKg, current.heightCm);
    final f = _microFlags(current.conditionTags, bmi: bmi);
    return cm
        .microAlerts(totals,
            isMale: current.sex == Sex.male,
            cholestasis: f.cholestasis,
            liver: f.liver,
            renal: f.renal,
            crrt: f.crrt,
            giLoss: f.giLoss,
            glucoseLoad: glucoseLoad,
            wernickeRisk: f.wernicke)
        .map((a) => _infusionAlertRow(
            a.level == ci.AlertLevel.danger
                ? ci.AlertLevel.danger
                : ci.AlertLevel.caution,
            a.message))
        .toList();
  }

  /// 採用済み(なければ全体)から条件に合う製剤を1つ選ぶ。
  Product? _pickAdoptedProduct(bool Function(Product) test) {
    final all = widget.state.catalog.products.where(test).toList();
    final adopted =
        all.where((p) => widget.state.isAdopted(p.id)).toList();
    if (adopted.isNotEmpty) return adopted.first;
    return all.isNotEmpty ? all.first : null;
  }

  /// ベース製剤の内蔵成分に応じた非重複の推奨加注（胆汁うっ滞/肝障害ならMn-free）。
  List<String> _recommendedSelectAdditives(PatientCase current) {
    final bases = <Product>[];
    for (final it in current.regimenItems) {
      final p = widget.state.catalog.byId(it.productId);
      final n =
          it.hasMealTiming ? (it.morning + it.noon + it.evening) : it.units;
      if (p != null && n > 0) bases.add(p);
    }
    final hasVit = bases.any((p) => p.kitHasVitamins);
    final hasTrace = bases.any((p) => p.kitHasFullTrace);
    final mnAvoid = current.conditionTags.contains('cholestasis') ||
        current.conditionTags.contains('liver');
    final out = <String>[];
    if (!hasVit) {
      final mvi = _pickAdoptedProduct((p) => p.isFullMvi);
      if (mvi != null) out.add(mvi.name);
    }
    if (!hasTrace) {
      final trace = mnAvoid
          ? (_pickAdoptedProduct((p) => p.isMnFreeTrace) ??
              _pickAdoptedProduct((p) => p.isCombinedTrace))
          : _pickAdoptedProduct((p) => p.isCombinedTrace);
      if (trace != null) out.add(trace.name);
    }
    return out;
  }

  void _snapTo(double target) {
    _snapFrom = _summaryHeight;
    _snapToTarget = target;
    _scrollFrom = _listScroll.hasClients ? _listScroll.offset : 0.0;
    final delta = target - _summaryHeight;
    _scrollToTarget = _scrollFrom + delta.clamp(0.0, double.infinity);
    _snapCtrl.forward(from: 0);
  }

  void _chartSnapTo(double target) {
    _chartSnapFrom = _chartPanelHeight;
    _chartSnapToTarget = target;
    _chartSnapCtrl.forward(from: 0);
  }

  static const _infusionRateOptions = [0.0, 10.0, 20.0, 30.0, 40.0];

  String _rateLabel(double rate) =>
      rate <= 0 ? '全量' : '${rate.toStringAsFixed(0)} ml/h';

  List<Product> _selectedProductsForCategory(String category) {
    if (category == 'EN') {
      return widget.state.catalog.products.where((p) {
        return (p.category == 'EN' || p.category == 'EN_AUX') &&
            widget.state.isAdopted(p.id);
      }).toList();
    }
    return widget.state.catalog
        .byCategory(category)
        .where((p) => widget.state.isAdopted(p.id))
        .toList();
  }

  /// EN投与速度（持続）指定時、8h交換で1バッグに必要な本数に処方を自動調整する。
  /// 必要本数 = ceil(速度ml/h × 8h ÷ 製剤容量ml)。
  /// すでに処方されているタイミング(朝/昼/夕で1本以上)を必要本数ちょうどに合わせる（増減両方）。
  /// EN本体のみ対象（EN補助製剤は調整しない）。本数は朝昼夕ドロップダウンの上限3まで。
  Future<void> _adjustEnUnitsForRate(PatientCase current) async {
    final perBagMl = _enRateMlPerHour * 8; // ENは8h毎に交換
    for (final item in current.regimenItems.toList()) {
      final product = widget.state.catalog.byId(item.productId);
      if (product == null) continue;
      if (product.category != 'EN') continue; // EN補助(EN_AUX)は調整off
      final vol = product.volumeMl ?? 0;
      if (vol <= 0) continue;
      final needed = (perBagMl / vol).ceil().clamp(1, 3);
      if (item.hasMealTiming) {
        // 処方済み(>0)のタイミングだけを必要本数に揃える（0のタイミングは触らない）
        final m = item.morning > 0 ? needed : 0;
        final n = item.noon > 0 ? needed : 0;
        final e = item.evening > 0 ? needed : 0;
        if (m != item.morning || n != item.noon || e != item.evening) {
          await widget.state.setMealUnits(current.id, product, m, n, e);
        }
      } else if (item.units > 0 && item.units != needed) {
        await widget.state.setUnits(current.id, product, needed);
      }
    }
  }

  AggregateResult _aggregateWithRates(PatientCase current) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;

    final activeItems = current.regimenItems.toList();

    // 各レジメンアイテムの「本数」: EN朝昼夕が設定されていれば合計、なければ units
    int unitsOf(RegimenItem item) =>
        item.hasMealTiming ? (item.morning + item.noon + item.evening) : item.units;

    // Excel準拠の本数ベース集計。製剤の kcal/aminoAcidG/fatBase/carbBase/volumeMl は
    // 1パック(1本)あたりの値なので、本数を掛けるだけでよい（密度換算は不要）。
    void processCategory(String categoryKey, double rate) {
      // 該当カテゴリの実際に選択されている製剤(本数>0)を抽出
      final selectedItems = activeItems.where((item) {
        final product = widget.state.catalog.byId(item.productId);
        if (product == null) return false;
        if (categoryKey == 'EN') {
          if (!(product.category == 'EN' || product.category == 'EN_AUX')) {
            return false;
          }
          return unitsOf(item) > 0;
        }
        if (product.category != categoryKey) return false;
        // TPN/PPN/食事: 本数>0 または 部分ml>0
        return item.units > 0 || item.partialMl > 0;
      }).toList();

      // 製剤が選ばれていなければ投与速度を動かしても何も加算しない
      if (selectedItems.isEmpty) return;

      // 実効本数: EN=本数、TPN/PPN=units+部分ml/bagVol(per-product ml指定)。
      double effOf(RegimenItem item, Product product) {
        if (categoryKey == 'EN') return unitsOf(item).toDouble();
        final bagVol = product.volumeMl ?? 0;
        return item.units + (bagVol > 0 ? item.partialMl / bagVol : 0);
      }

      // 集計（本数/ml ベース）— Excel T19/T20/T21/T23 に対応
      double fullIN = 0, fullKcal = 0, fullProt = 0, fullFatG = 0, fullCarbG = 0;
      for (final item in selectedItems) {
        final product = widget.state.catalog.byId(item.productId)!;
        final n = effOf(item, product);
        fullIN += (product.volumeMl ?? 0) * n;
        fullKcal += (product.kcal ?? 0) * n;
        fullProt += (product.aminoAcidG ?? 0) * n;
        fullFatG += (product.fatBase ?? 0) * n;
        fullCarbG += (product.carbBase ?? 0) * n;
      }

      // ENのみ投与速度で「一部投与」按分。TPN/PPN/食事はper-product mlがそのまま日量。
      final factor =
          (categoryKey == 'EN' && rate > 0 && fullIN > 0) ? (rate * 24) / fullIN : 1.0;

      totalVolumeMl += fullIN * factor;
      totalKcal += fullKcal * factor;
      totalProteinG += fullProt * factor;
      totalFatG += fullFatG * factor;
      fatKcal += fullFatG * 9 * factor;
      carbKcal += fullCarbG * 4 * factor;
      proteinKcal += fullProt * 4 * factor;
    }

    // TPN/PPNはper-product ml指定(本数+部分ml)がそのまま日量。流量は表示用。
    processCategory('EN', _enRateMlPerHour);
    processCategory('TPN', 0);
    processCategory('PPN', 0);
    // 食事(濃厚流動食・栄養サポート食品)を本数ベースで合算 (rate=0 → 全量)
    processCategory('濃厚流動食', 0);
    processCategory('栄養サポート食品', 0);

    // 加注製剤(電解質/微量元素/ビタミン)を合算（個別選択は_selectAdditives）
    for (final name in _selectAdditives) {
      final p = widget.state.catalog.byName(name);
      if (p == null) continue;
      final prot = p.aminoAcidG ?? 0;
      final fat = p.fatBase ?? 0;
      final carb = p.carbBase ?? 0;
      totalVolumeMl += p.volumeMl ?? 0;
      totalKcal += p.kcal ?? 0;
      totalProteinG += prot;
      totalFatG += fat;
      fatKcal += fat * 9;
      carbKcal += carb * 4;
      proteinKcal += prot * 4;
    }

    return AggregateResult(
      totalVolumeMl: totalVolumeMl,
      totalKcal: totalKcal,
      totalProteinG: totalProteinG,
      totalFatG: totalFatG,
      fatKcal: fatKcal,
      carbKcal: carbKcal,
      proteinKcal: proteinKcal,
    );
  }

  AggregateResult _aggregateFromVolumes(
      List<Product?> products, List<double> volumesMl) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;

    for (var i = 0; i < products.length; i++) {
      final product = products[i];
      final volume = volumesMl[i];
      if (product == null || volume <= 0) continue;
      final density =
          (product.volumeMl ?? 1) == 0 ? 0 : volume / (product.volumeMl ?? 1);
      final kcal = (product.kcal ?? 0) * density;
      final protein = (product.aminoAcidG ?? 0) * density;
      final fat = (product.fatBase ?? 0) * density;
      final carb = (product.carbBase ?? 0) * density;
      totalVolumeMl += volume;
      totalKcal += kcal;
      totalProteinG += protein;
      totalFatG += fat;
      fatKcal += fat * 9;
      carbKcal += carb * 4;
      proteinKcal += protein * 4;
    }

    return AggregateResult(
      totalVolumeMl: totalVolumeMl,
      totalKcal: totalKcal,
      totalProteinG: totalProteinG,
      totalFatG: totalFatG,
      fatKcal: fatKcal,
      carbKcal: carbKcal,
      proteinKcal: proteinKcal,
    );
  }

  // 加注製剤(電解質/微量元素/ビタミン)を複数追加するピッカー。
  // カテゴリ見出し付きの1リストを最初から展開表示し、各行のステッパーで選ぶ。
  // target は ゼロmenu(_zeroAdditives) / 個別選択(_selectAdditives) を切替えて渡す。
  Widget _additivePicker(List<String> target) {
    const cats = [
      ('電解質', '電解質補正'),
      ('微量元素', '微量元素製剤'),
      ('ビタミン', 'ビタミン製剤'),
    ];
    int countOf(String name) => target.where((x) => x == name).length;

    Widget header(String label) => Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          color: Colors.blueGrey.shade50,
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade600)),
        );

    Widget prodRow(Product p) {
      final cnt = countOf(p.name);
      final vol = p.volumeMl != null ? '${p.volumeMl!.round()}ml' : '';
      final sub = [if (p.content.isNotEmpty) p.content, if (vol.isNotEmpty) vol]
          .join(' / ');
      return Container(
        color: cnt > 0 ? Colors.blue.shade50 : null,
        padding: const EdgeInsets.only(left: 6),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (sub.isNotEmpty)
                  Text(sub,
                      style:
                          TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            color: Colors.red.shade400,
            onPressed:
                cnt > 0 ? () => setState(() => target.remove(p.name)) : null,
          ),
          SizedBox(
              width: 18,
              child: Text('$cnt',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: cnt > 0 ? Colors.blue.shade700 : Colors.grey))),
          IconButton(
            icon: const Icon(Icons.add_circle, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            visualDensity: VisualDensity.compact,
            color: Colors.blue.shade600,
            onPressed: () => setState(() => target.add(p.name)),
          ),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (cat, label) in cats) ...[
          header(label),
          ...sortProductsForDisplay(widget.state.catalog.byCategory(cat),
                  additiveCat: cat)
              .map(prodRow),
        ],
      ],
    );
  }

  /// 病態タグに応じた処方サジェスト(💡)。タグ0個なら非表示。
  /// 蛋白の目安cap超過時は控えめなテキスト1行を添える(色強調・ダイアログなし)。
  Widget _conditionSuggestionBanner(
      PatientCase current, AggregateResult aggregate) {
    final defs = current.conditionTags
        .map(ConditionCatalog.byId)
        .whereType<ConditionDef>()
        .toList();
    if (defs.isEmpty) return const SizedBox.shrink();

    final w = current.weightKg;
    final protPerKg = w > 0 ? aggregate.totalProteinG / w : 0.0;
    // cap を持つタグのうち、現処方が超過しているもの
    final overs = defs
        .where((d) =>
            d.proteinCapPerKg != null && protPerKg > d.proteinCapPerKg! + 1e-9)
        .toList();

    final textColor = Colors.brown.shade700;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in defs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('💡 ${d.label}: ${d.suggestion}',
                  style: TextStyle(fontSize: 12, color: textColor)),
            ),
          if (overs.isNotEmpty)
            Text(
              '現在 ${protPerKg.toStringAsFixed(1)} g/kg'
              '（${overs.map((d) => '${d.label} 目安${d.proteinCapPerKg!.toStringAsFixed(1)}').join(' / ')} 超）',
              style: TextStyle(
                  fontSize: 12,
                  color: textColor,
                  fontWeight: FontWeight.w600),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.state.selectedCase;
    if (current == null) {
      return const Center(child: Text('先に症例を作成してください'));
    }

    final targetKcal = NutritionCalculator.targetEnergy(current);
    final targetProtein = NutritionCalculator.targetProtein(current);
    final protocol = widget.state.protocols
        .firstWhere((e) => e.id == current.selectedProtocolId);
    final zeroMenu = NutritionCalculator.zeroMenuSuggestion(
      targetKcal: double.tryParse(targetKcalController.text) ?? targetKcal,
      npcNRatio: double.tryParse(npcnController.text) ?? 125,
      lipidGramPerKg: _lipidGPerKg,
      weightKg: current.weightKg,
      glucoseProduct: widget.state.adoptedByBase(glucoseSource),
      aminoProduct: widget.state.adoptedAminoForZero(),
      lipidProduct: widget.state.adoptedLipidForZero(),
    );
    // 製剤構成と一致させる: 本体は10ml単位に丸め、加注製剤も合算してサマリーへ反映
    double _round10(double v) => (v / 10).round() * 10.0;
    final scratchAggregate = _aggregateFromVolumes(
      [
        widget.state.adoptedAminoForZero(),
        widget.state.adoptedLipidForZero(),
        widget.state.adoptedByBase(glucoseSource),
        ..._zeroAdditives.map((n) => widget.state.catalog.byName(n)),
      ],
      [
        _round10(zeroMenu.aminoVolumeMl),
        _round10(zeroMenu.lipidVolumeMl),
        _round10(zeroMenu.glucoseVolumeMl),
        ..._zeroAdditives
            .map((n) => widget.state.catalog.byName(n)?.volumeMl ?? 0),
      ],
    );
    final actualAggregate = _aggregateWithRates(current);

    final productUnits = <String, int>{};
    for (final item in current.regimenItems) {
      if (item.units > 0) {
        productUnits[item.productId] =
            (productUnits[item.productId] ?? 0) + item.units;
      }
    }

    // ENタブ選択時は、EN本体とEN補助(EN_AUX)を両方取得してグループ表示
    final products = category == 'EN'
        ? [
            ...widget.state.catalog
                .byCategory('EN')
                .where((p) => widget.state.isAdopted(p.id)),
            ...widget.state.catalog
                .byCategory('EN_AUX')
                .where((p) => widget.state.isAdopted(p.id)),
          ]
        : category == '食事'
            ? widget.state.catalog.products
                .where((p) => p.isFood && widget.state.isAdopted(p.id))
                .toList()
            : widget.state.catalog
                .byCategory(category)
                .where((p) => widget.state.isAdopted(p.id))
                .toList();
    // 朝 > 昼 > 夕 > ★ > 未選択
    products.sort((a, b) {
      int groupOf(Product p) {
        final item = current.regimenItems
            .where((e) => e.productId == p.id)
            .firstOrNull;
        if (item != null && item.hasMealTiming) {
          if (item.morning > 0) return 0;
          if (item.noon > 0) return 1;
          if (item.evening > 0) return 2;
        }
        if ((productUnits[p.id] ?? 0) >= 1) return 3;
        if (widget.state.isEffectiveFavorite(p.id)) return 4;
        return 5;
      }
      return groupOf(a).compareTo(groupOf(b));
    });

    // メイン製剤 = EN_AUX以外（ENタブならEN本体のみ）
    final mainProducts = products.where((p) => p.category != 'EN_AUX').toList();
    // EN補助製剤はENタブのときだけ表示
    final helperProducts = category == 'EN'
        ? products.where((p) => p.category == 'EN_AUX').toList()
        : <Product>[];

    final isScratchMode = _builderTabIndex == 1;
    final aggregate = isScratchMode ? scratchAggregate : actualAggregate;
    final aminoProduct = widget.state.adoptedAminoForZero();
    final glucoseProduct = widget.state.adoptedByBase(glucoseSource);
    final lipidProduct = widget.state.adoptedLipidForZero();
    final scratchTotalVolumeMl = scratchAggregate.totalVolumeMl;
    final scratchInfusionRateMlPerHour = scratchTotalVolumeMl / 24;
    String formatRequiredUnits(Product? product, double requiredMl) {
      if (product == null ||
          product.volumeMl == null ||
          product.volumeMl! <= 0) {
        return '未設定';
      }
      return '${(requiredMl / product.volumeMl!).ceil()} 本';
    }

    // 製剤構成と一致(10ml丸め)
    final scratchAminoUnits =
        formatRequiredUnits(aminoProduct, _round10(zeroMenu.aminoVolumeMl));
    final scratchGlucoseUnits =
        formatRequiredUnits(glucoseProduct, _round10(zeroMenu.glucoseVolumeMl));
    final scratchLipidUnits =
        formatRequiredUnits(lipidProduct, _round10(zeroMenu.lipidVolumeMl));
    // 加注製剤の処方表示 (名称 + 合計量, 同一製剤は×本数で集約)
    final scratchAdditiveLines = (() {
      final m = <String, int>{};
      for (final n in (isScratchMode ? _zeroAdditives : _selectAdditives)) {
        m[n] = (m[n] ?? 0) + 1;
      }
      return m.entries.map((e) {
        final vol = widget.state.catalog.byName(e.key)?.volumeMl;
        final amt = vol != null ? '${(vol * e.value).round()} ml' : '${e.value}管';
        final nm = e.value > 1 ? '${e.key} ×${e.value}' : e.key;
        return '$nm  $amt';
      }).toList();
    })();


    final screenH = MediaQuery.of(context).size.height;
    final _mqPad = MediaQuery.of(context).padding;
    // パネルの最大高さ = 画面高さ - ステータスバー - AppBar - ホームインジケータ - パディング16
    final maxSummaryH = (screenH - _mqPad.top - kToolbarHeight - _mqPad.bottom - 16.0)
        .clamp(200.0, screenH);

    // 入室日・栄養開始日 (ヘッダー表示用)
    String _mmdd(DateTime? d) => d == null ? '—' : '${d.month}/${d.day}';
    final _admissionDate = (() {
      final e =
          current.bedHistory.where((b) => b.fromBed == null).firstOrNull;
      return e != null ? DateTime.tryParse(e.changedAt) : null;
    })();
    final _nutritionStart = (() {
      final s = current.autoDesignConfig?['startDate'] as String?;
      return (s != null ? DateTime.tryParse(s) : null) ?? _admissionDate;
    })();
    final _fastingDate = current.fastingDate != null
        ? DateTime.tryParse(current.fastingDate!)
        : null;

    return Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('処方ビルダー'),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _listScroll,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _builderCardCollapsed
                            ? null
                            : () => _editPatientParams(context, current),
                        child: Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: _builderCardCollapsed ? 2 : 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (!_builderCardCollapsed) ...[
                                  const Icon(Icons.person, size: 18),
                                  const SizedBox(width: 2),
                                  Text(current.caseCode,
                                      style:
                                          Theme.of(context).textTheme.titleLarge),
                                  const SizedBox(width: 12),
                                  const Icon(Icons.bed, size: 18),
                                  const SizedBox(width: 2),
                                  Text(current.currentBed,
                                      style:
                                          Theme.of(context).textTheme.titleLarge),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    tooltip: '患者情報を編集',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _editPatientParams(context, current),
                                  ),
                                ] else
                                  const Spacer(),
                                if (current.conditionTags.isNotEmpty)
                                  IconButton(
                                    icon: Icon(Icons.lightbulb,
                                        size: 20, color: Colors.amber.shade700),
                                    tooltip: '病態サジェスト',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => showDialog(
                                      context: context,
                                      builder: (_) => Dialog(
                                        backgroundColor: Colors.transparent,
                                        elevation: 0,
                                        insetPadding: const EdgeInsets.symmetric(
                                            horizontal: 24, vertical: 80),
                                        child: GestureDetector(
                                          onTap: () => Navigator.pop(context),
                                          child: SingleChildScrollView(
                                            child: _conditionSuggestionBanner(
                                                current, aggregate),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  icon: Icon(
                                      _builderCardCollapsed
                                          ? Icons.expand_more
                                          : Icons.expand_less,
                                      size: 22),
                                  tooltip: _builderCardCollapsed
                                      ? '患者情報を展開'
                                      : '折りたたむ',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => setState(() =>
                                      _builderCardCollapsed =
                                          !_builderCardCollapsed),
                                ),
                              ],
                            ),
                            if (!_builderCardCollapsed) ...[
                            const SizedBox(height: 4),
                            // 入室日 / 絶食開始日 / 栄養開始日
                            Text(
                              '入室日 ${_mmdd(_admissionDate)}, '
                              '絶食開始日 ${_mmdd(_fastingDate)}, '
                              '栄養開始日 ${_mmdd(_nutritionStart)}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current.patientInfoLine,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current.energyModel == 'kcalPerKg'
                                  ? '${(current.kcalPerKgValue ?? 25).toStringAsFixed(0)} kcal/kg, '
                                      'タンパク目標 ${current.proteinGoalPerKg.toStringAsFixed(1)}g/kg'
                                  : '活動係数 ${current.activityFactor.toStringAsFixed(1)}, '
                                      '侵害係数 ${current.stressFactor.toStringAsFixed(1)}, '
                                      'タンパク目標 ${current.proteinGoalPerKg.toStringAsFixed(1)}g/kg',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(
                              'カロリー ${targetKcal.round()} kcal, '
                              'タンパク ${targetProtein.round()} g/day',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Builder(builder: (_) {
                              final er = NutritionCalculator
                                  .targetEnergyResult(current);
                              final showW = (er.feedingWeightKg -
                                          er.actualWeightKg)
                                      .abs() >=
                                  0.1;
                              final bmi = cbw.bmiOf(
                                  current.weightKg, current.heightCm);
                              return Text(
                                '式 ${ce.energyModelFromId(current.energyModel).label}'
                                ' / BMI ${bmi.toStringAsFixed(1)} ${cbw.obesityClass(bmi)}'
                                '${showW ? ' / 栄養計算体重 ${er.feedingWeightKg.toStringAsFixed(1)}kg（実${er.actualWeightKg.toStringAsFixed(0)}/理想${er.idealWeightKg.toStringAsFixed(0)}/補正適用）' : ''}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.blueGrey),
                              );
                            }),
                            // 過剰栄養アラート (H-B×係数 + 高SF + >30kcal/kg)
                            Builder(
                                builder: (_) =>
                                    _energyOverfeedAlert(current) ??
                                    const SizedBox.shrink()),
                            if (current.memo.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(current.memo,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey)),
                            ],
                            if (current.conditionTags.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  for (final id in current.conditionTags)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.teal.shade50,
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        border: Border.all(
                                            color: Colors.teal.shade200),
                                      ),
                                      child: Text(
                                        ConditionCatalog.labelOf(id),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.teal.shade800),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            ],
                          ],
                        ),
                      ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 3タブ切替 (個別選択 / ゼロmenu / 自動計算)
                    Center(
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment<int>(
                            value: 0,
                            label: Text('個別選択'),
                            icon: Icon(Icons.list_alt),
                          ),
                          ButtonSegment<int>(
                            value: 1,
                            label: Text('ゼロmenu'),
                            icon: Icon(Icons.science),
                          ),
                          ButtonSegment<int>(
                            value: 2,
                            label: Text('自動計算'),
                            icon: Icon(Icons.auto_awesome),
                          ),
                        ],
                        selected: {_builderTabIndex},
                        onSelectionChanged: (Set<int> newSelection) {
                          setState(() => _builderTabIndex = newSelection.first);
                          // 自動計算タブ初回表示時: AutoDesignInline のinitState完了後に
                          // もう一度 setState してグラフパネルを描画する
                          if (newSelection.first == 2) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() {});
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 6),
                    // タブごとの説明書き
                    Text(
                      _builderTabIndex == 0
                          ? '製剤併用を集計し, 処方・カルテ記載に向けてサマライズします.'
                          : _builderTabIndex == 1
                              ? '静脈栄養のみで最小のINにする際の逆引き計算を行います.'
                              : 'フェーズに応じた処方設計を提案し, トレンドを可視化します.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 12),
                    // ゼロmenu タブ
                    Visibility(
                      visible: _builderTabIndex == 1,
                      maintainState: true,
                      child: Builder(builder: (context) {
                        Product? prod(String? n) =>
                            n == null ? null : widget.state.catalog.byName(n);
                        double round10(double v) => (v / 10).round() * 10.0;

                        // 本体(ベース)の使用量を10ml単位に丸め (IN/kcal/PFCはサマリーカードで集計)
                        final aminoMl = round10(zeroMenu.aminoVolumeMl);
                        final gluMl = round10(zeroMenu.glucoseVolumeMl);
                        final lipMl = round10(zeroMenu.lipidVolumeMl);

                        const rowH = 32.0;
                        Widget dataRow(String label, String val,
                                {bool bold = false, Color? color}) =>
                            SizedBox(
                              height: rowH,
                              child: Row(children: [
                                // 長い加注製剤名は折り返さず、末尾を省略(…)して容量の手前で切る
                                Expanded(
                                    child: Text(label,
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: color,
                                            fontWeight: bold
                                                ? FontWeight.bold
                                                : FontWeight.normal))),
                                const SizedBox(width: 6),
                                Text(val,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: color,
                                        fontWeight: bold
                                            ? FontWeight.bold
                                            : FontWeight.normal)),
                              ]),
                            );

                        // ── 本体タブ: 投与目標設定 ──
                        final bodyCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('投与目標設定',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Divider(),
                                TextField(
                                  controller: targetKcalController,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: '投与カロリー',
                                    suffixText: targetKcalController.text.isNotEmpty
                                        ? 'kcal'
                                        : null,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: npcnController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'タンパク投与量 (NPC/N)',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<double>(
                                  value: _lipidGPerKg,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '脂質量',
                                    suffixText: 'g/kg/day',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 4),
                                  ),
                                  items: [
                                    for (int i = 0; i <= 10; i++)
                                      DropdownMenuItem(
                                        value: i / 10.0,
                                        child: Text((i / 10.0).toStringAsFixed(1)),
                                      ),
                                  ],
                                  onChanged: (v) => setState(
                                      () => _lipidGPerKg = v ?? _lipidGPerKg),
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  value: glucoseSource,
                                  decoration: const InputDecoration(
                                      labelText: '糖質', isDense: true),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'ハイカリックRF',
                                        child: Text('ハイカリックRF')),
                                    DropdownMenuItem(
                                        value: '70% グルコース',
                                        child: Text('70% グルコース')),
                                    DropdownMenuItem(
                                        value: '8%グルコース',
                                        child: Text('8%グルコース')),
                                  ],
                                  onChanged: (v) => setState(
                                      () => glucoseSource = v ?? glucoseSource),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: () {
                                      current.zeroMenuConfig = ZeroMenuConfig(
                                        targetKcal: double.tryParse(
                                                targetKcalController.text) ??
                                            targetKcal,
                                        npcNRatio: double.tryParse(
                                                npcnController.text) ??
                                            125,
                                        lipidGramPerKg: _lipidGPerKg,
                                        glucoseProductName: glucoseSource,
                                      );
                                      widget.state.persist();
                                      setState(() {});
                                    },
                                    child: const Text('保存'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );

                        // ── 加注タブ: 製剤を1リストから選んで追加 ──
                        final addCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('加注製剤 (電解質・微量元素・ビタミン)',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Divider(),
                                _additivePicker(_zeroAdditives),
                              ],
                            ),
                          ),
                        );

                        // ── 製剤構成 (タンパク→脂肪→糖質の順) ──
                        final compCard = Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('製剤構成',
                                    style:
                                        Theme.of(context).textTheme.titleSmall),
                                const Divider(),
                                Text('本体',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600)),
                                dataRow(aminoProduct?.name ?? 'アミノ酸製剤',
                                    '${aminoMl.round()} ml'),
                                dataRow(lipidProduct?.name ?? '脂肪乳剤',
                                    '${lipMl.round()} ml'),
                                dataRow(glucoseSource, '${gluMl.round()} ml'),
                                if (_zeroAdditives.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text('加注',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600)),
                                  ..._zeroAdditives.map((n) => dataRow(n,
                                      prod(n)?.volumeMl != null
                                          ? '${prod(n)!.volumeMl!.round()} ml'
                                          : '1管')),
                                ],
                                Builder(builder: (_) {
                                  final gluProd =
                                      widget.state.adoptedByBase(glucoseSource);
                                  final gluKcal = (gluProd != null &&
                                          (gluProd.volumeMl ?? 0) > 0)
                                      ? gluMl *
                                          (gluProd.kcal ?? 0) /
                                          gluProd.volumeMl!
                                      : 0.0;
                                  return _infusionAlerts(
                                    glucoseGramPerDay: gluKcal / 4,
                                    lipidGramPerDay: zeroMenu.lipidGram,
                                    weightKg: current.weightKg,
                                    glucoseRestrict: cc
                                            .resolveCoeff(current.conditionTags)
                                            ?.glucoseRestrict ??
                                        false,
                                  );
                                }),
                              ],
                            ),
                          ),
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // サブタブ: 本体 / 加注 (中央寄せ)
                            Center(
                              child: SegmentedButton<int>(
                                segments: const [
                                  ButtonSegment(value: 0, label: Text('本体')),
                                  ButtonSegment(value: 1, label: Text('加注')),
                                ],
                                selected: {_zeroSubTab},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) =>
                                    setState(() => _zeroSubTab = s.first),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                    child: _zeroSubTab == 0 ? bodyCard : addCard),
                                const SizedBox(width: 8),
                                Expanded(child: compCard),
                              ],
                            ),
                          ],
                        );
                      }),
                    ),
                    // タブ内容: EN/TPN/PPN 選択 (インデックス 0)
                    Visibility(
                      visible: _builderTabIndex == 0,
                      maintainState: true,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('処方ビルダー',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Builder(builder: (context) {
                                final activeCategories = ['EN', 'TPN', 'PPN']
                                    .where((cat) =>
                                        _selectedProductsForCategory(cat)
                                            .isNotEmpty)
                                    .toList();
                                if (activeCategories.isEmpty) {
                                  return const Text('採用製剤を製剤マスタで選択してください');
                                }
                                // 加注・食事タブは常時選択可。EN/TPN/PPNは採用製剤がある時のみ
                                final tabCats = [...activeCategories, '加注', '食事'];
                                final effectiveCategory =
                                    tabCats.contains(category)
                                        ? category
                                        : activeCategories.first;
                                if (effectiveCategory != category) {
                                  WidgetsBinding.instance.addPostFrameCallback(
                                      (_) => setState(
                                          () => category = effectiveCategory));
                                }
                                // EN/TPN/PPN タブ + ドロップダウン（選択中カテゴリに対応）
                                // TPN/PPN流量オプション: 24hかけて(0) + 5〜60ml/h(5刻み)
                                final pnRateOptions = <double>[0,
                                  ...List.generate(12, (i) => (i + 1) * 5.0)];
                                String pnRateLabel(double v) =>
                                    v <= 0 ? '24hかけて' : '${v.toInt()}ml/h';
                                final curPnRate = effectiveCategory == 'TPN'
                                    ? _tpnRateMlPerHour
                                    : _ppnRateMlPerHour;
                                // スイッチを画面中央、DDをスイッチ右端〜右壁の中間に配置
                                return Row(
                                  children: [
                                    const Expanded(child: SizedBox()), // 左スペーサー
                                    SizedBox(
                                      width: 60.0 * tabCats.length,
                                      child: SegmentedButton<String>(
                                        showSelectedIcon: false,
                                        style: ButtonStyle(
                                          visualDensity: VisualDensity.compact,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        segments: tabCats
                                            .map((cat) => ButtonSegment(
                                                value: cat, label: Text(cat)))
                                            .toList(),
                                        selected: {effectiveCategory},
                                        onSelectionChanged: (newSel) =>
                                            setState(() => category = newSel.first),
                                      ),
                                    ),
                                    // 右半分: DDをスイッチ右端〜右壁の中間に配置
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 12),
                                          child: (effectiveCategory == '加注' ||
                                                  effectiveCategory == '食事')
                                            ? const SizedBox.shrink()
                                            : effectiveCategory == 'EN'
                                            ? DropdownButton<double>(
                                              value: _enRateMlPerHour,
                                              isDense: true,
                                              items: _infusionRateOptions
                                                  .map((v) => DropdownMenuItem(
                                                      value: v,
                                                      child: Text(_rateLabel(v),
                                                          style: const TextStyle(fontSize: 13))))
                                                  .toList(),
                                              onChanged: (v) async {
                                                setState(() => _enRateMlPerHour = v ?? 0);
                                                if ((v ?? 0) > 0) {
                                                  await _adjustEnUnitsForRate(current);
                                                  if (mounted) setState(() {});
                                                }
                                              },
                                            )
                                            : DropdownButton<double>(
                                              value: curPnRate,
                                              isDense: true,
                                              items: pnRateOptions
                                                  .map((v) => DropdownMenuItem(
                                                      value: v,
                                                      child: Text(pnRateLabel(v),
                                                          style: const TextStyle(fontSize: 13))))
                                                  .toList(),
                                              onChanged: (v) {
                                                final rate = v ?? 0;
                                                setState(() {
                                                  if (effectiveCategory == 'TPN') {
                                                    _tpnRateMlPerHour = rate;
                                                  } else {
                                                    _ppnRateMlPerHour = rate;
                                                  }
                                                });
                                              },
                                            ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }),
                              if (category == '加注') ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: () => setState(() {
                                      _selectAdditives
                                        ..clear()
                                        ..addAll(
                                            _recommendedSelectAdditives(current));
                                    }),
                                    icon: Icon(Icons.auto_fix_high,
                                        size: 16, color: Colors.indigo.shade600),
                                    label: const Text('推奨加注を自動セット（重複回避）',
                                        style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact),
                                  ),
                                ),
                                Text(
                                    'ベースに微量元素/ビタミンが内蔵なら加注せず、胆汁うっ滞/肝障害ではMn-freeを選択。',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: Colors.grey.shade600)),
                                const SizedBox(height: 6),
                                _additivePicker(_selectAdditives),
                              ],
                              if (category == '食事') ...[
                                const SizedBox(height: 4),
                                Text('経口/経腸の食事製剤（濃厚流動食・栄養サポート食品）。本数を指定',
                                    style: Theme.of(context).textTheme.bodySmall),
                                if (mainProducts.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                        '採用された食事製剤がありません（製剤マスタの「食事」タブで採用してください）',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(color: Colors.grey)),
                                  ),
                              ],
                              if (category != '加注' && category != '食事') ...[
                                const SizedBox(height: 4),
                                Text('ENは8h毎, TPN/PPNは24h毎に交換',
                                    style: Theme.of(context).textTheme.bodySmall),
                              ],
                              const SizedBox(height: 8),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 380),
                                transitionBuilder: (child, anim) {
                                  final slide = Tween(
                                    begin: const Offset(0, -0.12),
                                    end: Offset.zero,
                                  ).animate(CurvedAnimation(parent: anim, curve: Curves.easeInOutSine));
                                  return SlideTransition(
                                    position: slide,
                                    child: FadeTransition(opacity: anim, child: child),
                                  );
                                },
                                child: Column(
                                  key: ValueKey(products.map((p) => p.id).join(',')),
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                              ...mainProducts.map((product) {
                                final existing = current.regimenItems
                                    .where((e) => e.productId == product.id)
                                    .firstOrNull;
                                final units = existing?.units ?? 0;
                                final partialMl = existing?.partialMl ?? 0;
                                final isFavorite =
                                    widget.state.isFavorite(product.id);
                                final isAutoFav = widget.state
                                    .isAutoFavorite(product.id, current);
                                final classification = product.productType;
                                final attributes =
                                    product.content.trim().isNotEmpty
                                        ? product.content
                                        : '性状不明';
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ListTile(
                                      isThreeLine: true,
                                      contentPadding: EdgeInsets.zero,
                                      leading: IconButton(
                                        tooltip: isAutoFav
                                            ? '病態タグにより自動 (タップで固定)'
                                            : null,
                                        onPressed: () async {
                                          await widget.state
                                              .toggleFavorite(product.id);
                                          setState(() {});
                                        },
                                        icon: Icon(
                                            (isFavorite || isAutoFav)
                                                ? Icons.star
                                                : Icons.star_border,
                                            color: isFavorite
                                                ? Colors.orange
                                                : isAutoFav
                                                    ? Colors.teal
                                                    : null),
                                      ),
                                      title: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(product.name),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$classification / $attributes',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(
                                          '${product.volumeMlString} / ${product.kcalString} / ${product.aminoString}'),
                                      tileColor: (units >= 1 || partialMl > 0)
                                          ? Colors.blue.shade100
                                          : null,
                                      trailing: (product.category == 'EN' || product.category == 'EN_AUX')
                                          ? _MealPicker(
                                              morning: existing?.morning ?? 0,
                                              noon: existing?.noon ?? 0,
                                              evening: existing?.evening ?? 0,
                                              onChanged: (m, n, e) async {
                                                await widget.state.setMealUnits(current.id, product, m, n, e);
                                                setState(() {});
                                              },
                                            )
                                          : SizedBox(
                                              width: ((product.category == 'TPN' ||
                                                          product.category == 'PPN') &&
                                                      (product.volumeMl ?? 0) > 100)
                                                  ? 196
                                                  : 120,
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  // 部分量(100ml単位): 本数指定の左に配置
                                                  if ((product.category == 'TPN' ||
                                                          product.category == 'PPN') &&
                                                      (product.volumeMl ?? 0) > 100)
                                                    Builder(builder: (_) {
                                                      final bagVol =
                                                          (product.volumeMl ?? 0).round();
                                                      final maxPartial = bagVol > 100
                                                          ? ((bagVol - 1) ~/ 100) * 100
                                                          : 0;
                                                      final opts = <int>[
                                                        0,
                                                        for (int v = 100; v <= maxPartial; v += 100) v
                                                      ];
                                                      final cur =
                                                          partialMl.clamp(0, maxPartial);
                                                      return DropdownButton<int>(
                                                        value: cur,
                                                        isDense: true,
                                                        underline: const SizedBox.shrink(),
                                                        items: opts
                                                            .map((v) => DropdownMenuItem(
                                                                value: v,
                                                                child: Text(
                                                                    v == 0 ? '+0' : '+${v}ml',
                                                                    style: const TextStyle(
                                                                        fontSize: 13))))
                                                            .toList(),
                                                        onChanged: (v) async {
                                                          await widget.state.setPartialMl(
                                                              current.id, product, v ?? 0);
                                                          setState(() {});
                                                        },
                                                      );
                                                    }),
                                                  IconButton(
                                                    visualDensity: VisualDensity.compact,
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                        minWidth: 32, minHeight: 32),
                                                    onPressed: () async {
                                                      await widget.state.setUnits(current.id, product, (units - 1).clamp(0, 99));
                                                      setState(() {});
                                                    },
                                                    icon: const Icon(Icons.remove_circle_outline),
                                                  ),
                                                  Text('$units', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                                  IconButton(
                                                    visualDensity: VisualDensity.compact,
                                                    padding: EdgeInsets.zero,
                                                    constraints: const BoxConstraints(
                                                        minWidth: 32, minHeight: 32),
                                                    onPressed: () async {
                                                      await widget.state.setUnits(current.id, product, units + 1);
                                                      setState(() {});
                                                    },
                                                    icon: const Icon(Icons.add_circle_outline),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      onTap: () => setState(() {
                                        if (expandedProducts.contains(product.id))
                                          expandedProducts.remove(product.id);
                                        else
                                          expandedProducts.add(product.id);
                                      }),
                                    ),
                                    if (expandedProducts.contains(product.id) &&
                                        product.notes?.trim().isNotEmpty ==
                                            true)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            left: 56.0,
                                            right: 8.0,
                                            bottom: 8.0),
                                        child: Text(product.notes!),
                                      ),
                                  ],
                                );
                              }),
                              if (helperProducts.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Text('EN補助製剤',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 8),
                                ...helperProducts.map((product) {
                                  final existing = current.regimenItems
                                      .where((e) => e.productId == product.id)
                                      .firstOrNull;
                                  final units = existing?.units ?? 0;
                                  final isFavorite =
                                      widget.state.isFavorite(product.id);
                                  final isAutoFav = widget.state
                                      .isAutoFavorite(product.id, current);
                                  final classification = product.productType;
                                  final attributes =
                                      product.content.trim().isNotEmpty
                                          ? product.content
                                          : '性状不明';
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ListTile(
                                        isThreeLine: true,
                                        contentPadding: EdgeInsets.zero,
                                        leading: IconButton(
                                          tooltip: isAutoFav
                                              ? '病態タグにより自動 (タップで固定)'
                                              : null,
                                          onPressed: () async {
                                            await widget.state
                                                .toggleFavorite(product.id);
                                            setState(() {});
                                          },
                                          icon: Icon(
                                              (isFavorite || isAutoFav)
                                                  ? Icons.star
                                                  : Icons.star_border,
                                              color: isFavorite
                                                  ? Colors.orange
                                                  : isAutoFav
                                                      ? Colors.teal
                                                      : null),
                                        ),
                                        title: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(product.name),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$classification / $attributes',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                          ],
                                        ),
                                        subtitle: Text(
                                            '${product.volumeMlString} / ${product.kcalString} / ${product.aminoString}'),
                                        tileColor: units >= 1
                                            ? Colors.blue.shade100
                                            : null,
                                        trailing: _MealPicker(
                                          morning: existing?.morning ?? 0,
                                          noon: existing?.noon ?? 0,
                                          evening: existing?.evening ?? 0,
                                          onChanged: (m, n, e) async {
                                            await widget.state.setMealUnits(current.id, product, m, n, e);
                                            setState(() {});
                                          },
                                        ),
                                        onTap: () => setState(() {
                                          if (expandedProducts.contains(product.id))
                                            expandedProducts.remove(product.id);
                                          else
                                            expandedProducts.add(product.id);
                                        }),
                                      ),
                                      if (expandedProducts
                                              .contains(product.id) &&
                                          product.notes?.trim().isNotEmpty ==
                                              true)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                              left: 56.0,
                                              right: 8.0,
                                              bottom: 8.0),
                                          child: Text(product.notes!),
                                        ),
                                    ],
                                  );
                                }),
                              ],
                            ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // タブ内容: 自動計算 (インデックス 2)
                    Visibility(
                      visible: _builderTabIndex == 2,
                      maintainState: true,
                      child: AutoDesignInline(
                          key: _autoDesignKey,
                          state: widget.state,
                          current: current,
                          onSettingsChanged: () { if (mounted) setState(() {}); }),
                    ),
                  ],
                ),
              ),
        // サマリーパネル（個別選択/ゼロmenuのみ。自動計算タブでは非表示）
        if (_builderTabIndex != 2) SafeArea(
            top: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSummaryH),
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.4),
                        width: 0.8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Flexible(
                      fit: FlexFit.loose,
                      child: ClipRect(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text('サマリー',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                  const Spacer(),
                                  IconButton(
                                    icon: Icon(
                                        _summaryCollapsed
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        size: 22),
                                    tooltip:
                                        _summaryCollapsed ? '展開' : '折りたたむ',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => setState(() =>
                                        _summaryCollapsed = !_summaryCollapsed),
                                  ),
                                ]),
                                if (!_summaryCollapsed) const SizedBox(height: 8),
                                // ── 2カード: 処方+サマリー | 円グラフ（画面幅に応じてレスポンシブ）──
                                if (!_summaryCollapsed)
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                  final availW = constraints.maxWidth;
                                  final scale = (availW / 380).clamp(0.72, 1.0);
                                  final chartSize = (150 * scale).roundToDouble();
                                  final labelFs = (12.5 * scale).clamp(10.0, 12.5);
                                  return ConstrainedBox(
                                  constraints: const BoxConstraints(minHeight: 200),
                                  child: IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      // 処方カード
                                      Expanded(
                                        flex: 3,
                                        child: Card(
                                          margin: const EdgeInsets.all(0),
                                          color: Colors.pink.shade50,
                                          child: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.start,
                                              children: [
                                                // ── サマリー数値 ──
                                                Builder(builder: (context) {
                                                  final w = current.weightKg;
                                                  final protPerKg = w > 0 ? aggregate.totalProteinG / w : 0.0;
                                                  final fatPerKg = w > 0 ? aggregate.totalFatG / w : 0.0;
                                                    final ss = TextStyle(fontSize: labelFs);
                                                  return Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text('合計', style: TextStyle(fontSize: labelFs, fontWeight: FontWeight.bold)),
                                                      const SizedBox(height: 2),
                                                      Text('IN ${aggregate.totalVolumeMl.round()}ml, 総カロリー ${aggregate.totalKcal.round()}kcal', style: ss),
                                                      Text('タンパク ${aggregate.totalProteinG.toStringAsFixed(1)}g/day (${protPerKg.toStringAsFixed(1)}g/kg)', style: ss),
                                                      Text('NPC/N比 ${aggregate.npcNText}', style: ss),
                                                      Text('脂質 ${fatPerKg.toStringAsFixed(1)}g/kg/day', style: ss),
                                                    ],
                                                  );
                                                }),
                                                const Divider(height: 14),
                                                Text('処方', style: TextStyle(fontSize: labelFs, fontWeight: FontWeight.bold)),
                                                const SizedBox(height: 6),
                                                if (isScratchMode) ...[
                                                  Text('${scratchInfusionRateMlPerHour.round()} ml/h', style: const TextStyle(fontSize: 12.5)),
                                                  const SizedBox(height: 4),
                                                  if (zeroMenu.aminoVolumeMl > 0 && aminoProduct != null)
                                                    Text('${aminoProduct.name}  $scratchAminoUnits', style: const TextStyle(fontSize: 12.5)),
                                                  if (zeroMenu.lipidVolumeMl > 0 && lipidProduct != null)
                                                    Text('${lipidProduct.name}  $scratchLipidUnits', style: const TextStyle(fontSize: 12.5)),
                                                  if (zeroMenu.glucoseVolumeMl > 0 && glucoseProduct != null)
                                                    Text('${glucoseProduct.name}  $scratchGlucoseUnits', style: const TextStyle(fontSize: 12.5)),
                                                  // 加注製剤
                                                  for (final l in scratchAdditiveLines)
                                                    Text(l, style: const TextStyle(fontSize: 12.5)),
                                                ] else ...[
                                                  Builder(builder: (c) {
                                                    final ts = TextStyle(fontSize: labelFs);
                                                    final tpnItems = current.regimenItems.where((i) {
                                                      final p = widget.state.catalog.byId(i.productId);
                                                      return p != null && p.category == 'TPN' && (i.units > 0 || i.partialMl > 0);
                                                    }).toList();
                                                    final ppnItems = current.regimenItems.where((i) {
                                                      final p = widget.state.catalog.byId(i.productId);
                                                      return p != null && p.category == 'PPN' && (i.units > 0 || i.partialMl > 0);
                                                    }).toList();
                                                    String pnAmt(RegimenItem i) {
                                                      if (i.units > 0 && i.partialMl > 0) return '${i.units}本+${i.partialMl}ml';
                                                      if (i.units > 0) return '${i.units}本';
                                                      return '${i.partialMl}ml';
                                                    }
                                                    // EN朝昼夕 (meal timingが設定されているもののみ)
                                                    final enItems = current.regimenItems.where((item) {
                                                      final p = widget.state.catalog.byId(item.productId);
                                                      return p != null && (p.category == 'EN' || p.category == 'EN_AUX') && item.hasMealTiming;
                                                    }).toList();
                                                    // 食事(濃厚流動食・栄養サポート食品): 本数指定のもの
                                                    final foodItems = current.regimenItems.where((item) {
                                                      final p = widget.state.catalog.byId(item.productId);
                                                      return p != null && p.isFood && item.units > 0;
                                                    }).toList();
                                                    Widget mealRow(String label, int Function(RegimenItem) getter) {
                                                      final items = enItems.where((i) => getter(i) > 0).toList();
                                                      if (items.isEmpty) return const SizedBox.shrink();
                                                      final desc = items.map((i) {
                                                        final p = widget.state.catalog.byId(i.productId)!;
                                                        return '${p.name} ${getter(i)}pac';
                                                      }).join(' / ');
                                                      return Padding(
                                                        padding: const EdgeInsets.only(bottom: 2),
                                                        child: Text('$label  $desc', style: ts),
                                                      );
                                                    }
                                                    final hasAny = enItems.isNotEmpty || tpnItems.isNotEmpty || ppnItems.isNotEmpty || foodItems.isNotEmpty || (isScratchMode ? _zeroAdditives : _selectAdditives).isNotEmpty;
                                                    if (!hasAny) return const Text('(未選択)', style: TextStyle(fontSize: 12.5, color: Colors.grey));
                                                    return Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        if (enItems.isNotEmpty) ...[
                                                          mealRow('朝', (i) => i.morning),
                                                          mealRow('昼', (i) => i.noon),
                                                          mealRow('夕', (i) => i.evening),
                                                        ],
                                                        ...tpnItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final volMl = (p.volumeMl ?? 0) * i.units + i.partialMl;
                                                          final rateMlH = (_tpnRateMlPerHour > 0 ? _tpnRateMlPerHour : volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('TPN  ${p.name} ${pnAmt(i)}  ${rateMlH}ml/h', style: ts));
                                                        }),
                                                        ...ppnItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final volMl = (p.volumeMl ?? 0) * i.units + i.partialMl;
                                                          final rateMlH = (_ppnRateMlPerHour > 0 ? _ppnRateMlPerHour : volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('PPN  ${p.name} ${pnAmt(i)}  ${rateMlH}ml/h', style: ts));
                                                        }),
                                                        ...foodItems.map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('食事  ${p.name} ${i.units}本', style: ts));
                                                        }),
                                                        ...scratchAdditiveLines.map((l) => Padding(
                                                            padding: const EdgeInsets.only(bottom: 2),
                                                            child: Text('加注  $l', style: ts))),
                                                      ],
                                                    );
                                                  }),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // 円グラフ + 凡例 + 縦棒%nut カード
                                      Expanded(
                                        flex: 2,
                                        child: Card(
                                          margin: const EdgeInsets.all(0),
                                          color: Colors.blue.shade50,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                                            child: Column(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                // ドーナツグラフ: カードの縦中央に配置するため Expanded で空間を埋める
                                                Expanded(
                                                  child: Center(
                                                  child: SizedBox(
                                                  width: chartSize,
                                                  height: chartSize,
                                                  child: Stack(
                                                    alignment: Alignment.center,
                                                    children: [
                                                      PieChart(
                                                        PieChartData(
                                                          startDegreeOffset: 270,
                                                          sectionsSpace: 2,
                                                          centerSpaceRadius: (28 * scale).clamp(18, 28),
                                                          sections: [
                                                            PieChartSectionData(
                                                              value: aggregate.proteinPercent <= 0 ? 0 : aggregate.proteinKcal,
                                                              color: Colors.blue,
                                                              title: aggregate.proteinPercent < 5 ? '' : '${aggregate.proteinPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                            PieChartSectionData(
                                                              value: aggregate.fatPercent <= 0 ? 0 : aggregate.fatKcal,
                                                              color: Colors.orange,
                                                              title: aggregate.fatPercent < 5 ? '' : '${aggregate.fatPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                            PieChartSectionData(
                                                              value: aggregate.carbPercent <= 0 ? 0 : aggregate.carbKcal,
                                                              color: Colors.yellow.shade700,
                                                              title: aggregate.carbPercent < 5 ? '' : '${aggregate.carbPercent.toStringAsFixed(0)}%',
                                                              titleStyle: TextStyle(fontSize: (12 * scale).clamp(9.0, 12.0), color: Colors.black, fontWeight: FontWeight.bold),
                                                              titlePositionPercentageOffset: 0.47,
                                                              radius: (52 * scale).clamp(34, 52),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      // 中央: 目標達成率
                                                      Center(
                                                        child: Text(
                                                          '${aggregate.targetPercent(targetKcal).toStringAsFixed(0)}%',
                                                          style: TextStyle(
                                                              fontSize: (16 * scale).clamp(12.0, 16.0),
                                                              fontWeight: FontWeight.bold),
                                                        ),
                                                      ),
                                                    ],
                                                  ),   // Stack
                                                  ),   // SizedBox
                                                  ),   // Center
                                                ),     // Expanded
                                                // PFC凡例（ドーナツ下端から10px）
                                                const SizedBox(height: 10),
                                                Row(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    _PfcLegendItem(color: Colors.blue, label: 'P'),
                                                    const SizedBox(width: 12),
                                                    _PfcLegendItem(color: Colors.orange, label: 'F'),
                                                    const SizedBox(width: 12),
                                                    _PfcLegendItem(color: Colors.yellow.shade700, label: 'C'),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),   // Row
                                  ),   // IntrinsicHeight
                                  );   // ConstrainedBox (return)
                                  }), // LayoutBuilder
                                // ── アラート（サマリー下部・個別/ゼロ共通）──
                                if (!_summaryCollapsed)
                                Builder(builder: (_) {
                                  double gluG;
                                  double lipidG;
                                  cm.MicroTotals micro;
                                  if (isScratchMode) {
                                    final gluProd =
                                        widget.state.adoptedByBase(glucoseSource);
                                    final gluKcal = (gluProd != null &&
                                            (gluProd.volumeMl ?? 0) > 0)
                                        ? zeroMenu.glucoseVolumeMl *
                                            (gluProd.kcal ?? 0) /
                                            gluProd.volumeMl!
                                        : 0.0;
                                    gluG = gluKcal / 4;
                                    lipidG = zeroMenu.lipidGram;
                                    micro = cm.aggregateMicro([
                                      for (final n in _zeroAdditives)
                                        cm.MicroContribution(
                                            widget.state.catalog.byName(n)?.micro,
                                            1),
                                    ]);
                                  } else {
                                    final pm = _parenteralMacros(current);
                                    gluG = pm.glucoseG;
                                    lipidG = pm.lipidG;
                                    micro = _microWithRates(current);
                                  }
                                  final rows = _summaryAlertWidgets(
                                    current: current,
                                    glucoseGramPerDay: gluG,
                                    lipidGramPerDay: lipidG,
                                    micro: micro,
                                  );
                                  if (rows.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          const Icon(
                                              Icons.notifications_active_outlined,
                                              size: 16,
                                              color: Colors.deepOrange),
                                          const SizedBox(width: 4),
                                          const Text('リスク・補充サジェスト',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 13,
                                                  color: Colors.black54)),
                                        ]),
                                        const SizedBox(height: 4),
                                        ...rows,
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
            // 栄養の推移パネル（自動計算タブのみ。サマリーと同じドラッグ仕様）
            if (_builderTabIndex == 2)
              _buildAutoChartPanel(screenH),
          ],
        ),
    );
  }

  Widget _buildAutoChartPanel(double screenH) {
    final _cqPad = MediaQuery.of(context).padding;
    final maxPanel = (screenH - _cqPad.top - kToolbarHeight - _cqPad.bottom - 16.0)
        .clamp(200.0, screenH);
    if (_chartPanelHeight > maxPanel) _chartPanelHeight = maxPanel;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxPanel),
          child: Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withOpacity(0.4),
                  width: 0.8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ClipRect(
                    child: SingleChildScrollView(
                      controller: _chartScroll,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Builder(builder: (ctx) {
                        final chart = _autoDesignKey.currentState
                            ?._buildBarChartsForBuilder();
                        if (chart == null) {
                          // 初回フレームで state が未初期化の場合、次フレームで再描画
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() {});
                          });
                          return const SizedBox.shrink();
                        }
                        return chart;
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  final _autoDesignKey = GlobalKey<_AutoDesignPageState>();

  /// 患者パラメータをまとめて編集するダイアログ
  Future<void> _editPatientParams(
          BuildContext context, PatientCase current) =>
      showPatientEditDialog(context, widget.state, current, onSaved: () {
        if (mounted) setState(() {});
        widget.refresh();
      });

  /// Phase 4-①: 個別パラメータの編集ヘルパー群
  Future<void> _editIntField(
      BuildContext context,
      PatientCase current,
      String label,
      int initial,
      int min,
      int max,
      void Function(int) setter) async {
    final controller = TextEditingController(text: initial.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            hintText: '$min 〜 $max',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final v = int.tryParse(controller.text);
                if (v == null) {
                  Navigator.pop(context);
                  return;
                }
                Navigator.pop(context, v.clamp(min, max));
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    setter(result);
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editDoubleField(
      BuildContext context,
      PatientCase current,
      String label,
      double initial,
      double min,
      double max,
      double step,
      void Function(double) setter) async {
    final controller = TextEditingController(text: initial.toString());
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            hintText: '$min 〜 $max',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final v = double.tryParse(controller.text);
                if (v == null) {
                  Navigator.pop(context);
                  return;
                }
                Navigator.pop(context, v.clamp(min, max));
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    setter(result);
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editDoubleDropdown(
      BuildContext context,
      PatientCase current,
      String label,
      double initial,
      List<double> options,
      void Function(double) setter) async {
    final result = await showDialog<double>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(label),
        children: [
          for (final v in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, v),
              child: Row(
                children: [
                  Icon((v - initial).abs() < 0.001
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(v.toStringAsFixed(1)),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    setter(double.parse(result.toStringAsFixed(2)));
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

  Future<void> _editSex(BuildContext context, PatientCase current) async {
    final result = await showDialog<Sex>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('性別'),
        children: [
          for (final s in Sex.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Row(
                children: [
                  Icon(current.sex == s
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(s == Sex.male ? '男性 (M)' : '女性 (F)'),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    current.sex = result;
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }
}

class _NoteSection {
  final String category;
  final String title;
  final String body;
  final Color color;
  const _NoteSection({
    required this.category,
    required this.title,
    required this.body,
    required this.color,
  });
}

class NotePage extends StatefulWidget {
  const NotePage({super.key, required this.state});
  final AppState state;

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage>
    with SingleTickerProviderStateMixin {
  String _selected = 'すべて表示';
  static const _allLabel = 'すべて表示';
  // 本文パネル(ドラッグで上に展開。処方ビルダーのサマリと同仕様)
  static const double _panelMin = 200.0;
  double _panelHeight = 360.0;
  double _snapFrom = 360.0;
  double _snapToTarget = 360.0;
  late AnimationController _snapCtrl;
  final ScrollController _noteScroll = ScrollController();
  // mutable sections (starts with defaults, supports add/edit)
  late List<_NoteSection> _editableSections;

  static final _sections = <_NoteSection>[
    _NoteSection(
      category: 'つかいかた',
      title: 'つかいかた',
      color: Color(0xFF4A90D9),
      body: '本アプリはICUの栄養処方を「個別計算・逆引き・自動設計」の3方式で支援し、トレンドとリスクを可視化する。\n\n■ TOP画面（ベッド管理）\n・患者カードが一覧表示。カードをタップで患者情報編集、「計算」で処方ビルダーへ、「退室」で退室。右上の「新規入室」から患者登録。\n\n■ 新規入室 / 患者情報編集\n・年齢・身長・体重・性別を入力。\n・エネルギー式を選択(簡易式kcal/kg〔既定〕/Harris-Benedict/Mifflin/間接熱量測定)。簡易式はkcal/kgを選ぶ。\n・目標タンパク(g/kg)、絶食開始日、病態タグ(腎不全・肝不全・胆汁うっ滞・CRRT・高排出消化管・アルコール 等)を設定。\n・肥満(BMI≥30)は自動で補正体重×20–25(ESPEN)。BMI・肥満区分・栄養計算体重はカードに自動表示。\n\n■ 処方ビルダーの3タブ\n①個別選択: EN/TPN/PPN/食事/加注を個別に選び、併用を合計→処方・カルテ記載向けにサマライズ。全ソースのIN・kcal・タンパク・微量栄養素を横断集計。\n②ゼロmenu: 静脈栄養のみで最小INにする逆引き計算。投与kcalとNPC/N比・脂質量を決めると各製剤の必要mlを算出。\n③自動計算: フェーズに応じた処方設計を提案しトレンドを可視化。急性期20→EN導入25→回復30 kcal/kgへ自動で上げる。Refeedingリスクは初期kcalを自動cap。\n\n■ 製剤選択アルゴリズム（病態連動）\n・病態を選ぶと、目標タンパクの推奨範囲、ゼロmenuのNPC/N比・脂質量を自動調整。\n・GIR(糖)>5(糖質制限病態は>4)、脂質>1.0–1.5 g/kg/dayでアラート。自動設計は上限を超えない製剤選定。\n・微量栄養素は全ソース合算し耐容上限超過を警告。胆汁うっ滞/肝障害はMn-free製剤へ切替提案、CRRTはSe/B1補充、高排出消化管はZn補充、糖負荷前のB1未投与はWernicke警告。\n・加注はベース製剤の内蔵成分と重複しないよう自動付替え(オールインワンTPNには加注しない 等)。\n\n■ アイコン・色の意味\n・入室(緑・login) / 絶食開始(赤・no_meals) / 栄養開始(青・water_drop) / 経口リハ導入(食事・restaurant)。\n・日付の丸囲み＝入室からday5の倍数。\n・グラフ棒: 下から PN→EN→食事 の積み上げ。青の折れ線＝IN(水分量)、IN最高点に水平線＋_ml表記。赤線＝アミノ酸(AA)。\n・グラフ下の「リスクと補充サジェスト」をタップで各種アラートを展開。',
    ),
    _NoteSection(
      category: 'EN',
      title: '経腸栄養 (EN)',
      color: Color(0xFF2E7D32),
      body: '・入室48時間以内に開始する. 1週間で目標投与量まで上げる.\n'
          '　ENはBacterial Translocationを抑制するので禁忌以外は第一選択.\n'
          '・カテコラミンは用量依存性に腸管虚血をおこす\n'
          '　ENもまた腸管酸素需要増加による腸管虚血をおこす.\n'
          '　→NAd ≦0.1γ程度までテーパーできればEN開始する.\n'
          '　　また蠕動音, 排便排ガスなくても安全に開始できる.\n'
          '・胃残 (GRV) <500mlならEN速度上げていく.\n'
          '　GRVが多い場合は蠕動薬や幽門後栄養 (誤嚥予防)を考える.\n'
          '・下痢の対策として (優先順位目安として)\n'
          '　①とろみをつける\n'
          '　②整腸剤, 食品の追加, 浸透圧を等張にする.\n'
          '　③滴下速度 100ml/h以下にする.\n'
          '・Refeeding症候群：NICEガイドライン参照\n'
          '　P, K, Mg, またvit B1が急激に減少するので補正する.\n'
          '・ダンピング症候群：空腸投与時は10-50ml/hから開始する.\n'
          '　最大100ml/hまでとする.',
    ),
    _NoteSection(
      category: 'EN',
      title: 'EN製剤の選択',
      color: Color(0xFF2E7D32),
      body: '■分類\n'
          '窒素源の形態により成分, 消化態, 半消化態に分類される.\n'
          '①成分栄養剤は脂肪含有量が極めて低い物があり, 2週間以上単独で使用する場合は必須脂肪酸を補充する必要がある.\n'
          '②消化態栄養素はペプチドを含む. 成分栄養より吸収効率が良い.\n'
          '③半消化態栄養剤はバランスや栄養に優れており消化機能に問題がなければ選択すべき.\n\n'
          '■選択の方法\n'
          '実効吸収面積の減少による吸収不良　：成分◯ 消化態△ 半消化態✕\n'
          '膵外分泌機能低下による消化不良　　：成分◯ 消化態◯ 半消化態△\n'
          '胆汁分泌障害による消化不良　　　　：成分◯ 消化態◯ 半消化態△\n'
          '食塊と消化液分泌のタイミング不調　：成分◯ 消化態△ 半消化態✕\n'
          '（◯重症例でも可, △中等症まで, ✕不適）\n\n'
          '消化吸収に問題があれば消化態栄養素\n'
          '→なければ半消化態栄養素を選ぶ.\n'
          '　個々の病態に応じて病態別栄養剤(*)も考慮する.\n'
          '→水分制限があるなら2kcal/ml前後に調整されたものを選択する.\n'
          '→1000kcal/day未満では微量元素, ビタミンが必要量を満たさず長期化すると欠乏症をおこすので採血を見て適宜補正する.\n\n'
          '＊病態別栄養剤\n'
          '糖尿病, 肝疾患, 腎疾患, 呼吸不全, 腫瘍, 免疫調整剤に向けた製剤.',
    ),
    _NoteSection(
      category: 'TPN',
      title: '中心静脈栄養 (TPN)',
      color: Color(0xFF1565C0),
      body: '・EN禁忌の患者は入室後7日目までにTPNもしくはPPNを開始する.\n'
          '　→栄養リスク高い患者 (NRS2002 ≧5点, NUTRIC score ≧6点)は速やかに開始.\n'
          '　→PPN 7日以上になればPICCなどのCVC留置を検討する.\n'
          '・腸管は最大級の免疫組織なので, 腸管を使用しないPNは感染性合併症が増える.\n'
          '　一方で確実に投与できるので過剰栄養 (=高血糖)になりやすく, これも感染を増やす.\n'
          '　重症患者では体タンパクの崩壊等による内因性エネルギー供給が多いので, これを勘案した投与設計をする.',
    ),
    _NoteSection(
      category: 'PPN',
      title: '末梢静脈栄養 (PPN)',
      color: Color(0xFF00838F),
      body: '・1000kcal/day程度の栄養が可能. 2週間以内の短期間なら考慮する.\n'
          '　栄養障害が高度な場合は水制限もできるTPNを選択する.\n'
          '　PPN単独での栄養状態の改善は難しいので経口やENとの併用をする.',
    ),
    _NoteSection(
      category: 'エネルギー\n算出法',
      title: 'エネルギー算出法',
      color: Color(0xFFE67E22),
      body: '目標エネルギー量をどう決めるか――その考え方は歴史的に変遷してきた。\n\n'
          '■ Harris-Benedictの式 (1919)\n'
          '基礎代謝量(BEE)を体重・身長・年齢から推定する古典的回帰式。健常者の実測がもとで、臨床では Long(1979) が「BEE×活動係数×侵害(ストレス)係数」を掛けて必要量とする方法を広めた。\n'
          '　女性 BEE = 655 + 9.6×体重kg + 1.8×身長cm − 4.7×年齢\n'
          '　男性 BEE =  66 + 13.7×体重kg + 5.0×身長cm − 6.8×年齢\n'
          '　（※女性定数は 655。665 は広く出回る誤記）\n'
          '長所: 個別の体格を反映。短所: もとが健常者由来で、重症・浮腫・肥満では系統的に過大評価しやすく、係数の掛け算がさらに過剰栄養を招くとされ、ICUでは支持を失っていった。\n\n'
          '■ 簡易式 (25〜30 kcal/kg/day)\n'
          '「複雑な式でも実測より正確とは限らない」という反省から、体重あたりの簡便な目安が普及。ASPEN/SCCM 2016・ESPEN 2019・JSPEN が採用。肥満では低めの係数(11〜14 kcal/kg)や理想体重を用いる。\n'
          '長所: 簡便で過剰栄養を避けやすい。短所: 体組成や代謝亢進の個別差は反映しにくい。\n\n'
          '■ 間接熱量測定 (indirect calorimetry)\n'
          '呼気のO₂消費・CO₂産生から実際の安静時エネルギー消費(REE)を測る、現在のゴールドスタンダード。ESPEN/ASPEN は「可能なら測定」を推奨。機器・人手・リーク等の制約で全例には使えないのが現実。\n\n'
          '■ いま何がエビデンスか\n'
          '・正確さ: 間接熱量測定 ＞ 体重あたり簡易式 ≧ 予測式(H-B等)。予測式は誤差が大きい。\n'
          '・急性期はむしろ不足を許容(permissive underfeeding)し過剰栄養を避けるのが主流(ESPEN)。\n'
          '・どの式でも、重症・浮腫・肥満では体重指標(実体重/理想体重/補正体重)の選択が結果を大きく左右する。\n\n'
          '本アプリでは患者情報編集で式を選べ(H-B / Mifflin-St Jeor / 簡易kcal·kg / 間接熱量測定)、補正体重は内部で自動採用する。',
    ),
    _NoteSection(
      category: '活動係数\n侵害係数',
      title: '活動係数 AF',
      color: Color(0xFFE91E8C),
      body: '寝たきり体動なし            1.0 – 1.1\n'
          '寝たきり体動あり            1.1 – 1.2\n'
          'ベッド外活動 (車椅子)   1.2 – 1.3\n'
          'ベッド外活動 (歩行)       1.3 – 1.4\n'
          '積極的なリハビリ            1.5以上\n'
          '\n'
          '■背景\n'
          '・Harris-Benedictは基礎代謝量(BEE)の推定式。これに活動係数(AF)×侵害係数(SF)を掛けて'
          '1日の総エネルギー消費量(TEE)を概算する(Longの式, 1979)。\n'
          '・AFは身体活動による上乗せ分。ICUでは安静〜リハ進行に応じて概ね1.0〜1.4。\n'
          '・AFとSFを掛け合わせるほど推定値は大きくなるため、両係数が高いと過大評価に傾く'
          '(→侵害係数の項を参照)。',
    ),
    _NoteSection(
      category: '活動係数\n侵害係数',
      title: '侵害 (ストレス) 係数 SF',
      color: Color(0xFFE91E8C),
      body: '低栄養                                                              1.0未満\n'
          'ストレスなし (術前, 退院直前などの状態)   1.0\n'
          '手術                                                                1.1 – 1.8　(外傷 1.35)\n'
          '癌                                                                   1.1 – 1.3\n'
          '感染症                                                            1.2 – 1.5　(敗血症 1.6)\n'
          '発熱                                                                1.2 – 1.5\n'
          '熱傷                                                                1.2 – 2.0　(広範囲熱傷 2.1)\n'
          '\n'
          '■背景\n'
          '・SFは疾患・侵襲による代謝亢進(hypermetabolism)の上乗せ係数(Longの式, 1979)。'
          '敗血症・外傷・熱傷などで基礎代謝が増える。\n'
          '\n'
          '■「SF≧1.5で過大栄養になりうる」根拠\n'
          '・BEE×AF×SFの予測式は、重症患者では実測エネルギー消費量(間接熱量測定)を'
          '過大評価しやすいことが報告されている。\n'
          '・急性期は異化による内因性エネルギー供給があるため、計算値どおりフル投与すると'
          '過剰栄養(overfeeding)になりやすい。\n'
          '・過剰栄養は高血糖・高TG血症・脂肪肝・CO2産生増加(換気負担)・感染・'
          '人工呼吸期間の延長などのリスクと関連する。\n'
          '・ASPEN/SCCM(2016)・ESPEN(2019)は、間接熱量測定が使えない場合は'
          '25–30 kcal/kg/day を目安とし、急性期は計算値の100%投与を急がない'
          '(段階的に増量)ことを推奨している。\n'
          '・目安として、侵害係数が高い(SF≧1.5)とAFと相まって目標が概ね'
          '>30 kcal/kg/day に達し、過剰栄養域に入りやすい'
          '(本アプリも該当時に注意表示)。\n'
          '※いずれも目安であり、最終判断は患者の病態と主治医の評価による。',
    ),
    _NoteSection(
      category: 'タンパク',
      title: 'タンパクの投与量',
      color: Color(0xFFE53935),
      body: '・全体の10〜20%を補うように投与\n'
          '・手術や敗血症などの高侵襲時はインスリン・カテコラミン↑となるため,\n'
          '　脂肪分解とケトーシスが抑制され, エネルギー源として筋蛋白が主に利用される.\n'
          '　→ 侵襲時にはアミノ酸製剤を混ぜる必要がある.\n\n'
          '式) 必要蛋白量 (アミノ酸g) = 6.25 × 必要窒素量g = 6.25 × 必要熱量kcal ÷ NPC/N\n\n'
          '■ NPC/N比\n'
          '　"蛋白に対し脂質と炭水化物がどの程度であれば蛋白が効率よく利用されるか"の指標\n'
          '　窒素1g = 蛋白質6.25gとして計算.\n'
          '　通常 150 / 敗血症 100–150 / 外科手術 150–200\n'
          '　飢餓 400–600 / 腎不全 500–1000\n\n'
          '■ 投与量の目安\n'
          '・重症患者: 1.2–2.0 g/kg/day (蛋白異化亢進のため)\n'
          '・その他患者: 最低 1 g/kg/day, 目標 1.2–1.5 g/kg/day\n'
          '・CKD患者 (≠AKI): 0.6–0.8 g/kg/day\n'
          '・肝硬変患者: 1–1.2 g/kg/day\n\n'
          '■ 注意事項\n'
          '・投与速度が早すぎると悪心嘔吐が出現する.\n'
          '・アミノ酸とグルコースはメイラード反応で褐変する. 投与直前に混ぜること.',
    ),
    _NoteSection(
      category: '炭水化物',
      title: '炭水化物の投与量',
      color: Color(0xFF8BC34A),
      body: '・全体の60〜70%を補うように投与.\n'
          '・末梢から投与可能な加糖液の濃度限界は10%.',
    ),
    _NoteSection(
      category: '脂質',
      title: '脂質の投与量',
      color: Color(0xFF009688),
      body: '・10〜20%を補うように投与\n'
          '・NPC/N比や糖質負荷量を適正化する目的に使用.\n'
          '・投与量は 1.0 g/kg/day以下, 投与速度 0.1 g/kg/h以下を厳守.\n'
          '　投与速度が速いと肺に蓄積され呼吸不全, 免疫機能低下を来す.\n'
          '・肝機能悪化, TG上昇, 胆嚢炎, 膵炎に注意しながら投与.\n'
          '・基本的に初期から投与する必要はない.\n'
          '　→ 2週間程度で必須脂肪酸が欠乏してくるので, その時点で投与を考慮.',
    ),
    _NoteSection(
      category: '電解質',
      title: '電解質',
      color: Color(0xFF3F51B5),
      body: '■ Na（ナトリウム）\n・厚労省 食事摂取基準2025 食塩相当量 目標量: 男性<7.5 / 女性<6.5 g/日。高血圧・CKD治療目標<6 g/日。\n・換算: 食塩1 g = Na 17.1 mEq。6 g=102.7 mEq, 7.5 g=128.3 mEq。\n・静脈栄養(ASPEN/JSPEN)標準: 1〜2 mEq/kg/日。本アプリは 食塩7 g/日(Na≈119.8 mEq, HTなし成人の目標値)超で黄、9.6 g/日(Na≈164.3 mEq, 日本人の平均食塩摂取量)以上で赤の塩分負荷アラート。\n\n■ K（カリウム）\n・食事摂取基準2025 目安量 男2,500/女2,000 mg/日(目標量 男3,000/女2,600 mg以上)。耐容上限なし。\n・PN標準 1〜2 mEq/kg/日。1日100 mEq超は注意。投与速度≤20 mEq/h・濃度≤40 mEq/L(原則中心静脈・心電図監視)。\n\n■ Ca（カルシウム）\n・推奨量 650〜800 mg/日、耐容上限 2,500 mg/日(≒125 mEq)。PN標準 10〜15 mEq/日。P製剤との配合変化(沈殿)に注意。\n\n■ Mg（マグネシウム）\n・推奨量 男340〜380/女280〜290 mg/日(サプリ等の上限350 mg)。PN標準 8〜20 mEq/日。腎機能低下で高Mg血症に注意。\n\n■ P（リン）\n・目安量 男1,000/女800 mg/日、耐容上限 3,000 mg/日(≒97 mmol)。PN標準 20〜40 mmol/日。Refeedingで低下しやすく要モニタ。\n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN 静脈経腸栄養ガイドライン',
    ),
    _NoteSection(
      category: 'ビタミン',
      title: 'ビタミン',
      color: Color(0xFF9C27B0),
      body: '■ ビタミンB1（チアミン）\n・体内貯蔵量が約30 mgと少なく早期に欠乏。糖負荷で需要増。Refeeding/Wernicke予防に投与前〜10日 200〜300 mg/日(NICE/JSPEN)。\n\n■ 耐容上限(UL)が臨床上重要なもの（食事摂取基準2025）\n・ビタミンA: 推奨 650〜900 µgRAE、UL 2,700 µgRAE/日。過剰で肝障害・頭蓋内圧亢進。\n・ビタミンD: 目安 9.0 µg、UL 100 µg(4,000 IU)/日。過剰で高Ca血症。\n・ビタミンB6: 推奨 1.2〜1.5 mg、UL 45〜60 mg/日。過剰で感覚性ニューロパチー。\n・葉酸(強化食品/サプリ) UL 900〜1,000 µg/日。ナイアシン UL 300〜350 mg/日。\n\n■ 静脈栄養の総合ビタミン(ASPEN成人/国内オーツカMV・ビタジェクト相当・1日量)\n・B1 3〜6・B2 3.6・B6 4〜6 mg, B12 5 µg, ナイアシン 40 mg, 葉酸 400〜600 µg, C 100〜200 mg, A 3,300 IU, D 200 IU, E 10 mg, K 150 µg。\n・TPNでは水溶性ビタミンが不足しやすく、毎日の総合ビタミン投与が基本。\n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN',
    ),
    _NoteSection(
      category: '微量元素',
      title: '微量元素',
      color: Color(0xFFFF7043),
      body: '微量元素は長期TPNで欠乏・過剰の両方が問題になる。経口/経腸はDRI、静脈はASPEN/JSPENで必要量が異なる。\n\n■ 必要量と耐容上限（食事摂取基準2025 / 括弧は内部単位µmol）\n・亜鉛 Zn: 推奨 8〜9.5 mg、UL 男45/女35 mg(≒688/535 µmol)。創傷治癒・味覚に重要。\n・銅 Cu: 推奨 0.7〜0.9 mg、UL 7 mg(≒110 µmol)。Zn過剰投与でCu欠乏を招く。\n・セレン Se: 推奨 25〜35 µg、UL 男450/女350 µg(≒5.7/4.4 µmol)。長期TPNで欠乏(心筋症)。\n・マンガン Mn: 目安 3〜3.5 mg、UL 11 mg(≒200 µmol)。胆汁うっ滞・長期TPNで脳(淡蒼球)蓄積→パーキンソン様神経毒性。減量/中止を検討。\n・ヨウ素 I: 推奨 140 µg、UL 3,000 µg(≒23.6 µmol)。\n・鉄 Fe: 推奨 男7.5/女(月経)10.5 mg。PNには通常ルーチン添加しない(鉄過剰リスク)。\n\n■ 静脈栄養の標準（ASPEN成人 / 国内エレジェクト等・1日量）\n・Zn 3〜5 mg, Cu 0.3〜0.5 mg, Se 60〜100 µg。Mn 国内製剤は約1.1 mg(ASPEN推奨55 µgの約20倍→長期は要注意)。\n・1,000 kcal/日未満が長期化すると不足しやすく、採血で過不足を確認し補正。\n\n出典: 厚労省「日本人の食事摂取基準2025」/ ASPEN 2019 / JSPEN / 食品安全委員会(Mn)',
    ),
    _NoteSection(
      category: 'ガイドライン',
      title: 'ASPEN/SCCM・ESPEN 概説',
      color: Color(0xFF6D4C41),
      body: 'ICU栄養の二大ガイドライン。要点を対比して概説する。\n\n■ ASPEN/SCCM 2016（米・McClaveら, 2022更新）\n・開始: 血行動態が安定すれば 24〜48時間以内に経腸栄養(EN)を開始。\n・エネルギー: 間接熱量測定が第一。なければ 25〜30 kcal/kg/日。\n・タンパク: 1.2〜2.0 g/kg/日。肥満は BMI30〜40で2.0、≥40で2.5 g/kg(理想体重)。\n・肥満の許容的低カロリー: BMI30〜50は11〜14 kcal/kg(実体重)、>50は22〜25 kcal/kg(理想体重)。\n・第1週はEN優先、栄養リスクが低ければ早期PNは急がない。\n\n■ ESPEN 2019（欧・Singerら, 2023実践版）\n・エネルギー: 間接熱量測定を推奨。なければ 20〜25 kcal/kg/日。\n・急性期早期(〜3日)は permissive underfeeding（目標の<70%）→以後80〜100%へ漸増。過剰栄養を避ける。\n・タンパク: 1.3 g/kg/日を漸増。糖質≤5 mg/kg/min、脂質≤1.5 g/kg/日。\n\n■ 近年の潮流\n・「早期の積極的フルフィード」より「過剰栄養を避け漸増」へ。\n・精度は 間接熱量測定 ＞ 体重あたり簡易式 ＞ 予測式。\n・電解質(特にRefeeding)・血糖(140〜180 mg/dL)を厳格に管理。\n\n出典: McClave et al. JPEN 2016 / Compher et al. JPEN 2022 / Singer et al. Clin Nutr 2019・2023',
    ),
    _NoteSection(
      category: 'Refeeding',
      title: 'Refeeding症候群 (NICE)',
      color: Color(0xFFC2185B),
      body: '低栄養・絶食後に栄養(特に糖質)を再開すると、細胞内へK・P・Mgが移動し致死的な低下を来す病態。インスリン分泌再開とビタミンB1需要増が引き金。\n\n■ 高リスク基準（NICE CG32, 2006）\n・次のいずれか1つ: BMI<16 / 3〜6か月で>15%体重減 / 10日以上のほぼ絶食 / 投与前からK・P・Mg低値。\n・または次のいずれか2つ: BMI<18.5 / >10%体重減 / 5日以上のほぼ絶食 / アルコール・薬物(インスリン・化学療法・制酸薬・利尿薬)歴。\n・超高リスク: BMI<14 または 15日以上の絶食。\n\n■ 対処\n・開始エネルギー: 高リスク 10 kcal/kg/日(超高リスクは5、心電図監視)。4〜7日かけて必要量へ漸増。\n・チアミン(B1) 200〜300 mg/日を糖負荷の前〜10日。総合ビタミンB群も。\n・電解質は補充しながら投与(正常化を待って開始を遅らせない): K 2〜4 / P 0.3〜0.6 / Mg 0.2〜0.4 mmol/kg/日。\n・血清P≥2.0 mg/dL維持。K・P・Mg・血糖を頻回モニタ。\n\n本アプリは絶食開始日・BMIからリスク階層を判定し、自動設計の初期kcalを上記rampで自動cap、対処サジェストを表示する。\n\n出典: NICE CG32「Nutrition support for adults」(2006) / JSPEN',
    ),
    _NoteSection(
      category: '微量元素\n病態調整',
      title: '微量元素の病態別調整',
      color: Color(0xFF5E35B1),
      body: '微量元素・ビタミンは「過剰(蓄積)」と「不足(喪失)」の両方が問題になり、病態で方向が変わる。\n\n■ 通常患者: 非重複が原則\nベースが内蔵する成分は加注しない(二重投与回避)。\n・エルネオパNF/ワンパル(電解質+微量元素+ビタミン内蔵)→加注なし(Seのみ条件付き)\n・フルカリック(ビタミンのみ)→微量元素のみ追加\n・ミキシッド/ゼロmenu→MVI+微量元素\n\n■ 胆汁うっ滞・肝不全・肝性脳症: Cu/Mn過剰回避\nMnは胆汁排泄80%→淡蒼球に蓄積しパーキンソン様(不可逆あり)。胆道閉塞はMn製剤禁忌。\n→標準微量元素(Mn 20μmol)をMn-free「ボルビサール」へ切替。Cuは減量しつつ残す(ゼロにしない)。\nモニタ: 全血Mn(基準0.52–2.4μg/dL)、血清Cu+セルロプラスミン(月2回)。\n\n■ 腎不全(非透析): Cr/Mn蓄積\nCrは輸液汚染で充足し追加不要(腎障害助長)。複合微量元素を減量し血中濃度をモニタ。\n\n■ CRRT・持続透析: 喪失側→補充\n水溶性(Se・B1・Cu・葉酸・VitC・カルニチン)が透析液へ喪失。Se・B1を2倍目安で補充、複合traceは継続。VitC高用量はシュウ酸で避ける。\n\n■ 高排出消化管瘻・大量下痢: Zn喪失\nZn 腸液+12mg/L・便/ストマ+17mg/Lを上乗せ。Mg/K/Na・水分も補正。\n\n■ チアミン×糖負荷(安全インターロック)\nB1欠乏者に糖を先行するとWernicke脳症・乳酸アシドーシス。糖の前〜同時にB1 100–300mg。標準MVIのB1 3mgは予防に不足→高用量B1製剤を別途。\n\n■ 単剤 add / replace\n・ADD: 創傷・高GI損失でZn追加、CRRT/長期でSe(アセレンド)追加。\n・REPLACE: Mn回避が必要な胆汁うっ滞で 標準複合→Mn-free複合+Se単剤。\n・注意: 国内にIV亜鉛単剤がほぼ無く、Zn増量は複合もう1管/院内調製/経口併用。\n\n■ 栄養開始時セット vs 補正後増量セット\n・開始時(refeeding慎重): B1高用量を糖前にフロントロード+標準MVI+標準微量元素(胆汁うっ滞ならMn-free)。Se/Zn追加なし、10–15kcal/kgで慎重、K/PO4/Mg頻回。\n・補正後増量: Se(CRRT/長期/熱傷/創傷)・Zn(高排出/創傷)追加、Mn再評価、採血ベースで増量。\n\n出典: ESPEN micronutrient guideline 2022 / ASPEN / JSPEN / NICE CG32 / 各添付文書',
    ),
  ];

  static final _categoryColors = <String, Color>{
    _allLabel: Color(0xFF4CAF50),
    'つかいかた': Color(0xFF4A90D9),
    'EN': Color(0xFF2E7D32),
    'TPN': Color(0xFF1565C0),
    'PPN': Color(0xFF00838F),
    'エネルギー\n算出法': Color(0xFFE67E22),
    'ガイドライン': Color(0xFF6D4C41),
    'Refeeding': Color(0xFFC2185B),
    '微量元素\n病態調整': Color(0xFF5E35B1),
    '活動係数\n侵害係数': Color(0xFFE91E8C),
    'タンパク': Color(0xFFE53935),
    '炭水化物': Color(0xFF8BC34A),
    '脂質': Color(0xFF009688),
    '電解質': Color(0xFF3F51B5),
    'ビタミン': Color(0xFF9C27B0),
    '微量元素': Color(0xFFFF7043),
  };

  @override
  void initState() {
    super.initState();
    _editableSections = List.from(_sections);
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _snapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOut.transform(_snapCtrl.value);
      setState(() =>
          _panelHeight = _snapFrom + (_snapToTarget - _snapFrom) * t);
    });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _noteScroll.dispose();
    super.dispose();
  }

  void _snapTo(double target) {
    _snapFrom = _panelHeight;
    _snapToTarget = target;
    _snapCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _selected == _allLabel
        ? _editableSections
        : _editableSections.where((s) => s.category == _selected).toList();
    final screenH = MediaQuery.of(context).size.height;
    final _nqPad = MediaQuery.of(context).padding;
    // ノートページはHomePageのScaffold内（AppBar+NavigationBar(80)を除く）
    const _navBarH = 80.0;
    final maxPanel = (screenH - _nqPad.top - kToolbarHeight - _navBarH - _nqPad.bottom)
        .clamp(200.0, screenH);
    if (_panelHeight > maxPanel) _panelHeight = maxPanel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上部(カテゴリー + 新規作成)。本文展開時は縮んでスクロール
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // カテゴリーグリッド
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 3.8,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    children: _categoryColors.entries.map((e) {
                      final selected = _selected == e.key;
                      return GestureDetector(
                        onTap: () => setState(() => _selected = e.key),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          decoration: BoxDecoration(
                            color: selected ? e.value : e.value.withOpacity(0.68),
                            borderRadius: BorderRadius.circular(6),
                            border: selected ? Border.all(color: Colors.white, width: 2.5) : null,
                            boxShadow: selected
                                ? [BoxShadow(color: e.value.withOpacity(0.4), blurRadius: 4, offset: const Offset(0, 2))]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(e.key,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                // 新規作成ボタン
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () => _createNote(context),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新規作成'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 本文パネル(ドラッグで上に展開。処方ビルダーのサマリと同仕様)
        SafeArea(
          top: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: SizedBox(
              width: double.infinity,
              height: _panelHeight,
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withOpacity(0.4),
                      width: 0.8),
                ),
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragUpdate: (d) {
                        setState(() {
                          _panelHeight = (_panelHeight - d.delta.dy)
                              .clamp(_panelMin, maxPanel);
                        });
                      },
                      onVerticalDragEnd: (_) {
                        // 上端まで引っ張ったら下端に戻す。それ以外は離した位置で止まる。
                        if (_panelHeight >= maxPanel) _snapTo(_panelMin);
                      },
                      child: Container(
                        color: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Center(
                          child: Container(
                            height: 4,
                            width: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: _noteScroll,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        children: filtered
                            .map((s) => _buildSection(s, filtered.indexOf(s)))
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _createNote(BuildContext context) async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新規ノート作成'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'タイトル')),
            const SizedBox(height: 8),
            TextField(controller: bodyCtrl, maxLines: 8, minLines: 4,
                decoration: const InputDecoration(labelText: '本文', border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('追加')),
        ],
      ),
    );
    if (saved != true || titleCtrl.text.trim().isEmpty) return;
    setState(() {
      _editableSections.add(_NoteSection(
        category: _selected == _allLabel ? 'つかいかた' : _selected,
        title: titleCtrl.text.trim(),
        body: bodyCtrl.text,
        color: _categoryColors[_selected] ?? const Color(0xFF607D8B),
      ));
    });
  }

  Future<void> _editNote(BuildContext context, _NoteSection s, int index) async {
    final titleCtrl = TextEditingController(text: s.title);
    final bodyCtrl = TextEditingController(text: s.body);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ノートを編集'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'タイトル')),
            const SizedBox(height: 8),
            TextField(controller: bodyCtrl, maxLines: 12, minLines: 4,
                decoration: const InputDecoration(labelText: '本文', border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    setState(() {
      final globalIdx = _editableSections.indexOf(s);
      if (globalIdx >= 0) {
        _editableSections[globalIdx] = _NoteSection(
          category: s.category, title: titleCtrl.text.trim(),
          body: bodyCtrl.text, color: s.color,
        );
      }
    });
  }

  Widget _buildSection(_NoteSection s, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '■ ',
                      style: TextStyle(
                          color: s.color,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                    TextSpan(
                      text: s.title,
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _editNote(context, s, index),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('編集', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withOpacity(0.4),
                  width: 0.8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(s.body, style: const TextStyle(height: 1.7, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}

class MasterPage extends StatefulWidget {
  const MasterPage({super.key, required this.state});
  final AppState state;

  @override
  State<MasterPage> createState() => _MasterPageState();
}

class _MasterPageState extends State<MasterPage> {
  String category = 'EN';
  String _query = '';

  static const _masterCats = [
    'EN', 'TPN', 'PPN', '食事', '電解質', '微量元素', 'ビタミン'
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // EN: EN本体/補助 + 両用food(alsoEn) を表示 / 食事: 濃厚流動食+栄養サポートを統合
    final all = category == 'EN'
        ? widget.state.catalog.products.where((p) => p.inEnTab).toList()
        : category == '食事'
            ? widget.state.catalog.products.where((p) => p.isFood).toList()
            : widget.state.catalog.byCategory(category);
    final q = _query.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : all
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.content.toLowerCase().contains(q))
            .toList();
    final total = widget.state.catalog.products.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── ヘッダ: タイトル + 製剤数合計 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Row(
            children: [
              Text('製剤マスタ',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('全 $total 製剤',
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        // ── 検索 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: '製剤名・性状で検索',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
            ),
          ),
        ),
        // ── カテゴリチップ (横スクロール) ──
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final c in _masterCats)
                _catChip(c, category == c,
                    () => setState(() => category = c)),
            ],
          ),
        ),
        // ── 説明 + 件数 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    category == '食事'
                        ? '食事(経口リハ)期の製剤。EN印は経腸でも使用可'
                        : '院内採用薬を選択（容量はチップで選択）',
                    style: theme.textTheme.bodySmall),
              ),
              Text('${items.length}件',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.black45)),
            ],
          ),
        ),
        // ── リスト ──
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('該当する製剤がありません',
                      style: TextStyle(color: Colors.black45)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    // 「食事」タブは 濃厚流動食 / 栄養サポート食品 に分割表示
                    if (category == '食事') ...[
                      for (final sub in const ['濃厚流動食', '栄養サポート食品'])
                        ...(() {
                          final subItems =
                              items.where((p) => p.category == sub).toList();
                          if (subItems.isEmpty) return <Widget>[];
                          return [
                            _foodSectionHeader(sub),
                            ..._groupCards(subItems),
                          ];
                        })(),
                    ] else
                      ..._groupCards(items),
                  ],
                ),
        ),
      ],
    );
  }

  /// 麻酔薬リファレンス風 カテゴリ選択チップ
  Widget _catChip(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        selectedColor: scheme.primary,
        labelStyle: TextStyle(
          color: selected ? Colors.white : Colors.black87,
          fontSize: 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
        backgroundColor: Colors.white,
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.3)),
      ),
    );
  }

  /// 製剤を同一ベース名(容量違い)でまとめてカード化。
  /// 加注(電解質/微量元素/ビタミン)は種別順、それ以外はあいうえお順。
  List<Widget> _groupCards(List<Product> list) {
    final groups = <String, List<Product>>{};
    for (final p in list) {
      groups.putIfAbsent(productBaseName(p.name), () => []).add(p);
    }
    final cat = list.isNotEmpty ? list.first.category : '';
    final order = _additiveTypeOrder[cat];
    final keys = groups.keys.toList();
    if (order != null) {
      int rank(String k) {
        final i = order.indexOf(groups[k]!.first.addType ?? '');
        return i < 0 ? 999 : i;
      }
      keys.sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : kanaSortKey(a).compareTo(kanaSortKey(b));
      });
    } else {
      keys.sort((a, b) => kanaSortKey(a).compareTo(kanaSortKey(b)));
    }
    return keys.map((k) => _productGroupCard(k, groups[k]!)).toList();
  }

  /// 「食事」タブのサブセクション見出し（----濃厚流動食---- 等）
  Widget _foodSectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(
          children: [
            const Expanded(child: Divider(thickness: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.teal.shade700)),
            ),
            const Expanded(child: Divider(thickness: 1)),
          ],
        ),
      );

  // ビタミンの単位 (1袋あたり)
  static const _vitUnits = {
    'B1': 'mg', 'B2': 'mg', 'B6': 'mg', 'B12': 'μg',
    'ナイアシン': 'mg', 'パントテン酸': 'mg', '葉酸': 'mg', 'ビオチン': 'μg',
    'C': 'mg', 'A': 'VA単位', 'D': 'μg', 'E': 'mg', 'K': 'mg',
  };

  String _numFmt(dynamic v) {
    if (v is num) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return '$v';
  }

  /// 微量栄養素セクション (電解質/微量元素/ビタミン)
  /// perL=true: 濃度(per L)表記 [PPN] / false: 1袋あたり [TPN等]
  Widget _microSection(Map<String, dynamic> micro, {bool perL = false}) {
    final per = perL ? '/L' : '/袋';
    final rows = <Widget>[];
    Widget line(String head, String body, Color c) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4),
              children: [
                TextSpan(
                    text: '$head  ',
                    style: TextStyle(fontWeight: FontWeight.bold, color: c)),
                TextSpan(text: body),
              ],
            ),
          ),
        );

    final elec = (micro['elec'] as Map?)?.cast<String, dynamic>();
    if (elec != null && elec.isNotEmpty) {
      final parts = <String>[];
      for (final k in ['Na', 'K', 'Cl', 'Ca', 'Mg']) {
        if (elec[k] != null) parts.add('$k ${_numFmt(elec[k])}');
      }
      var body = parts.isEmpty ? '' : '${parts.join(' / ')} mEq$per';
      if (elec['P'] != null) {
        body += '${body.isEmpty ? '' : ', '}P ${_numFmt(elec['P'])} mmol$per';
      }
      rows.add(line('電解質', body, Colors.indigo.shade700));
    }

    final trace = (micro['trace'] as Map?)?.cast<String, dynamic>();
    if (trace != null && trace.isNotEmpty) {
      final parts = <String>[];
      for (final k in ['Zn', 'Fe', 'Mn', 'Cu', 'I']) {
        if (trace[k] != null) parts.add('$k ${_numFmt(trace[k])}');
      }
      var body = parts.isEmpty ? '' : '${parts.join(' / ')} μmol$per';
      if (trace['Se'] != null) {
        // Se は μg 表記
        body += '${body.isEmpty ? '' : ', '}Se ${_numFmt(trace['Se'])} μg$per';
      }
      rows.add(line('微量元素', body, Colors.deepOrange.shade700));
    }

    final vit = (micro['vit'] as Map?)?.cast<String, dynamic>();
    if (vit != null && vit.isNotEmpty) {
      final parts = <String>[];
      vit.forEach((k, v) {
        final u = _vitUnits[k] ?? '';
        parts.add('$k ${_numFmt(v)}$u');
      });
      rows.add(line('ビタミン', parts.join(' / '), Colors.purple.shade700));
    }

    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(perL ? '含有量 (mEq/L = 1L中の濃度)' : '含有量 (1袋あたり)',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey.shade400)),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  String _volLabel(Product p) {
    final v = p.volumeMl;
    if (v == null) return '—';
    final s = v % 1 == 0 ? v.toInt().toString() : v.toString();
    return '${s}mL';
  }

  /// 同一ベース名(容量違い)を1項目に集約したカード。容量チップで採用を選択。
  Widget _productGroupCard(String base, List<Product> variants) {
    variants.sort((a, b) => (a.volumeMl ?? 0).compareTo(b.volumeMl ?? 0));
    final adoptedAny = variants.any((p) => widget.state.isAdopted(p.id));
    final rep = variants.firstWhere((p) => widget.state.isAdopted(p.id),
        orElse: () => variants.first);
    final typeColor =
        rep.productType == '医薬品' ? Colors.red.shade100 : Colors.green.shade100;
    final typeTextColor =
        rep.productType == '医薬品' ? Colors.red.shade900 : Colors.green.shade900;

    return Card(
      child: ExpansionTile(
        leading: Icon(adoptedAny ? Icons.circle : Icons.circle_outlined,
            color: adoptedAny ? Colors.blue : null),
        title: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(base,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            _miniTag(rep.productType, bg: typeColor, fg: typeTextColor),
            if (rep.content.isNotEmpty)
              _miniTag(rep.content,
                  bg: Colors.blueGrey.shade50, fg: Colors.blueGrey.shade900),
            // 両用(食事⇔EN)製剤バッジ
            if (rep.alsoEn)
              _miniTag('EN両用',
                  bg: Colors.green.shade50, fg: Colors.green.shade800),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 容量チップ (タップで採用ON/OFF・複数可)
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: variants.map((p) {
                  final on = widget.state.isAdopted(p.id);
                  return FilterChip(
                    label: Text(_volLabel(p),
                        style: const TextStyle(fontSize: 12)),
                    selected: on,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) async {
                      await widget.state.toggleAdopted(p.id);
                      setState(() {});
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 2),
              Text('${rep.kcalString} / ${rep.aminoString}',
                  style:
                      const TextStyle(fontSize: 12.5, color: Colors.black54)),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (variants.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('▼ 組成は ${_volLabel(rep)} のもの',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ),
          ..._productDetailChildren(rep),
        ],
      ),
    );
  }

  /// 製剤詳細(要素/NPC/脂質/糖質・含有量・コメント)を返す共通部品。
  List<Widget> _productDetailChildren(Product p) {
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (p.category != 'TPN' && p.category != 'PPN')
            InfoChip(
                label: '分類',
                value: p.productType,
                onTap: () => _editProductType(p)),
          InfoChip(
              label: '要素',
              value: p.content.isEmpty ? '-' : p.content,
              onTap: () => _editContent(p)),
          InfoChip(label: 'NPC/N', value: p.npcNRatio?.toString() ?? '-'),
          InfoChip(
              label: '脂質',
              value: (p.fatBase == null || p.fatBase == 0)
                  ? '-'
                  : '${p.fatBase!.toStringAsFixed(p.fatBase! % 1 == 0 ? 0 : 1)}g'),
          InfoChip(
              label: '糖質',
              value: (p.carbBase == null || p.carbBase == 0)
                  ? '-'
                  : '${p.carbBase!.toStringAsFixed(p.carbBase! % 1 == 0 ? 0 : 1)}g'),
        ],
      ),
      if (p.micro != null) ...[
        const SizedBox(height: 10),
        _microSection(p.micro!, perL: p.category == 'PPN'),
      ],
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              p.notes?.trim().isNotEmpty == true ? p.notes! : 'コメントなし',
              style: const TextStyle(height: 1.5),
            ),
          ),
          IconButton(
            tooltip: 'コメントを編集',
            icon: const Icon(Icons.edit_note),
            onPressed: () => _editNotes(p),
          ),
        ],
      ),
    ];
  }

  Widget _miniTag(String text, {required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Future<void> _editNotes(Product p) async {
    final controller = TextEditingController(text: p.notes ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} のコメントを編集'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 12,
            minLines: 5,
            decoration: const InputDecoration(
              hintText: 'コメントを入力してください',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, notes: result);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${p.name} のコメントを保存しました')));
    }
  }

  Future<void> _editProductVolume(Product p) async {
    final controller =
        TextEditingController(text: p.volumeMl?.toString() ?? '');
    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} の容量を編集'),
        content: SizedBox(
          width: 300,
          child: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: '容量（ml）を入力',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () {
                final newVolume = double.tryParse(controller.text);
                Navigator.pop(context, newVolume);
              },
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null || result <= 0) return;
    final originalVolume = (p.volumeMl ?? 0) <= 0 ? result : p.volumeMl!;
    final ratio = result / originalVolume;
    await widget.state.updateProductOverride(
      p,
      volumeMl: result,
      kcal: (p.kcal ?? 0) * ratio,
      aminoAcidG: (p.aminoAcidG ?? 0) * ratio,
      nitrogenG: (p.nitrogenG ?? 0) * ratio,
      fatBase: (p.fatBase ?? 0) * ratio,
      carbBase: (p.carbBase ?? 0) * ratio,
      npcNRatio: p.npcNRatio,
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${p.name} の容量を ${result}ml に更新しました')));
    }
  }

  Future<void> _editProductType(Product p) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${p.name} の分類'),
        children: [
          for (final t in ['食品', '医薬品'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, t),
              child: Row(
                children: [
                  Icon(p.productType == t
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off),
                  const SizedBox(width: 8),
                  Text(t),
                ],
              ),
            ),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, productType: result);
    if (mounted) setState(() {});
  }

  Future<void> _editContent(Product p) async {
    final controller = TextEditingController(text: p.content);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.name} の性状'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例: 半消化態 / 成分栄養 / 高濃度AA など',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (result == null) return;
    await widget.state.updateProductOverride(p, content: result);
    if (mounted) setState(() {});
  }
}

class SliderWithLabel extends StatelessWidget {
  const SliderWithLabel(
      {super.key,
      required this.label,
      required this.value,
      required this.min,
      required this.max,
      required this.onChanged});
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(1)}'),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip(
      {super.key, required this.label, required this.value, this.onTap});
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text('$label: $value'),
    );
    if (onTap == null) return child;
    return InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(999), child: child);
  }
}

class ResultLegend extends StatelessWidget {
  const ResultLegend(
      {super.key,
      required this.color,
      required this.label,
      required this.value});
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(value),
        ],
      ),
    );
  }
}

enum Sex { male, female }

/// 病態タグの定義。患者に付けた病態タグに応じて、対応する病態別製剤を
/// 処方画面で上位(お気に入り扱い)に浮かせ、処方サジェストを表示する。
class ConditionDef {
  const ConditionDef({
    required this.id,
    required this.label,
    required this.suggestion,
    this.proteinCapPerKg,
  });

  final String id; // glucose_intolerance/renal/liver/respiratory/critical/wound/malabsorption/dysphagia
  final String label; // 表示名
  final String suggestion; // 💡 処方サジェスト本文
  final double? proteinCapPerKg; // 蛋白の目安上限(g/kg/day)。超過時に控えめなテキスト(現状は未設定=オフ)
}

/// 病態カタログ(選択アルゴリズム)。各病態の「考え方」と推奨製剤を紐づける。
/// 文言・割り当ては現場でレビュー・調整して使う。
class ConditionCatalog {
  static const List<ConditionDef> all = [
    ConditionDef(
      id: 'glucose_intolerance',
      label: '耐糖能異常',
      suggestion: '急な糖質負荷を避け、血糖変動を大きくしない。'
          '必要なら食物繊維や低GI設計を用いる。',
    ),
    ConditionDef(
      id: 'renal',
      label: '腎不全(保存期)',
      suggestion: '保存期: 低蛋白(0.6–0.8 g/kg/day)・低K・低P で腎負荷を軽減。'
          '十分なエネルギーを確保し異化を防ぐ。',
    ),
    ConditionDef(
      id: 'renal_dialysis',
      label: '腎不全(透析期)',
      suggestion: '透析期: 必要蛋白(1.0–1.2 g/kg/day)を確保しつつ'
          'K/P・水分負荷に配慮。',
    ),
    ConditionDef(
      id: 'liver',
      label: '肝不全/肝性脳症',
      suggestion: '蛋白 1.0–1.2 g/kg/day を目安に低栄養を避け、BCAAを意識。'
          '肝性脳症悪化リスクに配慮(過度な蛋白制限は避ける)。',
    ),
    ConditionDef(
      id: 'respiratory',
      label: '呼吸器疾患/高CO2貯留',
      suggestion: '糖質過多でCO2産生を増やしすぎない。',
    ),
    ConditionDef(
      id: 'critical',
      label: '重症・周術期・高侵襲',
      suggestion: '蛋白 1.2–2.0 g/kg/day と十分なエネルギーを確保。'
          '必要に応じEPA/DHA・アルギニン等の免疫栄養を補充。',
    ),
    ConditionDef(
      id: 'wound',
      label: '褥瘡・創傷治癒・サルコペニア',
      suggestion: '蛋白 1.2–1.5 g/kg/day・十分なエネルギーを確保。'
          'アルギニン・HMB・微量元素(Zn等)の補充を検討。',
    ),
    ConditionDef(
      id: 'malabsorption',
      label: '消化吸収障害・短腸・下痢',
      suggestion: '消化態/成分栄養の要否、脂肪・浸透圧耐性、'
          '吸収のしやすさ・低残渣性に配慮。',
    ),
    ConditionDef(
      id: 'dysphagia',
      label: '嚥下障害・逆流・胃瘻',
      suggestion: '誤嚥・逆流・注入時間・半固形化の要否に配慮。'
          '液体で問題があれば半固形・とろみへの切替を検討。',
    ),
    ConditionDef(
      id: 'cholestasis',
      label: '胆汁うっ滞・胆道閉塞',
      suggestion: 'Mnは胆汁排泄のため蓄積し神経毒性(淡蒼球)。Mn含有微量元素はMn-free(ボルビサール)へ切替。'
          'Cuも減量しつつモニタ(血清Cu・セルロプラスミン)。胆道閉塞ではMn製剤は禁忌。',
    ),
    ConditionDef(
      id: 'crrt',
      label: 'CRRT・持続透析',
      suggestion: '水溶性微量栄養素(Se・B1・Cu・葉酸・VitC)が透析液へ喪失。'
          'Se・B1は2倍目安で補充し複合traceは継続、血中濃度をモニタ(蓄積でなく欠乏側)。',
    ),
    ConditionDef(
      id: 'gi_loss',
      label: '高排出消化管瘻・大量下痢',
      suggestion: 'Zn喪失大。腸液+12mg/L・便/ストマ+17mg/Lを上乗せ。Mg/K/Na・水分も補正。',
    ),
    ConditionDef(
      id: 'alcohol',
      label: 'アルコール多飲・低栄養',
      suggestion: 'ビタミンB1欠乏のハイリスク。糖負荷の前〜同時にチアミン100–300mgを投与し'
          'Wernicke脳症・乳酸アシドーシスを予防。Refeedingにも注意。',
    ),
  ];

  static ConditionDef? byId(String id) =>
      all.where((c) => c.id == id).firstOrNull;

  static String labelOf(String id) => byId(id)?.label ?? id;
}

class Product {
  Product({
    required this.id,
    required this.category,
    required this.name,
    required this.content,
    required this.productType,
    required this.volumeMl,
    required this.kcal,
    required this.aminoAcidG,
    required this.nitrogenG,
    required this.npcNRatio,
    required this.fatBase,
    required this.carbBase,
    required this.notes,
    this.micro,
    this.alsoEn = false,
    this.addType,
    this.conditionTags = const [],
  });

  final String id;
  String category; // EN / EN_AUX / TPN / PPN (mutable for master edit)
  String name; // mutable for future name editing
  String content; // 性状(成分/消化態/半消化態 など)
  String productType; // 食品 / 医薬品
  double? volumeMl;
  double? kcal;
  double? aminoAcidG;
  double? nitrogenG;
  double? npcNRatio;
  double? fatBase;
  double? carbBase;
  String? notes;
  // 微量栄養素(1袋あたり): {elec:{Na,K,Cl,Ca,Mg,P}, trace:{Zn,Fe,Mn,Cu,I,Se}, vit:{...}}
  // elec: Na/K/Cl/Ca/Mg=mEq, P=mmol / trace=μmol / vit=各単位
  Map<String, dynamic>? micro;
  // 両用フラグ: trueなら「食事」カテゴリの製剤をENマスタにも表示（同一製剤として採用共有）
  bool alsoEn;
  // 加注製剤の種別 (電解質:Na/K/Ca/Mg/P/HCO3, 微量元素:総合/Zn/Se, ビタミン:総合/B群/単独)
  String? addType;
  // 病態タグ (病態別製剤): ConditionCatalog の id 群 (renal/dialysis/liver/diabetes/respiratory/immune/heart)
  List<String> conditionTags;

  /// この製剤を「食事」タブに表示するか（濃厚流動食 or 栄養サポート食品）
  bool get isFood =>
      category == '濃厚流動食' || category == '栄養サポート食品';

  /// 「食事」タブ内のサブセクション名（濃厚流動食 / 栄養サポート食品）
  String? get foodClass => isFood ? category : null;

  /// ENマスタ（タブ）に表示するか（EN本体/補助 or 両用food）
  bool get inEnTab => category == 'EN' || category == 'EN_AUX' || alsoEn;

  // ── 組成判定（MVI/trace 自動付替え用。micro由来）──
  /// 複合微量元素（Zn+Cu を含む＝多元素）を内蔵するか
  bool get kitHasFullTrace {
    final tr = micro?['trace'];
    return tr is Map && tr.containsKey('Zn') && tr.containsKey('Cu');
  }

  /// 総合ビタミン（B1 or A を含む）を内蔵するか
  bool get kitHasVitamins {
    final v = micro?['vit'];
    return v is Map && (v.containsKey('B1') || v.containsKey('A'));
  }

  /// 含有Mn量（μmol）
  double get mnAmount {
    final tr = micro?['trace'];
    if (tr is! Map) return 0;
    final m = tr['Mn'];
    return m is num ? m.toDouble() : 0;
  }

  /// 複合微量元素製剤か（加注用）
  bool get isCombinedTrace => category == '微量元素' && kitHasFullTrace;

  /// Mn-free 複合微量元素製剤か
  bool get isMnFreeTrace => isCombinedTrace && mnAmount <= 0;

  /// 総合ビタミン製剤か（加注用）
  bool get isFullMvi => category == 'ビタミン' && kitHasVitamins;

  /// カテゴリ表示名（EN_AUXは「EN補助」と表示）
  String get categoryLabel {
    switch (category) {
      case 'EN_AUX':
        return 'EN補助';
      default:
        return category;
    }
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    double? toDouble(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return Product(
      id: map['id'] as String,
      category: map['category'] as String,
      name: map['name'] as String,
      content: (map['content'] ?? '') as String,
      productType: (map['product_type'] ?? '食品') as String,
      volumeMl: toDouble(map['volume_ml']),
      kcal: toDouble(map['kcal']),
      aminoAcidG: toDouble(map['amino_acid_g']),
      nitrogenG: toDouble(map['nitrogen_g']),
      npcNRatio: toDouble(map['npc_n_ratio']),
      fatBase: toDouble(map['fat_g_or_kcal_basis']),
      carbBase: toDouble(map['carb_g_or_kcal_basis']),
      notes: map['notes'] as String?,
      micro: (map['micro'] as Map?)?.cast<String, dynamic>(),
      alsoEn: (map['also_en'] as bool?) ?? false,
      addType: map['add_type'] as String?,
      conditionTags: (map['condition_tags'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'category': category,
        'name': name,
        'content': content,
        'product_type': productType,
        'volume_ml': volumeMl,
        'kcal': kcal,
        'amino_acid_g': aminoAcidG,
        'nitrogen_g': nitrogenG,
        'npc_n_ratio': npcNRatio,
        'fat_g_or_kcal_basis': fatBase,
        'carb_g_or_kcal_basis': carbBase,
        'notes': notes,
        'micro': micro,
        if (alsoEn) 'also_en': true,
        if (addType != null) 'add_type': addType,
        if (conditionTags.isNotEmpty) 'condition_tags': conditionTags,
      };

  String get volumeMlString => volumeMl == null
      ? '-'
      : '${volumeMl!.toStringAsFixed(volumeMl! % 1 == 0 ? 0 : 1)} ml';
  String get kcalString => kcal == null
      ? '-'
      : '${kcal!.toStringAsFixed(kcal! % 1 == 0 ? 0 : 1)} kcal';
  String get aminoString =>
      aminoAcidG == null ? '-' : 'AA ${aminoAcidG!.toStringAsFixed(1)} g';
}

class RegimenItem {
  RegimenItem({
    required this.productId,
    required this.units,
    this.morning = 0,
    this.noon = 0,
    this.evening = 0,
    this.partialMl = 0,
  });
  final String productId;
  int units;
  int morning;
  int noon;
  int evening;
  // TPN/PPN: 本数(units)に上乗せする部分使用量(ml, 100ml単位)。実投与量=units×bagVol+partialMl。
  int partialMl;

  bool get hasMealTiming => morning > 0 || noon > 0 || evening > 0;

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'units': units,
        'morning': morning,
        'noon': noon,
        'evening': evening,
        'partialMl': partialMl,
      };
  factory RegimenItem.fromMap(Map<String, dynamic> map) => RegimenItem(
        productId: map['productId'] as String,
        units: map['units'] as int,
        morning: (map['morning'] as int?) ?? 0,
        noon: (map['noon'] as int?) ?? 0,
        evening: (map['evening'] as int?) ?? 0,
        partialMl: (map['partialMl'] as int?) ?? 0,
      );
}

class BedAssignment {
  BedAssignment(
      {required this.changedAt,
      required this.fromBed,
      required this.toBed,
      required this.note});
  String changedAt;
  final String? fromBed;
  final String toBed;
  final String note;

  Map<String, dynamic> toMap() => {
        'changedAt': changedAt,
        'fromBed': fromBed,
        'toBed': toBed,
        'note': note
      };
  factory BedAssignment.fromMap(Map<String, dynamic> map) => BedAssignment(
        changedAt: map['changedAt'] as String,
        fromBed: map['fromBed'] as String?,
        toBed: map['toBed'] as String,
        note: (map['note'] ?? '') as String,
      );
}

class ZeroMenuConfig {
  ZeroMenuConfig(
      {required this.targetKcal,
      required this.npcNRatio,
      required this.lipidGramPerKg,
      required this.glucoseProductName});
  final double targetKcal;
  final double npcNRatio;
  final double lipidGramPerKg;
  final String glucoseProductName;

  factory ZeroMenuConfig.defaultConfig() => ZeroMenuConfig(
      targetKcal: 1500,
      npcNRatio: 125,
      lipidGramPerKg: 0.4,
      glucoseProductName: '70% グルコース');

  Map<String, dynamic> toMap() => {
        'targetKcal': targetKcal,
        'npcNRatio': npcNRatio,
        'lipidGramPerKg': lipidGramPerKg,
        'glucoseProductName': glucoseProductName,
      };

  factory ZeroMenuConfig.fromMap(Map<String, dynamic> map) => ZeroMenuConfig(
        targetKcal: (map['targetKcal'] as num).toDouble(),
        npcNRatio: (map['npcNRatio'] as num).toDouble(),
        lipidGramPerKg: (map['lipidGramPerKg'] as num).toDouble(),
        glucoseProductName: map['glucoseProductName'] as String,
      );
}

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
    List<String>? conditionTags,
  }) : conditionTags = conditionTags ?? [];

  final String id;
  String caseCode;
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
        return known.contains(oldId) ? oldId! : 'five_day';
    }
  }

  String get sexLabel => sex == Sex.male ? 'M' : 'F';

  String get patientInfoLine =>
      '${age}歳, $sexLabel, ${heightCm.toStringAsFixed(0)}cm, ${weightKg.toStringAsFixed(1)}kg, BMI ${NutritionCalculator.bmi(this).toStringAsFixed(1)}';

  Map<String, dynamic> toMap() => {
        'id': id,
        'caseCode': caseCode,
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
        'energyModel': energyModel,
        'kcalPerKgValue': kcalPerKgValue,
        'measuredREE': measuredREE,
      };

  factory PatientCase.fromMap(Map<String, dynamic> map) => PatientCase(
        id: map['id'] as String,
        caseCode: map['caseCode'] as String,
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
        energyModel: (map['energyModel'] as String?) ?? 'harrisBenedict',
        kcalPerKgValue: (map['kcalPerKgValue'] as num?)?.toDouble(),
        measuredREE: (map['measuredREE'] as num?)?.toDouble(),
      )..fastingDate = map['fastingDate'] as String?;
}

class ProtocolTemplate {
  const ProtocolTemplate(
      {required this.id,
      required this.name,
      required this.percentages,
      required this.description});
  final String id;
  final String name;
  final List<double> percentages;
  final String description;
}

class AggregateResult {
  const AggregateResult({
    required this.totalVolumeMl,
    required this.totalKcal,
    required this.totalProteinG,
    required this.totalFatG,
    required this.fatKcal,
    required this.carbKcal,
    required this.proteinKcal,
  });

  final double totalVolumeMl;
  final double totalKcal;
  final double totalProteinG;
  final double totalFatG;
  final double fatKcal;
  final double carbKcal;
  final double proteinKcal;

  double targetPercent(double targetKcal) =>
      targetKcal == 0 ? 0 : (totalKcal / targetKcal) * 100;
  double get totalMacroKcal => fatKcal + carbKcal + proteinKcal;
  double get fatPercent =>
      totalMacroKcal == 0 ? 0 : fatKcal / totalMacroKcal * 100;
  double get carbPercent =>
      totalMacroKcal == 0 ? 0 : carbKcal / totalMacroKcal * 100;
  double get proteinPercent =>
      totalMacroKcal == 0 ? 0 : proteinKcal / totalMacroKcal * 100;
  String get npcNText {
    if (totalProteinG <= 0) return '-';
    final n = totalProteinG / 6.25;
    if (n == 0) return '-';
    final value = (totalKcal - totalProteinG * 4) / n;
    if (value.isNaN || value.isInfinite) return '-';
    return value.round().toString();
  }
}

class ZeroMenuSuggestion {
  const ZeroMenuSuggestion({
    required this.aminoVolumeMl,
    required this.glucoseVolumeMl,
    required this.lipidVolumeMl,
    required this.proteinGram,
    required this.lipidGram,
  });

  final double aminoVolumeMl;
  final double glucoseVolumeMl;
  final double lipidVolumeMl;
  final double proteinGram;
  final double lipidGram;
}

/// 自動設計の1製剤分（本数 or 静注ml）
class DesignItem {
  DesignItem({
    required this.name,
    this.units,
    required this.volumeMl,
    required this.kcal,
    required this.proteinG,
  });
  final String name;
  final int? units; // 本数(pac/本)。静注mlベースのときはnull
  final double volumeMl; // 1日総量ml
  final double kcal;
  final double proteinG;
  double get ratePerHour => volumeMl / 24; // 24h持続換算
}

/// 自動設計の1案（複数製剤の組み合わせ）
class DesignPlan {
  DesignPlan({required this.label, required this.items, this.enKcal = 0});
  final String label; // 'EN案' / 'TPN案' / 'ゼロmenu案'
  final List<DesignItem> items;
  final double enKcal; // EN由来kcal（designDayが設定、単調増加管理用）
  double get totalKcal => items.fold(0.0, (s, i) => s + i.kcal);
  double get totalProteinG => items.fold(0.0, (s, i) => s + i.proteinG);
  double get totalVolumeMl => items.fold(0.0, (s, i) => s + i.volumeMl);
}

class NutritionCalculator {
  static double bmi(PatientCase item) =>
      item.weightKg / ((item.heightCm / 100) * (item.heightCm / 100));

  /// 目標エネルギー（kcal/day）。選択モデル＋補正体重を内部適用（clinical/energy.dart に委譲）。
  static ce.EnergyResult targetEnergyResult(PatientCase item) => ce.targetEnergy(
        model: ce.energyModelFromId(item.energyModel),
        isMale: item.sex == Sex.male,
        weightKg: item.weightKg,
        heightCm: item.heightCm,
        age: item.age,
        activityFactor: item.activityFactor,
        stressFactor: item.stressFactor,
        kcalPerKgValue: item.kcalPerKgValue ?? 30,
        measuredREE: item.measuredREE,
      );

  static double targetEnergy(PatientCase item) =>
      targetEnergyResult(item).kcal;

  /// 目標タンパク（g/day）。肥満は理想体重基準（clinical/protein.dart に委譲）。
  static double targetProtein(PatientCase item) => cp.targetProtein(
        actualKg: item.weightKg,
        heightCm: item.heightCm,
        isMale: item.sex == Sex.male,
        gramPerKg: item.proteinGoalPerKg,
      );

  static AggregateResult aggregate(List<RegimenItem> items) {
    double totalVolumeMl = 0;
    double totalKcal = 0;
    double totalProteinG = 0;
    double totalFatG = 0;
    double fatKcal = 0;
    double carbKcal = 0;
    double proteinKcal = 0;
    for (final item in items) {
      final product = ProductCatalog.instance.byId(item.productId);
      if (product == null || item.units <= 0) continue;
      totalVolumeMl += (product.volumeMl ?? 0) * item.units;
      totalKcal += (product.kcal ?? 0) * item.units;
      totalProteinG += (product.aminoAcidG ?? 0) * item.units;
      totalFatG += (product.fatBase ?? 0) * item.units;
      fatKcal += (product.fatBase ?? 0) * 9 * item.units;
      carbKcal += (product.carbBase ?? 0) * 4 * item.units;
      proteinKcal += (product.aminoAcidG ?? 0) * 4 * item.units;
    }
    return AggregateResult(
      totalVolumeMl: totalVolumeMl,
      totalKcal: totalKcal,
      totalProteinG: totalProteinG,
      totalFatG: totalFatG,
      fatKcal: fatKcal,
      carbKcal: carbKcal,
      proteinKcal: proteinKcal,
    );
  }

  static ZeroMenuSuggestion zeroMenuSuggestion({
    required double targetKcal,
    required double npcNRatio,
    required double lipidGramPerKg,
    required double weightKg,
    required Product? glucoseProduct,
    required Product? aminoProduct,
    required Product? lipidProduct,
    double? girLimitMgKgMin, // 指定時: GIR上限でブドウ糖をcapし余剰kcalを脂質へ再配分(自動設計用)
    double? maxLipidGramPerKgDay, // 脂質再配分の上限(g/kg/day)
  }) {
    final aminoMlPerGram = (aminoProduct?.volumeMl ?? 500) /
        ((aminoProduct?.aminoAcidG ?? 50) == 0
            ? 50
            : (aminoProduct?.aminoAcidG ?? 50));
    final proteinGram = (6.25 * targetKcal) / (npcNRatio + 6.25 * 4);
    final aminoVolumeMl = proteinGram * aminoMlPerGram;
    double lipidGram = lipidGramPerKg * weightKg;
    double glucoseKcal = (targetKcal - proteinGram * 4 - lipidGram * 9)
        .clamp(0, double.infinity)
        .toDouble();
    // GIR上限でブドウ糖を制限し、余剰kcalを脂質へ再配分（自動設計でのみ有効）
    if (girLimitMgKgMin != null && weightKg > 0) {
      final maxGluGram = girLimitMgKgMin * weightKg * 1440 / 1000;
      double glucoseGram = glucoseKcal / 4;
      if (glucoseGram > maxGluGram) {
        final deficitKcal = (glucoseGram - maxGluGram) * 4;
        glucoseGram = maxGluGram;
        glucoseKcal = glucoseGram * 4;
        if (maxLipidGramPerKgDay != null) {
          final maxLipidGram = maxLipidGramPerKgDay * weightKg;
          final addable = maxLipidGram - lipidGram;
          if (addable > 0) {
            final extra = deficitKcal / 9;
            lipidGram += extra < addable ? extra : addable;
          }
        }
      }
    }
    final lipidVolumeMl = lipidProduct == null
        ? 0.0
        : lipidGram /
            ((lipidProduct.fatBase ?? 20) / (lipidProduct.volumeMl ?? 100));
    final glucoseDensity =
        glucoseProduct == null || (glucoseProduct.volumeMl ?? 0) == 0
            ? 1
            : (glucoseProduct.kcal ?? 0) / (glucoseProduct.volumeMl ?? 1);
    final glucoseVolumeMl =
        glucoseDensity == 0 ? 0.0 : glucoseKcal / glucoseDensity;
    return ZeroMenuSuggestion(
      aminoVolumeMl: aminoVolumeMl,
      glucoseVolumeMl: glucoseVolumeMl,
      lipidVolumeMl: lipidVolumeMl,
      proteinGram: proteinGram,
      lipidGram: lipidGram,
    );
  }

  /// 自動設計。
  /// ルール: カロリーは目標の90〜100%(オーバー不可)、タンパクは90〜100%(オーバー不可)。
  /// mode: 'EN'(EN最大2剤+PPN補正) / 'TPN'(TPN単剤+PPN補正) / 'BOTH'(両案) / 'ZERO'(静注ブレンド)
  static List<DesignPlan> autoDesign({
    required String mode,
    required double targetKcal,
    required double targetProtein,
    required double weightKg,
    required List<Product> enProducts,
    required List<Product> tpnProducts,
    required List<Product> ppnProducts,
    Product? glucoseProduct,
    Product? aminoProduct,
    Product? lipidProduct,
  }) {
    final plans = <DesignPlan>[];
    if (mode == 'EN' || mode == 'BOTH') {
      final p = _designWithBase(
          enProducts, ppnProducts, targetKcal, targetProtein, 'EN案',
          maxBase: 2);
      if (p != null) plans.add(p);
    }
    if (mode == 'TPN' || mode == 'BOTH') {
      final p = _designWithBase(
          tpnProducts, ppnProducts, targetKcal, targetProtein, 'TPN案',
          maxBase: 1);
      if (p != null) plans.add(p);
    }
    if (mode == 'ZERO') {
      final z = zeroMenuSuggestion(
        targetKcal: targetKcal,
        npcNRatio: 125,
        lipidGramPerKg: 0.4,
        weightKg: weightKg,
        glucoseProduct: glucoseProduct,
        aminoProduct: aminoProduct,
        lipidProduct: lipidProduct,
      );
      final items = <DesignItem>[];
      double densKcal(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.kcal ?? 0) * ml / p.volumeMl!;
      double densProt(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.aminoAcidG ?? 0) * ml / p.volumeMl!;
      if (aminoProduct != null && z.aminoVolumeMl > 0) {
        items.add(DesignItem(
            name: aminoProduct.name,
            volumeMl: z.aminoVolumeMl,
            kcal: densKcal(aminoProduct, z.aminoVolumeMl),
            proteinG: densProt(aminoProduct, z.aminoVolumeMl)));
      }
      if (glucoseProduct != null && z.glucoseVolumeMl > 0) {
        items.add(DesignItem(
            name: glucoseProduct.name,
            volumeMl: z.glucoseVolumeMl,
            kcal: densKcal(glucoseProduct, z.glucoseVolumeMl),
            proteinG: 0));
      }
      if (lipidProduct != null && z.lipidVolumeMl > 0) {
        items.add(DesignItem(
            name: lipidProduct.name,
            volumeMl: z.lipidVolumeMl,
            kcal: z.lipidGram * 9,
            proteinG: 0));
      }
      plans.add(DesignPlan(label: 'ゼロmenu案', items: items));
    }
    return plans;
  }

  /// 主軸製剤(base)を maxBase 剤まで使い、PPNでタンパク補正する設計を1案返す。
  static DesignPlan? _designWithBase(List<Product> bases, List<Product> ppns,
      double targetKcal, double targetProtein, String label,
      {required int maxBase}) {
    final minKcal = targetKcal * 0.9;
    List<MapEntry<Product, int>>? best;
    double bestIn = double.infinity;

    void consider(List<MapEntry<Product, int>> combo) {
      double kcal = 0, prot = 0, inMl = 0;
      for (final e in combo) {
        kcal += (e.key.kcal ?? 0) * e.value;
        prot += (e.key.aminoAcidG ?? 0) * e.value;
        inMl += (e.key.volumeMl ?? 0) * e.value;
      }
      if (kcal > targetKcal) return; // カロリーオーバー不可
      if (kcal < minKcal) return; // -10%未満は不採用
      if (prot > targetProtein) return; // タンパクオーバー不可
      // カロリー条件を満たす中で IN(投与量) 最小を採用
      if (inMl < bestIn) {
        bestIn = inMl;
        best = combo;
      }
    }

    final valid = bases.where((b) => (b.kcal ?? 0) > 0).toList();
    // 単剤
    for (final b in valid) {
      final k = b.kcal!;
      for (int n = 1; n * k <= targetKcal; n++) {
        consider([MapEntry(b, n)]);
      }
    }
    // 2剤
    if (maxBase >= 2) {
      for (int i = 0; i < valid.length; i++) {
        for (int j = i + 1; j < valid.length; j++) {
          final a = valid[i], c = valid[j];
          for (int n1 = 1; n1 * a.kcal! <= targetKcal; n1++) {
            for (int n2 = 1; n1 * a.kcal! + n2 * c.kcal! <= targetKcal; n2++) {
              consider([MapEntry(a, n1), MapEntry(c, n2)]);
            }
          }
        }
      }
    }

    if (best == null) return null;

    final items = best!
        .map((e) => DesignItem(
              name: e.key.name,
              units: e.value,
              volumeMl: (e.key.volumeMl ?? 0) * e.value,
              kcal: (e.key.kcal ?? 0) * e.value,
              proteinG: (e.key.aminoAcidG ?? 0) * e.value,
            ))
        .toList();

    // タンパク補正: 達成タンパクが目標の90%未満ならPPNアミノ酸を追加
    double curKcal = items.fold(0.0, (s, i) => s + i.kcal);
    double curProt = items.fold(0.0, (s, i) => s + i.proteinG);
    if (curProt < targetProtein * 0.9) {
      final aminos = ppns.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
        ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
            .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
      if (aminos.isNotEmpty) {
        final pp = aminos.first;
        int add = 0;
        while (curProt < targetProtein * 0.9 &&
            curProt + (pp.aminoAcidG ?? 0) <= targetProtein &&
            curKcal + (pp.kcal ?? 0) <= targetKcal) {
          curProt += pp.aminoAcidG ?? 0;
          curKcal += pp.kcal ?? 0;
          add++;
        }
        if (add > 0) {
          items.add(DesignItem(
              name: pp.name,
              units: add,
              volumeMl: (pp.volumeMl ?? 0) * add,
              kcal: (pp.kcal ?? 0) * add,
              proteinG: (pp.aminoAcidG ?? 0) * add));
        }
      }
    }

    return DesignPlan(label: label, items: items);
  }

  /// Day別設計: そのDayの目標(kcal/タンパク)を、選んだクラスとEN速度でサジェスト。
  /// mode: 'TPN' / 'TPN+EN' / 'EN' / 'ZERO'
  static DesignPlan designDay({
    required String mode,
    required double dayTargetKcal,
    required double dayTargetProt,
    required double weightKg,
    required List<Product> enProducts,
    double enRateMlH = 0,
    int enPac = 0,
    Product? pnProduct,
    double pnRateMlH = 0,
    required List<Product> tpnProducts,
    required List<Product> ppnProducts,
    Product? glucoseProduct,
    Product? aminoProduct,
    Product? lipidProduct,
    double minEnKcal = 0, // 単調増加制約: 前日のEN kcal以上を要求
    List<Product> mealProducts = const [], // 食事(濃厚流動食/栄養サポート)
    int mealPac = 0, // 食事 朝昼夕あたりpac数(1..3, 経口リハ期に使用)
    double? girLimitMgKgMin, // 自動設計: GIR上限(糖質制限病態は4, 既定5)
    double? maxLipidGramPerKgDay, // 脂質再配分の上限
    bool allowZeroMenu = false, // ゼロmenu許可(PNのみ7日目以降・EN未開始時のみtrue)
  }) {
    // ゼロmenu(静注ブレンド)のitem群を構築
    List<DesignItem> buildZeroItems(double tKcal) {
      final items = <DesignItem>[];
      final z = zeroMenuSuggestion(
        targetKcal: tKcal,
        npcNRatio: 125,
        lipidGramPerKg: 0.4,
        weightKg: weightKg,
        glucoseProduct: glucoseProduct,
        aminoProduct: aminoProduct,
        lipidProduct: lipidProduct,
        girLimitMgKgMin: girLimitMgKgMin,
        maxLipidGramPerKgDay: maxLipidGramPerKgDay,
      );
      double dKcal(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.kcal ?? 0) * ml / p.volumeMl!;
      double dProt(Product? p, double ml) =>
          p == null || (p.volumeMl ?? 0) == 0 ? 0 : (p.aminoAcidG ?? 0) * ml / p.volumeMl!;
      if (aminoProduct != null && z.aminoVolumeMl > 0) {
        items.add(DesignItem(name: aminoProduct.name, volumeMl: z.aminoVolumeMl, kcal: dKcal(aminoProduct, z.aminoVolumeMl), proteinG: dProt(aminoProduct, z.aminoVolumeMl)));
      }
      if (glucoseProduct != null && z.glucoseVolumeMl > 0) {
        items.add(DesignItem(name: glucoseProduct.name, volumeMl: z.glucoseVolumeMl, kcal: dKcal(glucoseProduct, z.glucoseVolumeMl), proteinG: 0));
      }
      if (lipidProduct != null && z.lipidVolumeMl > 0) {
        items.add(DesignItem(name: lipidProduct.name, volumeMl: z.lipidVolumeMl, kcal: z.lipidGram * 9, proteinG: 0));
      }
      items.add(DesignItem(name: 'ビタミン製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      items.add(DesignItem(name: '微量元素製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      items.add(DesignItem(name: '電解質製剤', volumeMl: 2, kcal: 0, proteinG: 0));
      return items;
    }

    // ZERO: 静注ブレンド（EN不要）
    if (mode == 'ZERO') {
      return DesignPlan(label: 'Day', items: buildZeroItems(dayTargetKcal));
    }

    // タンパク不足を高濃度AA製剤で補正してitemsに追加するヘルパー。
    //   AAが目標未満なら、高濃度AA(aminoProduct=純AA, アミパレンfallback)で
    //   「目標まで一旦全部埋める」。INやkcalが多少増えてもタンパクを優先する。
    void addPpnProtein(List<DesignItem> items, double curKcal, double curProt) {
      if (curProt >= dayTargetProt) return;
      // 高濃度AA製剤: 純AA(aminoProduct) > 採用PPNの最高AA密度。
      Product? aa = (aminoProduct != null && (aminoProduct.aminoAcidG ?? 0) > 0)
          ? aminoProduct
          : null;
      if (aa == null) {
        final aminos = ppnProducts.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
          ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
              .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
        aa = aminos.isNotEmpty ? aminos.first : null;
      }
      final aaG = aa?.aminoAcidG ?? 0;
      if (aa == null || aaG <= 0) return;
      // 不足分を満たす最小本数(端数切り上げ=目標到達優先)。安全上限20本。
      final add = ((dayTargetProt - curProt) / aaG).ceil().clamp(1, 20);
      items.add(DesignItem(
          name: aa.name,
          units: add,
          volumeMl: (aa.volumeMl ?? 0) * add,
          kcal: (aa.kcal ?? 0) * add,
          proteinG: aaG * add));
    }

    // 食事(経口リハ): 食事製剤を朝昼夕 mealPac本ずつ(=計3×mealPac本)投与。
    //   ただしkcalが当日目標を超えない範囲にcap。不足分(kcal・タンパク)はPPNで補う。
    if (mode == '食事') {
      final meals = mealProducts
          .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
          .toList();
      final items = <DesignItem>[];
      double mealKcal = 0, mealProt = 0;
      if (meals.isNotEmpty && mealPac > 0) {
        // 主食 = kcal/pacが最大の食事製剤(高栄養の濃厚流動食)を一貫採用
        final sorted = [...meals]
          ..sort((a, b) => (b.kcal ?? 0).compareTo(a.kcal ?? 0));
        final p = sorted.first;
        final pk = (p.kcal ?? 0).toDouble();
        if (pk > 0) {
          final capPac = 3 * mealPac; // 朝昼夕 × pac数(1→3で漸増)
          // kcalが当日目標を超えない範囲にcap
          final byKcal = (dayTargetKcal / pk).floor();
          final pac = (capPac < byKcal ? capPac : byKcal).clamp(0, capPac);
          if (pac > 0) {
            mealKcal = pk * pac;
            mealProt = (p.aminoAcidG ?? 0) * pac;
            items.add(DesignItem(
                name: p.name,
                units: pac,
                volumeMl: (p.volumeMl ?? 0) * pac,
                kcal: mealKcal,
                proteinG: mealProt));
          }
        }
      }
      // 不足分(kcal・タンパク)をPPN製剤で補う
      final restKcal =
          (dayTargetKcal - mealKcal).clamp(0, double.infinity).toDouble();
      final restProt =
          (dayTargetProt - mealProt).clamp(0, double.infinity).toDouble();
      if (restKcal > 80 && ppnProducts.isNotEmpty) {
        final sub = _designWithBase(
            ppnProducts, ppnProducts, restKcal, restProt, 'PPN',
            maxBase: 2);
        if (sub != null) items.addAll(sub.items);
      }
      // 経口リハ期はタンパクが落ち込みやすい(エルネオパ等のPN中止+食事は低タンパク)。
      // → 高濃度AA製剤で「目標タンパクまで」確実に補充する(kcal超過は許容しタンパク優先)。
      //   AA源は ゼロmenuと同じ純AA製剤(aminoProduct, アミパレンfallback)を最優先。
      //   PPN未採用の施設(エルネオパ中心)でも補充が効くようにする。
      {
        final curProt = items.fold(0.0, (s, it) => s + it.proteinG);
        // 高濃度AA製剤の選定: 純AA(aminoProduct) > 採用PPNの最高AA密度。
        Product? aa = (aminoProduct != null && (aminoProduct.aminoAcidG ?? 0) > 0)
            ? aminoProduct
            : null;
        if (aa == null) {
          final aminos =
              ppnProducts.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
                ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
                    .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
          aa = aminos.isNotEmpty ? aminos.first : null;
        }
        final aaG = aa?.aminoAcidG ?? 0;
        if (aa != null && aaG > 0 && curProt < dayTargetProt) {
          // 不足分を満たす最小本数(端数切り上げ=目標到達優先)。安全上限20本。
          final add = ((dayTargetProt - curProt) / aaG).ceil().clamp(1, 20);
          items.add(DesignItem(
              name: aa.name,
              units: add,
              volumeMl: (aa.volumeMl ?? 0) * add,
              kcal: (aa.kcal ?? 0) * add,
              proteinG: aaG * add));
        }
      }
      return DesignPlan(label: 'Day', items: items);
    }

    // EN baseのitem群＋PN主剤(pnBase)を渡して、PN自動減量＋PPN補正で1日プランを完成
    DesignPlan completePlan(List<DesignItem> enItems, Product? pnBase) {
      final items = <DesignItem>[...enItems];
      final enKcal = enItems.fold<double>(0, (s, it) => s + it.kcal);
      final enProt = enItems.fold<double>(0, (s, it) => s + it.proteinG);
      if (mode == 'EN') {
        addPpnProtein(items, enKcal, enProt);
        return DesignPlan(label: 'Day', items: items);
      }
      // PN自動減量: 残りkcalをPNで埋める(over回避)
      final restKcal =
          (dayTargetKcal - enKcal).clamp(0, double.infinity).toDouble();
      final restProt =
          (dayTargetProt - enProt).clamp(0, double.infinity).toDouble();
      if (pnBase != null && (pnBase.volumeMl ?? 0) > 0 && restKcal > 0) {
        final bagVol = pnBase.volumeMl!; // 1袋の容量ml
        final bagKcal = pnBase.kcal ?? 0; // 1袋のkcal
        final pnDensity = bagVol > 0 ? bagKcal / bagVol : 0.0; // kcal/ml
        // 袋数調整: under feeding許容 + INの段差を緩和するため、端数が≥50%なら開封OK
        //   ≤1袋分 → 速度調整で部分使用(目標ちょうど)
        //   >1袋分 → 整数袋 + 端数が袋容量の50%以上なら+1袋(部分使用)、未満は切り捨て
        const fracThreshold = 0.50; // 端数50%以上なら開封
        double pnMl = 0;
        int? pnUnits;
        if (pnDensity > 0) {
          if (restKcal <= bagKcal) {
            pnMl = restKcal / pnDensity;
            if ((bagVol - pnMl).abs() < 1.0) {
              pnMl = bagVol;
              pnUnits = 1;
            }
          } else {
            final wholeBags = (restKcal / bagKcal).floor();
            final fracKcal = restKcal - wholeBags * bagKcal;
            if (fracKcal / bagKcal >= fracThreshold) {
              // 端数袋を開封(部分使用)
              pnMl = wholeBags * bagVol + fracKcal / pnDensity;
              pnUnits = wholeBags + 1;
            } else {
              // 端数は切り捨て
              pnMl = wholeBags * bagVol;
              pnUnits = wholeBags;
            }
          }
        }
        // TPN(PN主剤)の使用量を100ml単位に丸める。
        // 過剰栄養は禁忌のため、丸めで残りkcalを超える場合は100ml切り下げる。
        if (pnMl > 0 && pnDensity > 0) {
          double rounded = (pnMl / 100).round() * 100.0;
          while (rounded > 0 && pnDensity * rounded > restKcal + 1e-6) {
            rounded -= 100;
          }
          pnMl = rounded;
          pnUnits = pnMl > 0 ? (pnMl / bagVol).ceil() : null;
        }
        final pnKcal = pnDensity * pnMl;
        final pnProt = (pnBase.aminoAcidG ?? 0) * pnMl / bagVol;
        if (pnMl > 0) {
          items.add(DesignItem(
              name: pnBase.name,
              units: pnUnits,
              volumeMl: pnMl,
              kcal: pnKcal,
              proteinG: pnProt));
        }
        addPpnProtein(items, enKcal + pnKcal, enProt + pnProt);
        return DesignPlan(label: 'Day', items: items);
      }
      // PN主剤なし: 残りをTPN単剤+PPNで本数最適
      if (restKcal > 0) {
        final sub = _designWithBase(
            tpnProducts, ppnProducts, restKcal, restProt, 'TPN', maxBase: 1);
        if (sub != null) items.addAll(sub.items);
      }
      return DesignPlan(label: 'Day', items: items);
    }

    // EN製剤を pac本 のitemに
    DesignItem enPacItem(Product p, int pac) {
      final double vol = pac * (p.volumeMl ?? 0.0);
      return DesignItem(
          name: p.name,
          units: pac,
          volumeMl: vol,
          kcal: (p.kcal ?? 0) * vol / (p.volumeMl ?? 1),
          proteinG: (p.aminoAcidG ?? 0) * vol / (p.volumeMl ?? 1));
    }

    // EN製剤名の集合(輸液=経静脈分の容量を切り分けるために使用)
    final enNameSet = enProducts.map((p) => p.name).toSet();
    // 評価(under feeding基準): kcalは当日目標の90-100%、タンパク90-100%、
    //   over nutritionは厳禁、INは~1000ml/dayを確保したい。スコア小が良。
    //   planEnKcal: ENアイテム由来kcal（候補ループ側で計算して渡す）
    double scoreOf(DesignPlan plan, double planEnKcal) {
      final tK = dayTargetKcal, tP = dayTargetProt;
      final k = plan.totalKcal, pr = plan.totalProteinG, vol = plan.totalVolumeMl;
      double s = 0;
      if (tK > 0) {
        final r = k / tK;
        if (r > 1.0) {
          s += (r - 1.0) * 100; // over厳禁
        } else if (r < 0.9) {
          s += (0.9 - r) * 50; // 90%未満の下振れ
        } else {
          s += (1.0 - r) * 5; // 90-100%窓内は目標寄りを微優先
        }
      }
      if (tP > 0) {
        final r = pr / tP;
        if (r > 1.0) {
          s += (r - 1.0) * 80;
        } else if (r < 0.9) {
          s += (0.9 - r) * 40;
        } else {
          s += (1.0 - r) * 4;
        }
      }
      // IN ~1000ml/day確保。絞りすぎ回避＆2500ml超は強くペナルティ(ゼロmenu等へ誘導)
      if (vol < 1000) {
        s += (1000 - vol) / 1000 * 10;
      } else if (vol <= 2500) {
        s += (vol - 1000) / 1000 * 1;
      } else {
        s += 1.5 + (vol - 2500) / 1000 * 50;
      }
      // 輸液(経静脈)上限: 3000ml/day を超えないようハードキャップ。
      //   EN(経腸)分は含めず、PN/PPN/IV分のみで判定する。
      double ivVol = 0;
      for (final it in plan.items) {
        if (!enNameSet.contains(it.name)) ivVol += it.volumeMl;
      }
      if (ivVol > 3000) {
        // 実質的に3000ml超を回避(代替が無い場合のみ許容＝段階的劣化)
        s += 1000 + (ivVol - 3000) * 2;
      }
      // 単調増加制約: ENカロリーが前日より少ない場合は重くペナルティ
      if (minEnKcal > 0 && planEnKcal < minEnKcal * 0.98) {
        s += (minEnKcal - planEnKcal) / (tK + 1) * 80;
      }
      return s;
    }

    final ens = enProducts
        .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
        .toList();

    // EN候補(食単位で最大2製剤まで混合)を列挙。1食内は1製剤のみ。
    List<List<DesignItem>> enCandidates() {
      if (mode == 'TPN' || ens.isEmpty) return [<DesignItem>[]];
      if (enPac > 0) {
        // 朝昼夕の3食。食あたりpac数=mealPac。3食を最大2製剤に振り分け
        final mealPac = (enPac / 3).round().clamp(1, enPac);
        final out = <List<DesignItem>>[];
        for (var i = 0; i < ens.length; i++) {
          final prod = ens[i];
          final pacKcal = (prod.kcal ?? 0).toDouble();
          // 単調増加制約: minEnKcal を満たす最小pac数まで単剤候補を切り上げ
          // (連続投与→ボーラス切替時の凹みを防ぐ)
          int totalPacs = 3 * mealPac;
          if (minEnKcal > 0 && pacKcal > 0) {
            final needed = (minEnKcal / pacKcal).ceil();
            if (needed > totalPacs) {
              // 目標kcalを超えない範囲で増やす
              final hardMax = dayTargetKcal > 0
                  ? (dayTargetKcal / pacKcal).floor().clamp(totalPacs, 99)
                  : 99;
              totalPacs = needed.clamp(totalPacs, hardMax);
            }
          }
          out.add([enPacItem(prod, totalPacs)]); // 単剤(単調増加対応)
          for (var j = i + 1; j < ens.length; j++) {
            for (final a in const [1, 2]) {
              // a食をens[i]、(3-a)食をens[j] (食単位混合)
              out.add([
                enPacItem(ens[i], a * mealPac),
                enPacItem(ens[j], (3 - a) * mealPac),
              ]);
            }
          }
        }
        return out;
      }
      if (enRateMlH > 0) {
        // 速度(ml/h)は持続投与=単剤のみ
        final ml = enRateMlH * 24;
        return ens
            .map((p) => [
                  DesignItem(
                      name: p.name,
                      volumeMl: ml,
                      kcal: (p.kcal ?? 0) * ml / (p.volumeMl ?? 1),
                      proteinG: (p.aminoAcidG ?? 0) * ml / (p.volumeMl ?? 1)),
                ])
            .toList();
      }
      return [<DesignItem>[]];
    }

    // PN主剤候補: 導入プロトコルの 1号/2号(エルネオパ or ネオパレン)のみを使用。
    // どちらも未採用ならゼロmenuで構築する(他TPNは自動設計のPN主剤に使わない)。
    // マスタ名は末尾空白や容量サフィックス付きの場合があるため productBaseName で正規化して判定。
    bool isProtoBase(Product p) {
      final b = productBaseName(p.name);
      return b == 'エルネオパNF1号' ||
          b == 'エルネオパNF2号' ||
          b == 'ネオパレン1号' ||
          b == 'ネオパレン2号';
    }
    final pnBases = tpnProducts
        .where((p) =>
            isProtoBase(p) && (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
        .toList();

    DesignPlan? best;
    double bestScore = double.infinity;
    double bestEnKcal = 0; // 勝者のEN由来kcal
    void consider(DesignPlan plan, double planEnKcal) {
      final sc = scoreOf(plan, planEnKcal);
      if (sc < bestScore) {
        bestScore = sc;
        best = plan;
        bestEnKcal = planEnKcal;
      }
    }

    for (final enItems in enCandidates()) {
      // EN由来kcalをitemから集計（単調増加スコアリング用）
      final enKcal =
          enItems.fold<double>(0, (s, it) => s + it.kcal);
      if (mode == 'EN') {
        consider(completePlan(enItems, null), enKcal);
      } else if (pnBases.isEmpty) {
        consider(completePlan(enItems, null), enKcal);
      } else {
        // PN主剤の選定: エルネオパ1号→2号 の導入プロトコルを優先する。
        //   初期導入は1号、必要量が過大(>2000ml相当)になれば2号へ切替。
        //   エルネオパ未採用時は従来どおり IN/kcal 最適で選ぶ。
        for (final pb in pnBases) {
          final plan = completePlan(enItems, pb);
          double planScore = scoreOf(plan, enKcal);
          final bagVol = pb.volumeMl ?? 1;
          double pnVol = 0;
          for (final it in plan.items) {
            if (it.units == null && it.name == pb.name) {
              pnVol = it.volumeMl;
              final usageRatio = it.volumeMl / bagVol;
              if (usageRatio < 0.5) {
                // 50%未満の端数使用 → 別製剤があれば乗り換えを促す
                planScore += (0.5 - usageRatio) * 20;
              }
            }
          }
          // 導入プロトコル: 1号を強く優先。1号で必要量が過大なら2号を次点優先。
          final pbBase = productBaseName(pb.name);
          final is1go =
              pbBase == 'エルネオパNF1号' || pbBase == 'ネオパレン1号';
          final is2go =
              pbBase == 'エルネオパNF2号' || pbBase == 'ネオパレン2号';
          if (is1go) {
            // 1号は希釈。約3000ml(輸液上限)までは1号を優先、超えれば2号へ
            if (pnVol <= 3000) planScore -= 1000.0;
          } else if (is2go) {
            planScore -= 500.0;
          }
          if (planScore < bestScore) {
            bestScore = planScore;
            best = plan;
            bestEnKcal = enKcal;
          }
        }
      }
    }
    // ゼロmenu(高濃度静注ブレンド)の使用制限:
    //  ・エルネオパ/ネオパレン 1号/2号 が未採用の施設のみ(採用施設は1号→2号を使用)。
    //  ・PNのみの栄養が6日続いた翌日(7日目)以降のPN専用日のみ(allowZeroMenu)。
    //  ・ENを開始していれば採用しない(mode=='TPN'のPN専用日に限る)。
    if (allowZeroMenu && pnBases.isEmpty && mode == 'TPN') {
      consider(DesignPlan(label: 'ZERO', items: buildZeroItems(dayTargetKcal)), 0);
    }
    // 勝者のEN kcalをDesignPlanに記録して返す（逐次生成時の単調増加追跡に使用）
    if (best == null) return DesignPlan(label: 'Day', items: const []);
    return DesignPlan(label: best!.label, items: best!.items, enKcal: bestEnKcal);
  }
}

class ProductCatalog {
  ProductCatalog(this.products) {
    instance = this;
  }

  static late ProductCatalog instance;
  final List<Product> products;

  static Future<ProductCatalog> load() async {
    final raw = await rootBundle.loadString('assets/product_masters.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final items = (decoded['products'] as List)
        .map((e) => Product.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    return ProductCatalog(items);
  }

  List<Product> byCategory(String category) =>
      products.where((e) => e.category == category).toList();
  Product? byName(String name) {
    try {
      return products.firstWhere((e) => e.name == name);
    } catch (_) {
      return null;
    }
  }

  Product? byId(String id) {
    try {
      return products.firstWhere((e) => e.id == id);
    } catch (_) {
      return null;
    }
  }
}

class AppState {
  AppState(
      {required this.catalog,
      required this.store,
      required this.cases,
      required this.protocols,
      required this.selectedCaseId,
      required this.favoriteProductIds,
      required this.adoptedProductIds,
      required this.noteText});

  /// 初回起動時にデフォルトで採用済みにする製剤名（院内採用の標準セット）
  static const List<String> _defaultAdoptedNames = [
    // ── EN / 食事（再編後の名称に合わせる） ──
    'F2α(エフツーアルファ)', 'テルミール2.0α', 'グルセルナ-REX', 'リーナレンMP',
    'ヘパス', 'ペプチーノ', 'ペプタメン AF', 'ペプタメン スタンダード',
    'エネーボ', 'エレンタール', 'アミノレバン',
    // ── EN補助（6種すべて） ──
    'REF P1', 'GFO', 'サンファイバー', 'オルニュート', 'ブイ・クレスゼリー', '一挙千菜',
    // ── PPN 採用薬 ──
    'ビーフリード', 'アミパレン', 'キドミン',
    'イントラリポス20%', '8%グルコース', '5%グルコース',
    // ── TPN 採用薬 ──
    'エルネオパNF1号', 'エルネオパNF2号',
    'フルカリック1号', 'フルカリック2号', 'フルカリック3号',
    'ハイカリックRF', '70% グルコース',
    // ── 加注(電解質/微量元素/ビタミン) プリセット ──
    '1モル塩化ナトリウム注射液', 'KCL補正液1mEq/mL', 'カルチコール注射液8.5%',
    '硫酸Mg補正液 1mEq/mL', 'リン酸Na補正液 0.5mmol/mL', 'メイロン静注8.4%',
    'エレジェクト注シリンジ', '硫酸亜鉛', 'アセレンド注 (セレン)',
    'オーツカMV注', 'ビタメジン静注用',
    // ── EN/食事 プリセット追加 ──
    'エンシュアリキッド', 'プルモケア-EX', 'ペプタメン スタンダード', 'ペプタメン AF',
    'メイバランス1.5', 'メイバランス2.0',
  ];

  /// デフォルト採用から外す製剤（同名で容量違いがあるため name+volume で指定）。
  static const List<(String, double)> _defaultExcluded = [
    ('メイバランス1.5', 333.0),
    ('カルチコール注射液8.5%', 5.0),
    ('グルセルナ-REX', 400.0),
  ];

  final ProductCatalog catalog;
  final LocalStore store;
  final List<PatientCase> cases;
  final List<ProtocolTemplate> protocols;
  final List<String> favoriteProductIds;
  final List<String> adoptedProductIds;
  String? selectedCaseId;
  String noteText;

  /// 製剤オーバーライドをローカル保存し、カタログにも反映させる
  Future<void> updateProductOverride(
    Product product, {
    String? notes,
    String? content,
    String? productType,
    double? volumeMl,
    double? kcal,
    double? aminoAcidG,
    double? nitrogenG,
    double? npcNRatio,
    double? fatBase,
    double? carbBase,
  }) async {
    if (notes != null) product.notes = notes;
    if (content != null) product.content = content;
    if (productType != null) product.productType = productType;
    if (volumeMl != null) product.volumeMl = volumeMl;
    if (kcal != null) product.kcal = kcal;
    if (aminoAcidG != null) product.aminoAcidG = aminoAcidG;
    if (nitrogenG != null) product.nitrogenG = nitrogenG;
    if (npcNRatio != null) product.npcNRatio = npcNRatio;
    if (fatBase != null) product.fatBase = fatBase;
    if (carbBase != null) product.carbBase = carbBase;

    final overrides = await store.loadProductOverrides();
    overrides[product.id] = {
      'notes': product.notes,
      'content': product.content,
      'product_type': product.productType,
      'volume_ml': product.volumeMl,
      'kcal': product.kcal,
      'amino_acid_g': product.aminoAcidG,
      'nitrogen_g': product.nitrogenG,
      'npc_n_ratio': product.npcNRatio,
      'fat_g_or_kcal_basis': product.fatBase,
      'carb_g_or_kcal_basis': product.carbBase,
    };
    await store.saveProductOverrides(overrides);
  }

  PatientCase? get selectedCase {
    if (selectedCaseId == null && cases.isNotEmpty)
      selectedCaseId = cases.first.id;
    return cases.where((e) => e.id == selectedCaseId).firstOrNull;
  }

  bool isFavorite(String productId) => favoriteProductIds.contains(productId);

  Future<void> toggleFavorite(String productId) async {
    if (favoriteProductIds.contains(productId)) {
      favoriteProductIds.remove(productId);
    } else {
      favoriteProductIds.add(productId);
    }
    await store.saveFavorites(favoriteProductIds);
  }

  /// 現在(または指定)患者の病態タグに対応する「採用済み病態別製剤」のid集合。
  /// 手動★とは別に処方画面で上位(★)に浮かせるための動的算出（非永続）。
  /// → タグOFFで自動的に消え、患者を切り替えても混入しない。
  Set<String> autoFavoriteIds([PatientCase? forCase]) {
    final c = forCase ?? selectedCase;
    final tags = c?.conditionTags ?? const <String>[];
    if (tags.isEmpty) return const <String>{};
    final tagSet = tags.toSet();
    final ids = <String>{};
    for (final p in catalog.products) {
      if (!isAdopted(p.id)) continue;
      if (p.conditionTags.any(tagSet.contains)) ids.add(p.id);
    }
    return ids;
  }

  /// 病態タグ由来の自動★か（手動★は除く）。★アイコンの色分け用。
  bool isAutoFavorite(String productId, [PatientCase? forCase]) =>
      !favoriteProductIds.contains(productId) &&
      autoFavoriteIds(forCase).contains(productId);

  /// 手動★ ∪ 病態タグ由来の自動★。ソート/上位表示はこれを使う。
  bool isEffectiveFavorite(String productId, [PatientCase? forCase]) =>
      favoriteProductIds.contains(productId) ||
      autoFavoriteIds(forCase).contains(productId);

  bool isAdopted(String productId) => adoptedProductIds.contains(productId);

  /// ベース名(容量違いを集約した名前)に対応する製剤を、採用容量を優先して返す。
  /// 計算画面はこれを使い「マスタで選んだ容量」で計算する。
  Product? adoptedByBase(String baseName) {
    final matches =
        catalog.products.where((p) => productBaseName(p.name) == baseName);
    for (final p in matches) {
      if (isAdopted(p.id)) return p;
    }
    return matches.isEmpty ? null : matches.first;
  }

  /// ゼロmenu用: 採用中の純アミノ酸製剤(糖・脂質を含まない高濃度AA)を自動選択。
  /// 採用が無ければアミパレンにフォールバック。
  Product? adoptedAminoForZero() {
    final c = catalog
        .byCategory('PPN')
        .where((p) =>
            isAdopted(p.id) &&
            (p.aminoAcidG ?? 0) > 0 &&
            (p.fatBase ?? 0) <= 0 &&
            (p.carbBase ?? 0) <= 0)
        .toList()
      ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
          .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
    return c.isNotEmpty ? c.first : adoptedByBase('アミパレン');
  }

  /// ゼロmenu用: 採用中の脂肪乳剤(高濃度優先)を自動選択。
  /// 採用が無ければイントラリポス20%にフォールバック。
  Product? adoptedLipidForZero() {
    final c = catalog
        .byCategory('PPN')
        .where((p) => isAdopted(p.id) && (p.fatBase ?? 0) > 0)
        .toList()
      ..sort((a, b) => ((b.fatBase ?? 0) / (b.volumeMl ?? 1))
          .compareTo((a.fatBase ?? 0) / (a.volumeMl ?? 1)));
    return c.isNotEmpty ? c.first : adoptedByBase('イントラリポス20%');
  }

  Future<void> toggleAdopted(String productId) async {
    if (adoptedProductIds.contains(productId)) {
      adoptedProductIds.remove(productId);
    } else {
      adoptedProductIds.add(productId);
    }
    await store.saveAdoptedProducts(adoptedProductIds);
  }

  static Future<AppState> bootstrap(
      ProductCatalog catalog, LocalStore store) async {
    final loaded = await store.loadCases();
    final cases = loaded.map(PatientCase.fromMap).toList();
    // Phase 3-①: 旧ベッド表記 (ICU-XX) を数字のみにマイグレーション
    var migrated = false;
    String _normalizeBed(String raw) {
      final m = RegExp(r'(\d+)').firstMatch(raw);
      if (m == null) return raw;
      return m.group(1)!.padLeft(2, '0');
    }

    for (final c in cases) {
      final newBed = _normalizeBed(c.currentBed);
      if (newBed != c.currentBed) {
        c.currentBed = newBed;
        migrated = true;
      }
      for (final b in c.bedHistory) {
        final newTo = _normalizeBed(b.toBed);
        if (newTo != b.toBed) {
          // BedAssignment.toBedは final なので 新要素に差し替え
          // と思ったが final だと代入できない → BedAssignmentをmutableに修正済みはないので
          // ここではインデックスで置換する
          final idx = c.bedHistory.indexOf(b);
          c.bedHistory[idx] = BedAssignment(
            changedAt: b.changedAt,
            fromBed: b.fromBed == null ? null : _normalizeBed(b.fromBed!),
            toBed: newTo,
            note: b.note,
          );
          migrated = true;
        } else if (b.fromBed != null) {
          final newFrom = _normalizeBed(b.fromBed!);
          if (newFrom != b.fromBed) {
            final idx = c.bedHistory.indexOf(b);
            c.bedHistory[idx] = BedAssignment(
              changedAt: b.changedAt,
              fromBed: newFrom,
              toBed: b.toBed,
              note: b.note,
            );
            migrated = true;
          }
        }
      }
    }
    if (migrated) await store.saveCases(cases);

    // EN製剤の旧形式マイグレーション: 朝昼夕未設定 (morning=noon=evening=0) かつ units>0 の EN/EN_AUX アイテムを削除
    var enMigrated = false;
    for (final c in cases) {
      final before = c.regimenItems.length;
      c.regimenItems.removeWhere((item) {
        final p = catalog.byId(item.productId);
        if (p == null) return false;
        if (p.category != 'EN' && p.category != 'EN_AUX') return false;
        return item.morning + item.noon + item.evening == 0 && item.units > 0;
      });
      if (c.regimenItems.length != before) enMigrated = true;
    }
    if (enMigrated) await store.saveCases(cases);

    final favorites = await store.loadFavorites();

    // 製剤オーバーライドをカタログに適用
    final overrides = await store.loadProductOverrides();
    for (final p in catalog.products) {
      final ov = overrides[p.id];
      if (ov == null) continue;
      if (ov['notes'] != null) p.notes = ov['notes'] as String?;
      if (ov['content'] != null) p.content = ov['content'] as String;
      if (ov['product_type'] != null) {
        p.productType = ov['product_type'] as String;
      }
      if (ov['volume_ml'] != null) {
        p.volumeMl = (ov['volume_ml'] as num).toDouble();
      }
      if (ov['kcal'] != null) {
        p.kcal = (ov['kcal'] as num).toDouble();
      }
      if (ov['amino_acid_g'] != null) {
        p.aminoAcidG = (ov['amino_acid_g'] as num).toDouble();
      }
      if (ov['nitrogen_g'] != null) {
        p.nitrogenG = (ov['nitrogen_g'] as num).toDouble();
      }
      if (ov['npc_n_ratio'] != null) {
        p.npcNRatio = (ov['npc_n_ratio'] as num).toDouble();
      }
      if (ov['fat_g_or_kcal_basis'] != null) {
        p.fatBase = (ov['fat_g_or_kcal_basis'] as num).toDouble();
      }
      if (ov['carb_g_or_kcal_basis'] != null) {
        p.carbBase = (ov['carb_g_or_kcal_basis'] as num).toDouble();
      }
    }
    if (cases.isEmpty) {
      cases.add(
        PatientCase(
          id: 'seed-1',
          caseCode: '01',
          currentBed: '01',
          age: 60,
          heightCm: 150,
          weightKg: 50,
          sex: Sex.male,
          activityFactor: 1.2,
          stressFactor: 1.6,
          proteinGoalPerKg: 1.5,
          createdAt: DateTime.now().toIso8601String(),
          bedHistory: [
            BedAssignment(
                changedAt: DateTime.now().toIso8601String().split('T').first,
                fromBed: null,
                toBed: '01',
                note: '初期登録')
          ],
          regimenItems: [],
          selectedProtocolId: 'five_day',
          zeroMenuConfig: ZeroMenuConfig.defaultConfig(),
        ),
      );
      await store.saveCases(cases);
    }

    var adopted = await store.loadAdoptedProducts();
    // デフォルト採用セットを一度だけ既存の採用リストにマージする
    if (!await store.loadDefaultsApplied()) {
      final defaults = _defaultAdoptedNames.map((n) => n.trim()).toSet();
      bool isExcluded(Product p) => _defaultExcluded
          .any((e) => e.$1 == p.name.trim() && (p.volumeMl ?? 0) == e.$2);
      final defaultIds = catalog.products
          .where((p) => defaults.contains(p.name.trim()) && !isExcluded(p))
          .map((p) => p.id);
      final excludedIds =
          catalog.products.where(isExcluded).map((p) => p.id).toSet();
      adopted = (<String>{...adopted, ...defaultIds}..removeAll(excludedIds))
          .toList();
      await store.saveAdoptedProducts(adopted);
      await store.saveDefaultsApplied();
    }
    final note = await store.loadNote();

    return AppState(
      catalog: catalog,
      store: store,
      cases: cases,
      protocols: const [
        ProtocolTemplate(
            id: 'three_day',
            name: '3日',
            percentages: [33, 67, 100],
            description: '最短3日で full nutrition を目指す'),
        ProtocolTemplate(
            id: 'four_day',
            name: '4日',
            percentages: [25, 50, 75, 100],
            description: '標準的な4日階段導入'),
        ProtocolTemplate(
            id: 'five_day',
            name: '5日',
            percentages: [20, 40, 60, 80, 100],
            description: 'ICU重症例向けの5日階段導入'),
      ],
      selectedCaseId: cases.first.id,
      favoriteProductIds: favorites,
      adoptedProductIds: adopted,
      noteText: note,
    );
  }

  Future<void> addCase(PatientCase item) async {
    cases.insert(0, item);
    selectedCaseId = item.id;
    await persist();
  }

  Future<void> removeCase(String caseId) async {
    cases.removeWhere((e) => e.id == caseId);
    if (selectedCaseId == caseId) {
      selectedCaseId = cases.isNotEmpty ? cases.first.id : null;
    }
    await persist();
  }

  Future<void> setUnits(String caseId, Product product, int units) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final existingIndex =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    if (existingIndex == -1 && units > 0) {
      current.regimenItems
          .add(RegimenItem(productId: product.id, units: units));
    } else if (existingIndex != -1) {
      final partial = current.regimenItems[existingIndex].partialMl;
      if (units <= 0 && partial <= 0) {
        current.regimenItems.removeAt(existingIndex);
      } else {
        current.regimenItems[existingIndex].units = units < 0 ? 0 : units;
        // 朝昼夕をリセット（シンプルカウントに戻す）
        current.regimenItems[existingIndex].morning = 0;
        current.regimenItems[existingIndex].noon = 0;
        current.regimenItems[existingIndex].evening = 0;
      }
    }
    await persist();
  }

  Future<void> setMealUnits(
      String caseId, Product product, int morning, int noon, int evening) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final total = morning + noon + evening;
    final existingIndex =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    if (existingIndex == -1 && total > 0) {
      current.regimenItems.add(RegimenItem(
          productId: product.id,
          units: total,
          morning: morning,
          noon: noon,
          evening: evening));
    } else if (existingIndex != -1) {
      if (total <= 0) {
        current.regimenItems.removeAt(existingIndex);
      } else {
        current.regimenItems[existingIndex]
          ..units = total
          ..morning = morning
          ..noon = noon
          ..evening = evening;
      }
    }
    await persist();
  }

  /// TPN/PPN製剤の部分使用量(ml)を設定。本数(units)はそのまま、部分量のみ更新。
  /// units==0 かつ partialMl==0 になったらアイテム削除。
  Future<void> setPartialMl(String caseId, Product product, int partialMl) async {
    final current = cases.firstWhere((e) => e.id == caseId);
    final idx =
        current.regimenItems.indexWhere((e) => e.productId == product.id);
    final ml = partialMl < 0 ? 0 : partialMl;
    if (idx == -1) {
      if (ml > 0) {
        current.regimenItems
            .add(RegimenItem(productId: product.id, units: 0, partialMl: ml));
      }
    } else {
      current.regimenItems[idx].partialMl = ml;
      if (current.regimenItems[idx].units <= 0 && ml <= 0) {
        current.regimenItems.removeAt(idx);
      }
    }
    await persist();
  }

  Future<void> persist() => store.saveCases(cases);

  Future<void> saveNote(String text) async {
    noteText = text;
    await store.saveNote(text);
  }
}

extension FirstWhereOrNullExtension<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

/// 円グラフ下の横並び凡例アイテム
class _PfcLegendItem extends StatelessWidget {
  const _PfcLegendItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

/// 朝/昼/夕ドロップダウン (0〜3)
class _MealPicker extends StatelessWidget {
  const _MealPicker({
    required this.morning,
    required this.noon,
    required this.evening,
    required this.onChanged,
  });

  final int morning;
  final int noon;
  final int evening;
  final void Function(int morning, int noon, int evening) onChanged;

  static const _options = [0, 1, 2, 3];

  Widget _drop(String label, int value, void Function(int) onChange) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        DropdownButton<int>(
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: _options
              .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
              .toList(),
          onChanged: (v) => onChange(v ?? 0),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _drop('朝', morning, (v) => onChanged(v, noon, evening)),
        const SizedBox(width: 6),
        _drop('昼', noon, (v) => onChanged(morning, v, evening)),
        const SizedBox(width: 6),
        _drop('夕', evening, (v) => onChanged(morning, noon, v)),
      ],
    );
  }
}

/// Day別 投与設計画面
// インライン版(BuilderPageタブ内)とページ版で共用するウィジェット
class AutoDesignInline extends StatefulWidget {
  const AutoDesignInline({super.key, required this.state, required this.current, this.onSettingsChanged});
  final AppState state;
  final PatientCase current;
  /// 設定変更時に親ウィジェットへ通知（チャートパネルのリアルタイム更新用）
  final VoidCallback? onSettingsChanged;

  @override
  State<AutoDesignInline> createState() => _AutoDesignPageState();
}

// 後方互換: 独立ページとして開く場合はScaffoldでラップ
class AutoDesignPage extends StatelessWidget {
  const AutoDesignPage({super.key, required this.state, required this.current});
  final AppState state;
  final PatientCase current;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('Day別 投与設計'),
        ),
        body: AutoDesignInline(state: state, current: current),
      );
}

class _AutoDesignPageState extends State<AutoDesignInline> {
  int _hoveredBarIdx = -1;  // グラフホバー中のバーインデックス (-1=なし)
  int _selectedBarIdx = -1; // タップ固定のバーインデックス (-1=なし)
  bool _alertsExpanded = false; // 栄養管理アラートの展開状態(既定=折り畳み)
  bool _trendCollapsed = false; // トレンド(栄養の推移)折りたたみ
  double _cachedChartW = 300.0; // LayoutBuilderで更新するチャート実幅
  int _rampDays = 5; // full nutrition達成日(栄養開始からのDay)。この日に等差ランプでfullへ到達。
  // 簡易式の栄養係数の上限を使う「最終日」(until, 栄養開始からのDay)。permissive underfeeding。
  int _kcalStep20Day = 2; // 20kcal/kgを上限とする最終日(これ以前は20上限)
  int _kcalStep25Day = 4; // 25kcal/kgを上限とする最終日(20最終日の翌日〜この日は25上限)
  // true: EN/経口リハ開始日に連動して係数の最終日を自動設定(既定)
  bool _kcalStepAuto = true;
  int _enStartDay = 6; // EN導入するDay番号(食上げ開始日)
  int? _oralRehabStartDay; // 経口リハ開始Day (null=未設定)
  int _totalDays = 5; // シミュレーション全体の日数 (= _enStartDay + EN食上げ7日 -1)
  Product? _pnProduct; // PN(中心静脈栄養)主剤
  late DateTime _startDate; // 栄養開始日
  late List<double> _dayPercents; // 各Dayの達成目標%
  late List<String> _dayModes; // 各Dayのクラス
  late List<String> _dayEnDose; // 各DayのEN投与 ('0'/'r20'(速度)/'p3'(pac))
  late List<int> _dayMealPac; // 各Dayの食事 朝昼夕あたりpac数(0=食事なし, 1..3)

  // EN食上げ固定シーケンス(7日): 10→20→30→40ml/h → 1pac朝昼夕(3) → 2pac朝昼夕(6) → EN単独full
  static const _enRampSequence = ['r10', 'r20', 'r30', 'r40', 'p3', 'p6', 'p6'];
  static const _enRampDays = 7;
  // 設定テーブルの Day ドロップダウン共通幅(full/EN/経口リハで揃える)
  static const double _dayDropW = 52;
  // 経口リハ食上げ(開始日から+5日=計6日): 朝昼夕pacを1→2→3に漸増、不足はPPN補充
  static const _mealRampDays = 6;

  @override
  void initState() {
    super.initState();
    final tpn = _adopted('TPN');
    final cfg = widget.current.autoDesignConfig;
    if (cfg != null) {
      // 保存済み設定を復元 (rampDays・開始日・PN製剤のみ。日別は固定シーケンスから再生成)
      _rampDays = ((cfg['rampDays'] as num?)?.toInt() ?? 5).clamp(2, 28);
      _enStartDay = (cfg['enStartDay'] as num?)?.toInt() ?? (_rampDays + 1);
      // 経口リハ導入の既定値: EN導入＋7日(EN食上げ完了の翌日)。未保存/未設定でも選択済みにし、
      // 「未選択(—)」でドロップダウンが横長になるのを防ぐ。
      _oralRehabStartDay = (cfg['oralRehabStartDay'] as num?)?.toInt() ??
          (_enStartDay + _enRampDays).clamp(1, 28);
      _startDate =
          DateTime.tryParse(cfg['startDate'] as String? ?? '') ?? DateTime.now();
      _kcalStep20Day = (cfg['kcalStep20Day'] as num?)?.toInt() ?? 2;
      _kcalStep25Day = (cfg['kcalStep25Day'] as num?)?.toInt() ?? 4;
      _kcalStepAuto = (cfg['kcalStepAuto'] as bool?) ?? true;
      final pid = cfg['pnProductId'] as String?;
      _pnProduct = pid != null ? widget.state.catalog.byId(pid) : (tpn.isNotEmpty ? tpn.first : null);
    } else {
      final p = widget.state.protocols.firstWhere(
          (e) => e.id == widget.current.selectedProtocolId,
          orElse: () => widget.state.protocols.first);
      _rampDays = p.percentages.length;
      _enStartDay = _rampDays + 1;
      // 経口リハ導入の既定値: EN導入＋7日(EN食上げ完了の翌日)
      _oralRehabStartDay = (_enStartDay + _enRampDays).clamp(1, 28);
      _pnProduct = tpn.isNotEmpty ? tpn.first : null;
      _startDate = () {
        for (final b in widget.current.bedHistory) {
          if (b.fromBed == null) {
            final d = DateTime.tryParse(b.changedAt);
            if (d != null) return d;
          }
        }
        return DateTime.now();
      }();
    }
    _rebuildDays();
  }

  @override
  void dispose() {
    _saveConfig();
    super.dispose();
  }

  void _saveConfig() {
    widget.current.autoDesignConfig = {
      'rampDays': _rampDays,
      'enStartDay': _enStartDay,
      'oralRehabStartDay': _oralRehabStartDay,
      'pnProductId': _pnProduct?.id,
      'startDate': _startDate.toIso8601String(),
      'kcalStep20Day': _kcalStep20Day,
      'kcalStep25Day': _kcalStep25Day,
      'kcalStepAuto': _kcalStepAuto,
    };
    widget.state.persist();
  }

  List<Product> _adopted(String cat) => widget.state.catalog
      .byCategory(cat)
      .where((p) => widget.state.isAdopted(p.id))
      .toList();

  /// 簡易式 栄養係数(20/25/30 kcal/kg)の段階開始日 設定。
  /// イベント日付決定(絶食〜経口リハ)と同じテーブルに行として配置する。
  /// 既定は自動(EN/経口リハ開始日に連動)。チェックを外すと手動設定。
  List<TableRow> _kcalStepTableRows() {
    final enabled = !_kcalStepAuto;
    TableRow dayRow(String label, Color color, int value, ValueChanged<int> onCh) {
      return TableRow(children: [
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.trending_up,
                size: 13, color: enabled ? color : Colors.grey),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 13, color: enabled ? color : Colors.grey)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('〜Day ', style: TextStyle(fontSize: 13)),
            SizedBox(
              width: _dayDropW,
              child: DropdownButton<int>(
                value: value.clamp(1, 28),
                isDense: true,
                isExpanded: true,
                items: List.generate(28, (i) => i + 1)
                    .map((d) => DropdownMenuItem(value: d, child: Text('$d')))
                    .toList(),
                onChanged: enabled
                    ? (v) {
                        if (v == null) return;
                        setState(() {
                          onCh(v);
                          // 単調性: 20上限の最終日 ≤ 25上限の最終日
                          if (_kcalStep25Day < _kcalStep20Day) {
                            _kcalStep25Day = _kcalStep20Day;
                          }
                          if (_kcalStep20Day > _kcalStep25Day) {
                            _kcalStep20Day = _kcalStep25Day;
                          }
                          _rebuildDays();
                        });
                        _saveConfig();
                        widget.onSettingsChanged?.call();
                      }
                    : null,
              ),
            ),
          ]),
        ),
      ]);
    }

    return [
      // 見出し + 自動連動チェックボックス
      TableRow(children: [
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 6),
          child: Text('栄養係数上限:',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.green.shade800)),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: _kcalStepAuto,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) {
                  setState(() {
                    _kcalStepAuto = v ?? true;
                    if (_kcalStepAuto) _applyAutoKcalSteps();
                    _rebuildDays();
                  });
                  _saveConfig();
                  widget.onSettingsChanged?.call();
                },
              ),
            ),
            const SizedBox(width: 2),
            const Text('自動(EN/リハ連動)', style: TextStyle(fontSize: 11)),
          ]),
        ),
      ]),
      dayRow('20 kcal/kg', Colors.green.shade700, _kcalStep20Day,
          (v) => _kcalStep20Day = v),
      dayRow('25 kcal/kg', Colors.green.shade700, _kcalStep25Day,
          (v) => _kcalStep25Day = v),
    ];
  }

  /// 食事(経口リハ)用の採用製剤: 濃厚流動食+栄養サポート。未採用なら全食事製剤。
  List<Product> _adoptedMeals() {
    final adopted = widget.state.catalog.products
        .where((p) => p.isFood && widget.state.isAdopted(p.id))
        .toList();
    if (adopted.isNotEmpty) return adopted;
    return widget.state.catalog.products.where((p) => p.isFood).toList();
  }

  /// EN製剤を全日程で1製剤に固定するための選択。
  /// 40ml/h連続投与(=ピーク)でtargetKcalを超えず、できるだけ目標に近い製剤を選ぶ。
  /// → 同じ製剤を全日に使うのでENカロリーが単調増加し、INのガタつきも抑制。
  Product? _pickEnProduct(List<Product> ens, double targetKcal) {
    if (ens.isEmpty) return null;
    const peakMl = 40.0 * 24; // 40ml/h × 24h = 960ml
    Product? best;
    double bestScore = double.infinity;
    for (final p in ens) {
      if ((p.kcal ?? 0) <= 0 || (p.volumeMl ?? 0) <= 0) continue;
      final kcalAt40 = (p.kcal ?? 0) * peakMl / p.volumeMl!;
      final ratio = targetKcal > 0 ? kcalAt40 / targetKcal : 1.0;
      double s;
      if (ratio > 1.0) {
        s = (ratio - 1.0) * 100; // over厳禁
      } else {
        s = (1.0 - ratio); // 不足はなるべく少なく(高密度優先)
      }
      if (s < bestScore) {
        bestScore = s;
        best = p;
      }
    }
    return best ?? ens.first;
  }

  // EN投与dose文字列の解釈: 'r20'=20ml/h, 'p3'=3pac, '0'=なし
  double _rateOf(String dose) =>
      dose.startsWith('r') ? (double.tryParse(dose.substring(1)) ?? 0) : 0;
  int _pacOf(String dose) =>
      dose.startsWith('p') ? (int.tryParse(dose.substring(1)) ?? 0) : 0;

  // EN投与doseのラベル
  String _doseLabel(String dose) {
    switch (dose) {
      case '0':
        return 'なし';
      case 'r10':
        return '10ml/h';
      case 'r20':
        return '20ml/h';
      case 'r30':
        return '30ml/h';
      case 'r40':
        return '40ml/h';
      case 'p3':
        return '朝昼夕1pac';
      case 'p6':
        return '朝昼夕2pac';
      default:
        return dose;
    }
  }

  // 栄養開始日からの mm/dd
  String _dateOf(int i) {
    final d = _startDate.add(Duration(days: i));
    return '${d.month}/${d.day}';
  }

  // クラスのバッジ表示
  Widget _modeBadge(String mode, {bool planIsZero = false}) {
    final baseLabel = switch (mode) {
      'TPN' => 'PN',
      'TPN+EN' => 'EN+PN',
      'EN' => 'EN',
      'ZERO' => 'ゼロmenu',
      '食事' => '食事',
      _ => mode,
    };
    // PN部分がゼロmenuにフォールバックした場合の表記
    final label = (mode == 'TPN+EN' && planIsZero) ? 'EN+ゼロmenu' : baseLabel;
    final color = switch (mode) {
      'TPN' => Colors.blue,
      'TPN+EN' => Colors.teal,
      'EN' => Colors.amber.shade500,
      '食事' => Colors.deepOrange.shade400,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.bold)),
    );
  }

  // 全期間を固定シーケンスで自動生成:
  //   目標%(総カロリー)はrampDaysで100%まで等差で漸増し、以降100%を維持(EN導入とは独立)
  //   EN食上げ(enStartDay以降7日): 10→20→30→40ml/h → 1pac→2pac朝昼夕、PNは自動減量、最終日はEN単独full
  /// 自動連動: 栄養開始〜EN開始前=20, EN開始〜経口リハ前=25, 経口リハ以降=30 kcal/kg。
  void _applyAutoKcalSteps() {
    // 20kcal/kg上限はEN開始日まで、25kcal/kg上限は経口リハ開始日まで(以降はfull)。
    _kcalStep20Day = _enStartDay.clamp(1, 28);
    final oral = _oralRehabStartDay ?? (_enStartDay + _enRampDays);
    _kcalStep25Day = oral.clamp(_kcalStep20Day, 28);
  }

  void _rebuildDays() {
    if (_enStartDay < 1) _enStartDay = 1;
    if (_kcalStepAuto) _applyAutoKcalSteps();
    final enEnd = _enStartDay + _enRampDays - 1;
    final oral = _oralRehabStartDay;
    // 経口リハ開始日+5日(計6日)まで延長
    final mealEnd = oral != null ? oral + _mealRampDays - 1 : 0;
    _totalDays = enEnd > mealEnd ? enEnd : mealEnd;
    // full達成(_rampDays)・25上限が最終日を超えると最終段階に到達しないため最終日までにクランプ。
    if (_totalDays > 0) {
      if (_rampDays > _totalDays) _rampDays = _totalDays;
      if (_kcalStepAuto && _kcalStep25Day > _totalDays) {
        _kcalStep25Day = _totalDays;
        if (_kcalStep20Day > _kcalStep25Day) _kcalStep20Day = _kcalStep25Day;
      }
    }
    // 設定変更を親(チャートパネル)に通知
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSettingsChanged?.call();
    });
    final n = _totalDays;
    _dayPercents = List.generate(n, (i) {
      final day = i + 1;
      // 総カロリーは等差ramp優先: rampDaysで100%まで漸増、以降100%維持
      if (day <= _rampDays) {
        return ((day * 100.0 / _rampDays).clamp(0.0, 100.0)).roundToDouble();
      }
      return 100.0;
    });
    _dayModes = List.generate(n, (i) {
      final day = i + 1;
      if (oral != null && day >= oral) return '食事'; // 経口リハ期は食事主体
      if (day < _enStartDay) return 'TPN'; // EN導入前はPNのみ
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      if (step == _enRampDays - 1) return 'EN'; // 最終ステップはEN単独full
      return 'TPN+EN'; // 食上げ中はPN+EN併用(PN自動減量)
    });
    _dayEnDose = List.generate(n, (i) {
      final day = i + 1;
      if (oral != null && day >= oral) return '0'; // 食事期のENは食事ロジック側で補完
      if (day < _enStartDay) return '0';
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      return _enRampSequence[step];
    });
    _dayMealPac = List.generate(n, (i) {
      final day = i + 1;
      if (oral == null || day < oral) return 0;
      final d = day - oral; // 0..5
      // 朝昼夕 1→2→3pac (2日ごとに1pac up)。不足分はPPNで補う
      return (1 + d ~/ 2).clamp(1, 3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final targetKcal = NutritionCalculator.targetEnergy(widget.current);
    final targetProt = NutritionCalculator.targetProtein(widget.current);
    final pcts = _dayPercents;
    // お気に入り製剤(手動★＋病態タグ由来)を先頭に並べて優先選択させる
    List<Product> sortFav(List<Product> list) {
      final fav = list
          .where((p) => widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      final rest = list
          .where((p) => !widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      return [...fav, ...rest];
    }
    final enList = sortFav(_adopted('EN'));
    final tpnAll = sortFav(_adopted('TPN'));
    final tpnList = tpnAll;
    final ppnList = sortFav(_adopted('PPN'));
    final mealList = sortFav(_adoptedMeals());
    // _pnProduct が採用TPNに無ければ先頭にフォールバック
    if (_pnProduct == null || !tpnAll.any((p) => p.id == _pnProduct!.id)) {
      _pnProduct = tpnAll.isNotEmpty ? tpnAll.first : null;
    }
    // プランを逐次生成して minEnKcal(単調増加制約)を引き継ぐ
    double prevEnKcal = 0;
    final dayPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final plan = NutritionCalculator.designDay(
        mode: _dayModes[i],
        dayTargetKcal: phase.kcal,
        dayTargetProt: phase.prot,
        weightKg: widget.current.weightKg,
        enProducts: enList,
        enRateMlH: _rateOf(_dayEnDose[i]),
        enPac: _pacOf(_dayEnDose[i]),
        pnProduct: _pnProduct,
        tpnProducts: tpnList,
        ppnProducts: ppnList,
        glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
        aminoProduct: widget.state.adoptedAminoForZero(),
        lipidProduct: widget.state.adoptedLipidForZero(),
        minEnKcal: prevEnKcal,
        mealProducts: mealList,
        mealPac: _dayMealPac[i],
        girLimitMgKgMin: _girLimit,
        maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
        // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
        allowZeroMenu: _dayModes[i] == 'TPN' && i >= 6,
      );
      dayPlans.add(plan);
      if (plan.enKcal > 0 && _dayModes[i] != '食事') prevEnKcal = plan.enKcal;
    }

    final screenH = MediaQuery.of(context).size.height;
    // Visibility(maintainState)内でExpandedは使えないため高さを固定する
    final listH = (screenH * 0.55).clamp(300.0, 600.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: listH,
          child: ListView(
            padding: EdgeInsets.zero, // 外側ListView(all:16)が既にパディングを持つ
            children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 設定: 絶食〜経口リハ
                  Table(
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    columnWidths: const {
                      0: IntrinsicColumnWidth(), // ラベル列（最長に合わせる）
                      1: IntrinsicColumnWidth(), // 値列
                    },
                    children: [
                      // 行0: 絶食日（常時表示・タップで設定）
                      TableRow(children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.no_meals, size: 13, color: Colors.red.shade400),
                              const SizedBox(width: 4),
                              Text('絶食日:',
                                  style: TextStyle(fontSize: 13, color: Colors.red.shade400)),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: const Size(0, 0),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    foregroundColor: Colors.red.shade400),
                                onPressed: () async {
                                  final fd = widget.current.fastingDate;
                                  final initial = fd != null
                                      ? (DateTime.tryParse(fd) ?? _startDate)
                                      : _startDate;
                                  final picked = await _quickPickDate(context, initial);
                                  if (picked != null) {
                                    setState(() {
                                      widget.current.fastingDate =
                                          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                                    });
                                    widget.state.persist();
                                    widget.onSettingsChanged?.call();
                                  }
                                },
                                child: Builder(builder: (_) {
                                  final fd = widget.current.fastingDate;
                                  final p = fd != null ? DateTime.tryParse(fd) : null;
                                  final label = p != null
                                      ? '${p.year}/${p.month.toString().padLeft(2, '0')}/${p.day.toString().padLeft(2, '0')}'
                                      : '未設定';
                                  return Text(label,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: p != null
                                              ? Colors.red.shade400
                                              : Colors.grey));
                                }),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      // 行1: 栄養開始日
                      TableRow(children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.water_drop, size: 13, color: Colors.blue.shade600),
                            const SizedBox(width: 4),
                            Text('栄養開始日:',
                                style: TextStyle(fontSize: 13, color: Colors.blue.shade600)),
                          ]),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: TextButton(
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: Colors.blue.shade600),
                            onPressed: () async {
                              final picked = await _quickPickDate(context, _startDate);
                              if (picked != null) {
                                setState(() => _startDate = picked);
                                widget.onSettingsChanged?.call();
                              }
                            },
                            child: Text(
                                '${_startDate.year}/${_startDate.month.toString().padLeft(2, '0')}/${_startDate.day.toString().padLeft(2, '0')}',
                                style: TextStyle(fontSize: 13, color: Colors.blue.shade600)),
                          ),
                        ),
                      ]),
                      // 行2: full nutrition達成
                      TableRow(children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: Text('full nutrition達成:',
                              style: TextStyle(fontSize: 13, color: Colors.green.shade800)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              SizedBox(
                                width: _dayDropW,
                                child: DropdownButton<int>(
                                  value: _rampDays.clamp(2, 28),
                                  isDense: true,
                                  isExpanded: true,
                                  items: List.generate(27, (i) => i + 2)
                                      .map((d) => DropdownMenuItem(
                                          value: d, child: Text('$d')))
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() {
                                      _rampDays = v ?? _rampDays;
                                      _rebuildDays();
                                    });
                                    _saveConfig();
                                    widget.onSettingsChanged?.call();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      // 行3: EN導入 (色はグラフのEN(アンバー)と統一)
                      TableRow(children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: Text('EN導入:',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.amber.shade500)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              SizedBox(
                                width: _dayDropW,
                                child: DropdownButton<int>(
                                  value: _enStartDay.clamp(1, 21),
                                  isDense: true,
                                  isExpanded: true,
                                  items: List.generate(21, (i) => i + 1)
                                      .map((d) => DropdownMenuItem(
                                          value: d, child: Text('$d')))
                                      .toList(),
                                  onChanged: (v) => setState(() {
                                    _enStartDay = v ?? _enStartDay;
                                    _rebuildDays();
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      // 行4: 経口リハ導入 (EN導入行と同一レイアウト)
                      TableRow(children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 6),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.restaurant,
                                size: 13, color: Colors.red.shade400),
                            const SizedBox(width: 4),
                            Text('経口リハ導入:',
                                style: TextStyle(
                                    fontSize: 13, color: Colors.red.shade400)),
                          ]),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              SizedBox(
                                width: _dayDropW,
                                child: DropdownButton<int?>(
                                  value: _oralRehabStartDay,
                                  isDense: true,
                                  isExpanded: true,
                                  hint: const Text('—',
                                      style: TextStyle(fontSize: 13)),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                        value: null, child: Text('—')),
                                    ...List.generate(28, (i) => i + 1).map((d) =>
                                        DropdownMenuItem<int?>(
                                            value: d, child: Text('$d'))),
                                  ],
                                  onChanged: (v) => setState(() {
                                    _oralRehabStartDay = v;
                                    _rebuildDays(); // 食事フェーズを再生成
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      // 栄養係数 step up(20/25/30 kcal/kg)の段階開始日を同テーブルに配置
                      ..._kcalStepTableRows(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text('★ お気に入り製剤を優先して設計します',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: (listH - 240).clamp(220.0, 460.0),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
          ...List.generate(pcts.length, (i) {
            final phase = _acutePhaseTarget(i);
            final dayKcal = phase.kcal;
            final dayProt = phase.prot;
            final pctOfFull =
                targetKcal > 0 ? dayKcal / targetKcal * 100 : 0.0;
            final mode = _dayModes[i];
            final showEn = mode == 'EN' || mode == 'TPN+EN';
            final showPn = mode == 'TPN' || mode == 'TPN+EN';
            // 逐次生成済みのプランを使用（minEnKcal単調増加制約適用済み）
            final plan = dayPlans[i];
            return SizedBox(
              width: 264,
              child: Card(
              margin: const EdgeInsets.only(right: 10),
              child: InkWell(
                onTap: () => _showDayDetail(i, plan, dayKcal, dayProt),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(_dateOf(i),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        Text('(Day${i + 1})',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ]),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          // 目標% or "full nutrition"（常にgreen）
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              pctOfFull >= 99
                                  ? 'full nutrition'
                                  : '目標 ${pctOfFull.round()}%',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green.shade800),
                            ),
                          ),
                          if (showEn) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade200,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.amber.shade600, width: 0.8),
                              ),
                              child: Text(_doseLabel(_dayEnDose[i]),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.brown.shade700)),
                            ),
                          ],
                          if (mode == '食事') ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade100,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.deepOrange.shade400, width: 0.8),
                              ),
                              child: Text('朝昼夕 ${_dayMealPac[i]}pac',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade800)),
                            ),
                          ],
                          _modeBadges(plan),
                        ],
                      ),
                      const Divider(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          child: _planBody(plan, dayKcal, dayProt, mode),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ));
          }),
              ],
            ),
          ),
            ],
          ),
        ),   // SizedBox(listH)
      ],
    );
  }

  // BuilderPage の _buildAutoChartPanel から呼ばれる
  Widget _buildBarChartsForBuilder() {
    final targetKcal = NutritionCalculator.targetEnergy(widget.current);
    final pcts = _dayPercents;
    List<Product> sortFav(String cat) {
      final list = widget.state.catalog
          .byCategory(cat)
          .where((p) => widget.state.isAdopted(p.id))
          .toList();
      final fav = list
          .where((p) => widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      final rest = list
          .where((p) => !widget.state.isEffectiveFavorite(p.id, widget.current))
          .toList();
      return [...fav, ...rest];
    }
    return _buildBarCharts(
        targetKcal, pcts, sortFav('EN'), sortFav('TPN'), sortFav('PPN'));
  }

  /// プラン内のEN/EN補助製剤由来のカロリーを集計
  double _enKcalOfPlan(DesignPlan plan) {
    double s = 0;
    for (final it in plan.items) {
      final p = widget.state.catalog.byName(it.name);
      // 食事(濃厚流動食/栄養サポート)はEN扱いしない。EN本体/補助のみ集計
      if (p != null && !p.isFood &&
          (p.category == 'EN' || p.category == 'EN_AUX')) {
        s += it.kcal;
      }
    }
    return s;
  }

  // 食事(経口リハ)由来kcal: 濃厚流動食/栄養サポート製剤の合計
  double _mealKcalOfPlan(DesignPlan plan) {
    double s = 0;
    for (final it in plan.items) {
      final p = widget.state.catalog.byName(it.name);
      if (p != null && p.isFood) s += it.kcal;
    }
    return s;
  }

  /// 自動設計で用いるGIR上限（糖質制限病態は4、それ以外は5 mg/kg/min）。
  double get _girLimit =>
      (cc.resolveCoeff(widget.current.conditionTags)?.glucoseRestrict ?? false)
          ? ck.ClinicalConst.girWarnMgKgMin
          : ck.ClinicalConst.girLimitMgKgMin;

  /// Refeeding（NICE）リスク階層。栄養開始日−絶食開始日 と BMI から判定。
  cr.RefeedingTier get _refeedingTier {
    final c = widget.current;
    final bmi = cbw.bmiOf(c.weightKg, c.heightCm);
    int? days;
    final fr = c.fastingDate != null ? DateTime.tryParse(c.fastingDate!) : null;
    if (fr != null) {
      days = DateTime(_startDate.year, _startDate.month, _startDate.day)
          .difference(DateTime(fr.year, fr.month, fr.day))
          .inDays;
    }
    return cr.refeedingTier(bmi: bmi, daysNoIntake: days);
  }

  /// Refeedingリスク時、栄養開始からの feeding 日(0始まり)で kcal を上限cap。
  double _refeedCappedKcal(int dayIndexZero, double rawKcal) {
    final tier = _refeedingTier;
    if (tier == cr.RefeedingTier.none) return rawKcal;
    final fw =
        NutritionCalculator.targetEnergyResult(widget.current).feedingWeightKg;
    if (fw <= 0) return rawKcal;
    final fullKpk = NutritionCalculator.targetEnergy(widget.current) / fw;
    final cap = cr.refeedingCapKcalPerKg(tier, dayIndexZero + 1, fullKpk) * fw;
    return rawKcal < cap ? rawKcal : cap;
  }

  /// 各日の目標kcal(full nutrition)= 等差ランプ ∧ 係数上限。
  ///  ・等差ランプ: full nutrition達成日(_rampDays)に本来full(realFull)へ線形到達。起点は20kcal/kg相当。
  ///  ・係数上限(permissive underfeeding): 20kcal/kg(〜_kcalStep20Day)・25kcal/kg(〜_kcalStep25Day)で上限キャップ。
  ///    _kcalStep25Day を過ぎたら上限解除(realFullまで)。
  /// タンパクはkcal比に按分。Refeedingリスク時はさらにcap。
  ({double kcal, double prot}) _acutePhaseTarget(int i) {
    final realFull = NutritionCalculator.targetEnergy(widget.current);
    final realProt = NutritionCalculator.targetProtein(widget.current);
    final fw =
        NutritionCalculator.targetEnergyResult(widget.current).feedingWeightKg;
    final raw = ce.acutePhaseTargetKcal(
      day: i + 1,
      feedingWeightKg: fw,
      realFullKcal: realFull,
      fullAchieveDay: _rampDays,
      kcal20UntilDay: _kcalStep20Day,
      kcal25UntilDay: _kcalStep25Day,
    );
    final cappedKcal = _refeedCappedKcal(i, raw);
    final frac = realFull > 0 ? cappedKcal / realFull : 1.0;
    return (kcal: cappedKcal, prot: realProt * frac);
  }

  /// 1日プランの電解質・微量元素・ビタミンUL超過アラート。
  List<cm.MicroAlert> _dayMicroAlerts(DesignPlan p) {
    final totals = cm.aggregateMicro(p.items.map((it) {
      var prod = widget.state.catalog.byName(it.name);
      double mult;
      if (prod == null) {
        // 加注プレースホルダ('電解質製剤'/'微量元素製剤'/'ビタミン製剤')→採用標準製剤に解決
        prod = _resolveAdditivePlaceholder(it.name);
        mult = prod != null ? 1.0 : 0.0; // 1日1管相当
      } else if ((it.units ?? 0) > 0) {
        mult = it.units!.toDouble();
      } else if ((prod.volumeMl ?? 0) > 0) {
        mult = it.volumeMl / prod.volumeMl!;
      } else {
        mult = 0;
      }
      return cm.MicroContribution(prod?.micro, mult);
    }));
    final bmi = cbw.bmiOf(widget.current.weightKg, widget.current.heightCm);
    final f = _microFlags(widget.current.conditionTags,
        bmi: bmi, refeedingHigh: _refeedingTier != cr.RefeedingTier.none);
    double carb = 0;
    for (final it in p.items) {
      final pr = widget.state.catalog.byName(it.name);
      final base = pr?.carbBase ?? 0;
      if (base <= 0) continue;
      carb += (pr?.volumeMl ?? 0) > 0
          ? base * it.volumeMl / pr!.volumeMl!
          : base * (it.units ?? 0);
    }
    return cm.microAlerts(totals,
        isMale: widget.current.sex == Sex.male,
        longTermTpn: false,
        cholestasis: f.cholestasis,
        liver: f.liver,
        renal: f.renal,
        crrt: f.crrt,
        giLoss: f.giLoss,
        glucoseLoad: carb > 0,
        wernickeRisk: f.wernicke);
  }

  /// 加注プレースホルダ名→採用済み標準製剤(なければ先頭)に解決。
  Product? _resolveAdditivePlaceholder(String name) {
    String? cat;
    if (name == '微量元素製剤') {
      cat = '微量元素';
    } else if (name == 'ビタミン製剤') {
      cat = 'ビタミン';
    } else if (name == '電解質製剤') {
      cat = '電解質';
    }
    if (cat == null) return null;
    final adopted = widget.state.catalog
        .byCategory(cat)
        .where((p) => widget.state.isAdopted(p.id))
        .toList();
    // 胆汁うっ滞/肝障害では微量元素はMn-freeを優先
    if (cat == '微量元素' &&
        (widget.current.conditionTags.contains('cholestasis') ||
            widget.current.conditionTags.contains('liver'))) {
      final mnFree = adopted.where((p) => p.isMnFreeTrace).toList();
      if (mnFree.isNotEmpty) return mnFree.first;
      final anyMnFree = widget.state.catalog
          .byCategory('微量元素')
          .where((p) => p.isMnFreeTrace)
          .toList();
      if (anyMnFree.isNotEmpty) return anyMnFree.first;
    }
    if (adopted.isNotEmpty) return adopted.first;
    final all = widget.state.catalog.byCategory(cat);
    return all.isNotEmpty ? all.first : null;
  }

  Widget _buildBarCharts(double targetKcal, List<double> pcts,
      List<Product> en, List<Product> tpn, List<Product> ppn) {
    final targetProt = NutritionCalculator.targetProtein(widget.current);
    // 逐次生成して minEnKcal 単調増加制約を適用
    double prevEnKcalChart = 0;
    final designPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final phase = _acutePhaseTarget(i);
      final p = NutritionCalculator.designDay(
              mode: _dayModes[i],
              dayTargetKcal: phase.kcal,
              dayTargetProt: phase.prot,
              weightKg: widget.current.weightKg,
              enProducts: en,
              enRateMlH: _rateOf(_dayEnDose[i]),
              enPac: _pacOf(_dayEnDose[i]),
              pnProduct: _pnProduct,
              tpnProducts: tpn,
              ppnProducts: ppn,
              glucoseProduct: widget.state.adoptedByBase('70% グルコース'),
              aminoProduct: widget.state.adoptedAminoForZero(),
              lipidProduct: widget.state.adoptedLipidForZero(),
              minEnKcal: prevEnKcalChart,
              mealProducts: _adoptedMeals(),
              mealPac: _dayMealPac[i],
              girLimitMgKgMin: _girLimit,
              maxLipidGramPerKgDay: ck.ClinicalConst.lipidDayLimitGKgD,
              // ゼロmenuはPN専用が6日続いた翌日(7日目, i>=6)以降のPN専用日のみ許可
              allowZeroMenu: _dayModes[i] == 'TPN' && i >= 6,
            );
      if (p.enKcal > 0 && _dayModes[i] != '食事') prevEnKcalChart = p.enKcal;
      designPlans.add(p);
    }

    // 絶食日が設定されていればそこから起算、なければ今日から
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    final startNorm = DateTime(_startDate.year, _startDate.month, _startDate.day);
    final fastingRaw = widget.current.fastingDate != null
        ? DateTime.tryParse(widget.current.fastingDate!)
        : null;
    final chartOrigin = fastingRaw != null
        ? DateTime(fastingRaw.year, fastingRaw.month, fastingRaw.day)
        : todayNorm;
    final preDays = startNorm.difference(chartOrigin).inDays.clamp(0, 60);
    final emptyPlan = DesignPlan(label: 'Day', items: const []);
    final plans = [
      ...List.filled(preDays, emptyPlan),
      ...designPlans,
    ];

    final enKcals = plans.map(_enKcalOfPlan).toList();
    final mealKcals = plans.map(_mealKcalOfPlan).toList();
    final ins = plans.map((p) => p.totalVolumeMl).toList();
    final prots = plans.map((p) => p.totalProteinG).toList();
    final n = plans.length;

    // 必須脂肪酸欠乏(EFAD)チェック:
    //   絶食開始(chartOrigin)からday14までに脂質が全く補充されていなければアラート。
    //   各itemの脂質gは製剤のfatBaseを投与量比で按分して算出。
    double fatOfPlan(DesignPlan p) {
      double f = 0;
      for (final it in p.items) {
        final prod = widget.state.catalog.byName(it.name);
        final base = prod?.fatBase ?? 0;
        if (base <= 0) continue;
        final pv = prod?.volumeMl ?? 0;
        f += pv > 0 ? base * it.volumeMl / pv : base * (it.units ?? 0);
      }
      return f;
    }
    // day14まで到達し、その間の累積脂質がほぼ0なら欠乏リスク
    final efadRisk = n >= 14 &&
        List.generate(14, (i) => fatOfPlan(plans[i]))
            .fold<double>(0.0, (s, v) => s + v) < 1.0;

    // ビタミンB1(チアミン)アラート: リフィーディング症候群/Wernicke脳症予防
    //   公開情報: B1体内貯蔵は約30mg=2〜3週で枯渇。糖質(ブドウ糖)負荷でB1消費が
    //   増大し、絶食後の栄養再開でWernicke脳症/乳酸アシドーシスを来しうる。
    //   NICE基準: 5日以上の絶食/低栄養はリフィーディング高リスク。
    //   → 絶食≥5日 かつ 糖質投与あり でB1補充を促す。
    double carbOfPlan(DesignPlan p) {
      double c = 0;
      for (final it in p.items) {
        final prod = widget.state.catalog.byName(it.name);
        final base = prod?.carbBase ?? 0;
        if (base <= 0) continue;
        final pv = prod?.volumeMl ?? 0;
        c += pv > 0 ? base * it.volumeMl / pv : base * (it.units ?? 0);
      }
      return c;
    }
    final thiamineRisk =
        preDays >= 5 && designPlans.any((p) => carbOfPlan(p) > 0);

    // PN主体モニタリングアラート:
    //   EN≤30ml/hでPNが栄養の主体となる期間が、絶食開始から一定日数(7日)続く場合、
    //   電解質・微量元素・ビタミンの過不足を採血で確認し補正を検討するよう促す。
    int pnHeavyMaxDay = 0;
    for (int i = preDays; i < n; i++) {
      final j = i - preDays;
      if (j < 0 || j >= _dayEnDose.length) continue;
      final enRate = _rateOf(_dayEnDose[j]);
      final pnKcal = plans[i].totalKcal - _enKcalOfPlan(plans[i]);
      if (enRate <= 30 && pnKcal > 1) {
        final dayFromFasting = i + 1; // chartOrigin=絶食開始 → i番目はDay(i+1)
        if (dayFromFasting > pnHeavyMaxDay) pnHeavyMaxDay = dayFromFasting;
      }
    }
    final pnMonitorRisk = pnHeavyMaxDay >= 7;

    // Refeeding（NICE）リスク: 絶食日数(preDays)とBMIから判定。
    final refeedTier = _refeedingTier;
    final refeedRisk = refeedTier != cr.RefeedingTier.none;
    // 電解質・微量元素・ビタミンのUL超過: 日毎に集計し栄養素ごとに最高レベル/最早日を採用。
    final microByNutrient = <String, ({cm.MicroAlert alert, int dayIdx})>{};
    for (int i = 0; i < n; i++) {
      for (final a in _dayMicroAlerts(plans[i])) {
        final prev = microByNutrient[a.nutrient];
        if (prev == null || a.level.index > prev.alert.level.index) {
          microByNutrient[a.nutrient] = (alert: a, dayIdx: i);
        }
      }
    }
    final microAlertsList = microByNutrient.values.toList();
    final hasAlerts = efadRisk ||
        thiamineRisk ||
        pnMonitorRisk ||
        refeedRisk ||
        microAlertsList.isNotEmpty;
    final alertCount = (efadRisk ? 1 : 0) +
        (thiamineRisk && !refeedRisk ? 1 : 0) +
        (pnMonitorRisk ? 1 : 0) +
        (refeedRisk ? 1 : 0) +
        microAlertsList.length;

    // 日付ラベル: 同月内は日のみ, 月が変わる初日はmm/dd
    final dates = List.generate(n, (i) => chartOrigin.add(Duration(days: i)));
    String dateLabel(int i) {
      if (i == 0) return '${dates[i].month}/${dates[i].day}';
      if (dates[i].month != dates[i - 1].month) {
        return '${dates[i].month}/${dates[i].day}';
      }
      return '${dates[i].day}';
    }
    // 後方互換
    String mmdd(int i) => dateLabel(i);
    final maxKcal =
        plans.map((p) => p.totalKcal).fold<double>(1, (a, b) => a > b ? a : b) * 1.1;
    final maxIn = ins.fold<double>(1, (a, b) => a > b ? a : b) * 1.1;
    // IN(水分量)のピーク値とそのDay（ピーク注記線・ラベル用）
    double inPeakVal = 0;
    int inPeakIdx = 0;
    for (var i = 0; i < ins.length; i++) {
      if (ins[i] > inPeakVal) {
        inPeakVal = ins[i];
        inPeakIdx = i;
      }
    }
    final maxAA = prots.fold<double>(1, (a, b) => a > b ? a : b) * 1.15;
    const hidden = AxisTitles(sideTitles: SideTitles(showTitles: false));
    // 特別日インデックス
    final fastingIdx   = (widget.current.fastingDate != null) ? 0 : -1;
    final admissionEntry = widget.current.bedHistory
        .where((b) => b.fromBed == null)
        .firstOrNull;
    final admissionRaw = admissionEntry != null
        ? DateTime.tryParse(admissionEntry.changedAt)
        : null;
    final admissionIdx = admissionRaw != null
        ? DateTime(admissionRaw.year, admissionRaw.month, admissionRaw.day)
            .difference(chartOrigin)
            .inDays
        : -1;
    final admissionIdxClamped =
        (admissionIdx >= 0 && admissionIdx < n) ? admissionIdx : -1;
    final nutritionIdx = preDays;
    // full nutrition達成日: 各日目標が本来full(realFull)に到達する最初の日。
    final _realFullRef = NutritionCalculator.targetEnergy(widget.current);
    int _fullDay = _totalDays > 0 ? _totalDays : 1;
    for (int d = 1; d <= _totalDays; d++) {
      if (_acutePhaseTarget(d - 1).kcal >= _realFullRef * 0.995) {
        _fullDay = d;
        break;
      }
    }
    final fullIdx      = (preDays + _fullDay - 1).clamp(0, n - 1);
    final enIdx        = (preDays + _enStartDay - 1).clamp(0, n - 1);
    final oralIdx      = (_oralRehabStartDay != null &&
            preDays + _oralRehabStartDay! - 1 < n)
        ? preDays + _oralRehabStartDay! - 1
        : -1;

    // 日付＋イベントアイコンのセル（グラフ下の独立Rowで使用）
    Widget dateCell(int i) {
      if (i < 0 || i >= n) return const SizedBox.shrink();

      // 同日イベントを収集して縦並べ
      // 表示順(上→下): 絶食 > 入室 > 栄養開始 > EN > full (EN/full同日はEN上)
      final List<bool> flags = [
        i == fastingIdx,
        i == admissionIdxClamped,
        i == nutritionIdx,
        i == enIdx && i >= preDays,
        i == fullIdx && i >= preDays,
        i == oralIdx && oralIdx >= 0,
      ];
      final bool hasEvent = flags.any((f) => f);
      final int evCount = flags.where((f) => f).length;
      final double fs = evCount >= 2 ? 12.0 : 15.0; // boxラベル文字/アイコンサイズ

      // 入室からの経過日数(入室=0)。5の倍数(day5/10/15…)を丸囲み対象にする
      final int daysFromAdm =
          admissionIdxClamped >= 0 ? i - admissionIdxClamped : -999;
      final bool mult5FromAdm = daysFromAdm > 0 && daysFromAdm % 5 == 0;

      // 横幅が詰まっているとき(セル幅が狭い)は、日付ラベルを
      // 「イベント日」または「入室後5の倍数の日」のみに間引く
      //  (入室未設定時は従来どおり暦日の5の倍数で間引く)
      final double cellW = n > 0 ? _cachedChartW / n : 999;
      final bool cramped = cellW < 30;
      final bool showDate = !cramped ||
          hasEvent ||
          mult5FromAdm ||
          (admissionIdxClamped < 0 && dates[i].day % 5 == 0);

      // 横幅をはみ出しても折り返さない（横方向の制約を外す）
      Widget noWrap(Widget child) => UnconstrainedBox(
            constrainedAxis: Axis.vertical,
            clipBehavior: Clip.none,
            child: child,
          );

      Widget mkBox(String t, Color c) => noWrap(Container(
            padding: EdgeInsets.symmetric(
                horizontal: evCount >= 2 ? 2 : 3,
                vertical: evCount >= 2 ? 0.5 : 1),
            decoration: BoxDecoration(
              border: Border.all(color: c, width: 0.9),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(t,
                softWrap: false,
                maxLines: 1,
                overflow: TextOverflow.visible,
                style: TextStyle(
                    fontSize: fs,
                    color: c,
                    fontWeight: FontWeight.bold,
                    height: 1.2)),
          ));

      // Material アイコンを四角囲みにする（mkBoxと同じ枠スタイル）
      Widget mkIconBox(IconData icon, Color c) => noWrap(Container(
            padding: EdgeInsets.all(evCount >= 2 ? 1 : 1.5),
            decoration: BoxDecoration(
              border: Border.all(color: c, width: 0.9),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Icon(icon, size: fs, color: c),
          ));

      final evWidgets = [
        if (flags[0]) mkIconBox(Icons.no_meals,   Colors.red.shade400),
        if (flags[1]) mkIconBox(Icons.bed,         Colors.blueGrey.shade400),
        // 栄養開始(=PN/輸液開始)は点滴(water_drop)アイコン。
        if (flags[2]) mkIconBox(Icons.water_drop,  Colors.blue.shade600),
        if (flags[3]) mkBox('EN',   Colors.amber.shade500),
        if (flags[4]) mkBox('full', Colors.green.shade700),
        // 経口リハ開始(濃厚流動食・栄サポ食品・一般食)はフォーク&ナイフアイコン。
        if (flags[5]) mkIconBox(Icons.restaurant,  Colors.deepOrange.shade400),
      ];

      Widget? icon;
      if (evWidgets.length == 1) {
        icon = evWidgets.first;
      } else if (evWidgets.length >= 2) {
        icon = Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: evWidgets,
        );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8), // バーと日付の間隔
          // 日付ラベル領域は固定高(22)。丸囲みの有無でアイコン位置がずれないように揃える
          SizedBox(
            height: 22,
            child: Center(
              child: !showDate
                  ? const SizedBox.shrink()
                  : mult5FromAdm
                      // 入室後day5の倍数は「円」で強調(楕円ではなく真円)
                      ? noWrap(Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.blueGrey.shade400, width: 1.2),
                          ),
                          child: Text(dateLabel(i),
                              softWrap: false,
                              maxLines: 1,
                              overflow: TextOverflow.visible,
                              style: TextStyle(
                                  fontSize: 12,
                                  letterSpacing: -0.5,
                                  height: 1.0,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueGrey.shade700)),
                        ))
                      : noWrap(Text(dateLabel(i),
                          softWrap: false,
                          maxLines: 1,
                          overflow: TextOverflow.visible,
                          style: const TextStyle(
                              fontSize: 14,
                              letterSpacing: -0.5,
                              height: 1.0))),
            ),
          ),
          const SizedBox(height: 8), // 日付とスタンプの間隔
          if (icon != null) icon else const SizedBox(height: 20),
        ],
      );
    }

    // 共通の透明な線グラフビルダー（タイトルなし・全4辺hidden）
    LineChart lineLayer(List<double> ys, double maxY, Color color) =>
        LineChart(LineChartData(
          minX: -0.5,
          maxX: n - 0.5,
          minY: 0,
          maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < n; i++) FlSpot(i.toDouble(), ys[i])],
              color: color,
              barWidth: 2.5,
              dotData: FlDotData(
                show: true,
                getDotPainter: (s, p, b, idx) => FlDotCirclePainter(
                    radius: 3, color: color, strokeWidth: 0),
              ),
            ),
          ],
          titlesData: const FlTitlesData(
            bottomTitles: hidden,
            leftTitles: hidden,
            topTitles: hidden,
            rightTitles: hidden,
          ),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          clipData: const FlClipData.all(),
          lineTouchData: const LineTouchData(enabled: false),
        ));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('トレンド',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: Icon(
                    _trendCollapsed ? Icons.expand_less : Icons.expand_more,
                    size: 22),
                tooltip: _trendCollapsed ? '展開' : '折りたたむ',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _trendCollapsed = !_trendCollapsed),
              ),
            ]),
            if (!_trendCollapsed) const SizedBox(height: 8),
            if (!_trendCollapsed)
            TapRegion(
              // チャート外タップでフローターを消去
              onTapOutside: (_) {
                if (_selectedBarIdx >= 0) {
                  setState(() { _selectedBarIdx = -1; _hoveredBarIdx = -1; });
                  widget.onSettingsChanged?.call();
                }
              },
              child: SizedBox(
              height: 250,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (n == 0) return;
                  final barWidth = _cachedChartW / n;
                  final idx = (details.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
                  setState(() { _selectedBarIdx = idx; });
                  widget.onSettingsChanged?.call();
                },
                child: MouseRegion(
                onHover: (e) {
                  if (n == 0) return;
                  final barWidth = _cachedChartW / n;
                  final idx = (e.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
                  if (idx != _hoveredBarIdx) {
                    setState(() => _hoveredBarIdx = idx);
                    widget.onSettingsChanged?.call();
                  }
                },
                onExit: (_) {
                  setState(() => _hoveredBarIdx = -1);
                  widget.onSettingsChanged?.call();
                },
                child: LayoutBuilder(builder: (_, _lbc) {
                  _cachedChartW = _lbc.maxWidth;
                  const plotH = 184.0; // プロット領域(棒・線)の高さ
                  const axisH = 66.0;  // 日付＋アイコン軸の高さ
                  return Column(
                    children: [
                      // === プロット領域: 棒グラフ・線グラフを同一184px領域に重ねる ===
                      // 棒も線も同じ高さの箱に置くので、ゼロ基線(=底辺)が物理的に完全一致する
                      SizedBox(
                        height: plotH,
                        child: ClipRect(
                          child: Stack(
                            children: [
                              // ① 積み上げ棒: カロリー内訳 (下→上: PN→EN→食事)
                              BarChart(BarChartData(
                                alignment: BarChartAlignment.spaceAround,
                                minY: 0,
                                maxY: maxKcal,
                                barTouchData: BarTouchData(enabled: false),
                                barGroups: List.generate(n, (i) {
                                  final enK = enKcals[i];
                                  final mealK = mealKcals[i];
                                  final total = plans[i].totalKcal;
                                  return BarChartGroupData(x: i, barRods: [
                                    BarChartRodData(
                                      toY: total,
                                      width: 16,
                                      borderRadius: BorderRadius.circular(2),
                                      rodStackItems: [
                                        // 下: 食事(橙) — 淡め
                                        BarChartRodStackItem(0, mealK,
                                            Colors.deepOrange.shade200),
                                        // 中: EN(黄) — 暗めのアンバー(白背景との視認性確保)
                                        BarChartRodStackItem(mealK, mealK + enK,
                                            Colors.amber.shade500),
                                        // 上: PN(緑) — 淡め
                                        BarChartRodStackItem(mealK + enK, total,
                                            Colors.green.shade200),
                                      ],
                                    ),
                                  ]);
                                }),
                                titlesData: const FlTitlesData(
                                  bottomTitles: hidden,
                                  leftTitles: hidden,
                                  topTitles: hidden,
                                  rightTitles: hidden,
                                ),
                                gridData: const FlGridData(show: false),
                                borderData: FlBorderData(show: false),
                              )),
                              // ② 合計IN ③ AA — 棒と同じ箱に重ねる
                              lineLayer(ins, maxIn, Colors.blue.shade600),
                              // IN最高点の注記: ±1日分の淡い水平線 + _ml ラベル
                              if (inPeakVal > 0) ...[
                                LineChart(LineChartData(
                                  minX: -0.5,
                                  maxX: n - 0.5,
                                  minY: 0,
                                  maxY: maxIn,
                                  lineBarsData: [
                                    LineChartBarData(
                                      spots: [
                                        FlSpot((inPeakIdx - 1).toDouble(), inPeakVal),
                                        FlSpot(inPeakIdx.toDouble(), inPeakVal),
                                        FlSpot((inPeakIdx + 1).toDouble(), inPeakVal),
                                      ],
                                      gradient: LinearGradient(colors: [
                                        Colors.blueGrey.shade700.withValues(alpha: 0.0),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.9),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.9),
                                        Colors.blueGrey.shade700.withValues(alpha: 0.0),
                                      ], stops: const [0.0, 0.35, 0.65, 1.0]),
                                      barWidth: 2,
                                      dotData: const FlDotData(show: false),
                                    ),
                                  ],
                                  titlesData: const FlTitlesData(
                                    bottomTitles: hidden,
                                    leftTitles: hidden,
                                    topTitles: hidden,
                                    rightTitles: hidden,
                                  ),
                                  gridData: const FlGridData(show: false),
                                  borderData: FlBorderData(show: false),
                                  clipData: const FlClipData.all(),
                                  lineTouchData: const LineTouchData(enabled: false),
                                )),
                                Positioned(
                                  left: ((_cachedChartW / n) * inPeakIdx +
                                          (_cachedChartW / n) / 2) -
                                      32,
                                  // 線とテキストの間隔をグラフ↔日付と同じ8pxにする
                                  top: (plotH * (1.0 - (inPeakVal / maxIn)) - 22)
                                      .clamp(0.0, plotH - 16),
                                  child: SizedBox(
                                    width: 64,
                                    child: Text(
                                      '${inPeakVal.round()}ml',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 14,
                                          height: 1.0,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.blueGrey.shade700),
                                    ),
                                  ),
                                ),
                              ],
                              lineLayer(prots, maxAA, Colors.red.shade400),
                              // フローター: タップ固定優先、次いでホバー
                              Builder(builder: (ctx) {
                                final displayIdx = _selectedBarIdx >= 0
                                    ? _selectedBarIdx
                                    : _hoveredBarIdx;
                                if (displayIdx < 0 || displayIdx >= n) {
                                  return const SizedBox.shrink();
                                }
                                final idx = displayIdx;
                                final plan = plans[idx];
                                final w = widget.current.weightKg;
                                final isPinned = _selectedBarIdx >= 0;
                                final barRatio = maxKcal > 0
                                    ? (plans[idx].totalKcal / maxKcal)
                                        .clamp(0.0, 1.0)
                                    : 0.0;
                                final barTopY = plotH * (1.0 - barRatio) - 8;
                                final chartW = _cachedChartW;
                                final barW = chartW / n;
                                final barCenterX = barW * idx + barW / 2;
                                const tipW = 156.0;
                                final tipX = (barCenterX - tipW / 2)
                                    .clamp(0.0, chartW - tipW);
                                final mmdd =
                                    '${dates[idx].month.toString().padLeft(2, '0')}/${dates[idx].day.toString().padLeft(2, '0')}';
                                return Positioned(
                                  left: tipX,
                                  top: barTopY.clamp(0.0, plotH - 60),
                                  child: Container(
                                    width: tipW,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 9, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: isPinned
                                          ? const Color(0xFFF0F4FF)
                                          : const Color(0xFFFFF8E7),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: isPinned
                                              ? Colors.blue.shade200
                                              : Colors.brown.shade200,
                                          width: 0.6),
                                      boxShadow: const [
                                        BoxShadow(
                                            color: Colors.black26,
                                            blurRadius: 4,
                                            offset: Offset(1, 2)),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(mmdd,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold)),
                                        if (plan.items.isEmpty)
                                          const Text('栄養開始前',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey))
                                        else ...[
                                          Text(
                                              'IN ${plan.totalVolumeMl.round()}ml, ${plan.totalKcal.round()}kcal',
                                              style: const TextStyle(
                                                  fontSize: 11)),
                                          Text(
                                              'AA ${plan.totalProteinG.toStringAsFixed(1)}g'
                                              '${w > 0 ? ' (${(plan.totalProteinG / w).toStringAsFixed(2)}g/kg)' : ''}',
                                              style: const TextStyle(
                                                  fontSize: 11)),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              }),
                              // 凡例カード（プロット領域の上下中央・左寄せ）
                              Positioned(
                                left: 10,
                                top: 0,
                                bottom: 0,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.88),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: Colors.black12, width: 0.8),
                                      boxShadow: const [
                                        BoxShadow(
                                            color: Colors.black12,
                                            blurRadius: 4,
                                            offset: Offset(0, 1)),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _legItem(Colors.deepOrange.shade200,
                                            '食事 (kcal)', false),
                                        _legItem(Colors.amber.shade500,
                                            'EN (kcal)', false),
                                        _legItem(Colors.green.shade200,
                                            'PN (kcal)', false),
                                        _legItem(Colors.blue.shade600,
                                            'IN (ml)', true),
                                        _legItem(Colors.red.shade400,
                                            'AA (g)', true),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // === 日付＋イベントアイコン軸（棒・線と独立した別Row） ===
                      SizedBox(
                        height: axisH,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < n; i++)
                              Expanded(child: dateCell(i)),
                          ],
                        ),
                      ),
                    ],
                  );
                }), // Column / LayoutBuilder
              ), // MouseRegion
              ), // GestureDetector
              ), // SizedBox
            ), // TapRegion
            // === 栄養管理アラート（グラフの下・既定は折り畳み、タップで展開） ===
            if (hasAlerts) ...[
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() => _alertsExpanded = !_alertsExpanded);
                  widget.onSettingsChanged?.call();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.notifications_active_outlined,
                        size: 16, color: Colors.deepOrange),
                    const SizedBox(width: 4),
                    const Text('リスクと補充サジェスト',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.black54)),
                    const SizedBox(width: 6),
                    // アラート件数バッジ
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: Colors.deepOrange.shade200),
                      ),
                      child: Text(
                          '$alertCount件',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange.shade700)),
                    ),
                    const Spacer(),
                    Icon(
                        _alertsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: Colors.black45),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_alertsExpanded && efadRisk)
              _chartAlert(
                color: Colors.orange.shade800,
                title: '${_alertDate(14, dates, n)}以降　必須脂肪酸欠乏のリスク',
                body:
                    '絶食開始からDay14まで脂質の投与がありません。長期化で必須脂肪酸が欠乏します。'
                    '脂肪乳剤を開始してください。',
                suggest: 'イントラリポス20% 100mL/日（脂質20g）を補充'
                    '（または週2回100mL）',
              ),
            if (_alertsExpanded && thiamineRisk && !refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title: '${_alertDate(preDays + 1, dates, n)}以降（栄養再開・糖負荷時）'
                    '　リフィーディング/Wernicke脳症のリスク',
                body:
                    '絶食5日以上＋糖質投与でビタミンB1の需要が増大し欠乏しうる'
                    '（貯蔵は約2週間で枯渇）。糖負荷の前〜同時に補充してください。',
                suggest: 'ビタミンB1（チアミン）100〜300mg/日を静注で補充',
              ),
            if (_alertsExpanded && pnMonitorRisk)
              _chartAlert(
                color: Colors.teal.shade700,
                title:
                    '${_alertDate(pnHeavyMaxDay, dates, n)}以降（PN主体がDay$pnHeavyMaxDayまで継続）'
                    '　電解質・微量元素の過不足に注意',
                body:
                    'EN≤30ml/hでPN主体の状態が続きます。'
                    'P・K・Mg・亜鉛・ビタミンの過不足が生じやすい時期です。'
                    '採血検査を追加して確認してください。',
                suggest: '不足時は リン酸Na/KCL/硫酸Mg補正液・微量元素製剤・'
                    '総合ビタミン剤 で補正',
              ),
            if (_alertsExpanded && refeedRisk)
              _chartAlert(
                color: Colors.red.shade700,
                title:
                    '${_alertDate(preDays + 1, dates, n)}以降（栄養再開初期）'
                        '　Refeeding症候群 ${refeedTier.label}（NICE）',
                body:
                    '絶食$preDays日・BMI ${cbw.bmiOf(widget.current.weightKg, widget.current.heightCm).toStringAsFixed(1)}。'
                    '初期は10 kcal/kg（超高リスクは5）から開始し4–7日で漸増します'
                    '（本設計は自動でcap済み）。',
                suggest: cr.refeedingActionText(refeedTier),
              ),
            for (final m in microAlertsList)
              if (_alertsExpanded)
                _chartAlert(
                  color: m.alert.level == ci.AlertLevel.danger
                      ? Colors.red.shade700
                      : Colors.orange.shade800,
                  title:
                      '${_alertDate(m.dayIdx + 1, dates, n)}以降　${m.alert.nutrient} 過剰のリスク',
                  body: m.alert.message,
                ),
          ],
        ),
      ),
    );
  }

  // Dayカードのタップで処方詳細(何を何pac)をダイアログ表示
  Widget _legItem(Color c, String lbl, bool line) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      // マーカーを固定幅スロットに収め、テキストの左位置を全項目で揃える
      SizedBox(
        width: 18,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: line ? 18 : 13,
            height: line ? 3.5 : 13,
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(2)),
          ),
        ),
      ),
      const SizedBox(width: 5),
      Text(lbl,
          style: const TextStyle(
              fontSize: 13, color: Colors.black54, height: 1.3)),
    ]),
  );

  /// アラート用の日付文字列 (chartOrigin起算のDay番号 → ○月○日)
  String _alertDate(int dayNum, List<DateTime> dates, int n) {
    if (dates.isEmpty) return '';
    final idx = (dayNum - 1).clamp(0, n - 1);
    return '${dates[idx].month}月${dates[idx].day}日';
  }

  /// 栄養管理アラート用の共通バナー
  /// title=「○月○日以降 …リスク」, body=対処, suggest=補充する製剤/成分+量
  Widget _chartAlert({
    required Color color,
    required String title,
    required String body,
    String? suggest,
  }) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: '$title\n',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: color,
                            fontSize: 12.5,
                            height: 1.4)),
                    TextSpan(
                        text: body,
                        style: TextStyle(
                            color: color, fontSize: 11.5, height: 1.4)),
                  ])),
                  if (suggest != null) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.add_circle_outline,
                              size: 15, color: color),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(suggest,
                                style: TextStyle(
                                    color: color,
                                    fontSize: 11.5,
                                    height: 1.35,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  void _showDayDetail(int i, DesignPlan plan, double dayKcal, double dayProt) {
    final date = _dateOf(i);
    final mode = _dayModes[i];
    final dose = _dayEnDose[i];
    final mealPac = _pacOf(dose) > 0 ? (_pacOf(dose) / 3).round() : 0;
    final isZero = mode == 'ZERO' || plan.label == 'ZERO';
    final w = widget.current.weightKg;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$date (Day${i + 1}) の処方',
            style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _planBody(plan, dayKcal, dayProt, mode),
              const Divider(height: 16),
              const SizedBox(height: 2),
              Text('当日目標 ${dayKcal.round()}kcal / タンパク ${dayProt.round()}g',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる')),
        ],
      ),
    );
  }

  /// 日次処方カードのモードバッジ（プラン内容に応じて 食事/EN/PN を横並び表示）
  Widget _modeBadges(DesignPlan plan) {
    final mealK = _mealKcalOfPlan(plan);
    final enK = _enKcalOfPlan(plan);
    final pnK = (plan.totalKcal - mealK - enK);
    final isZero = plan.label == 'ZERO';
    Widget badge(String label, Color color) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.bold)),
        );
    final badges = <Widget>[];
    if (mealK > 1) badges.add(badge('食事', Colors.deepOrange.shade400));
    if (enK > 1) badges.add(badge('EN', Colors.amber.shade500));
    if (pnK > 1) {
      badges.add(badge(isZero ? 'ゼロmenu' : 'PN', Colors.blue));
    }
    if (badges.isEmpty) badges.add(badge('—', Colors.grey));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < badges.length; i++) ...[
        if (i > 0) const SizedBox(width: 4),
        badges[i],
      ],
    ]);
  }

  Widget _planBody(
      DesignPlan plan, double targetKcal, double targetProt, String mode) {
    if (plan.items.isEmpty) {
      return const Text('（条件を満たす組み合わせなし）',
          style: TextStyle(color: Colors.red, fontSize: 12));
    }
    final w = widget.current.weightKg;
    final protPerKg = w > 0 ? plan.totalProteinG / w : 0.0;
    final isZero = mode == 'ZERO' || plan.label == 'ZERO';
    const ts = TextStyle(fontSize: 12.5);
    final children = <Widget>[];
    double pnRoundDelta = 0; // PNを10ml丸めしたことによるIN補正
    Widget line(String s, {TextStyle style = ts}) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(s, style: style));

    if (isZero) {
      for (final it in plan.items) {
        children.add(line('${it.name}  ${it.volumeMl.round()}ml'));
      }
    } else {
      double tpnVol = 0, ppnVol = 0; // 10ml丸め後
      double tpnOrig = 0, ppnOrig = 0;
      double r10(double v) => (v / 10).round() * 10.0;
      final tpnNames = <String>[], ppnNames = <String>[];
      for (final it in plan.items) {
        final p = widget.state.catalog.byName(it.name);
        final cat = p?.category;
        final isFood = p?.isFood ?? false;
        if (isFood) {
          // 食事: 経口摂取(嚥下リハ)なので流量指定なし。合計容量 ml/day のみ
          final n = it.units != null ? '${it.units}本 ' : '';
          children.add(line('${it.name}  $n(${it.volumeMl.round()}ml/day)'));
        } else if (cat == 'EN' || cat == 'EN_AUX') {
          if (it.units != null) {
            final mealPac = (it.units! / 3).round().clamp(1, it.units!);
            children.add(line(
                '${it.name}  朝昼夕${mealPac}pac (${it.volumeMl.round()}ml/day)'));
          } else {
            final rateMlH = it.volumeMl / 24;
            final pacPerExchange =
                (rateMlH * 8 / (p?.volumeMl ?? 200)).ceil();
            children.add(line(
                '${it.name}  ${rateMlH.toStringAsFixed(0)}ml/h  朝昼夕${pacPerExchange}pac'));
          }
        } else if (cat == 'TPN') {
          final v10 = r10(it.volumeMl);
          tpnVol += v10;
          tpnOrig += it.volumeMl;
          final u = it.units != null ? '${it.units}本 ' : '';
          tpnNames.add('${it.name}  $u(${v10.round()}ml)');
        } else if (cat == 'PPN') {
          final v10 = r10(it.volumeMl);
          ppnVol += v10;
          ppnOrig += it.volumeMl;
          final u = it.units != null ? '${it.units}本 ' : '';
          ppnNames.add('${it.name}  $u(${v10.round()}ml)');
        } else {
          children.add(line(it.name));
        }
      }
      pnRoundDelta = (tpnVol + ppnVol) - (tpnOrig + ppnOrig);
      // TPN / PPN はそれぞれまとめて別々に流量表記
      if (tpnVol > 0) {
        children.add(line(
            'TPN  ${(tpnVol / 24).toStringAsFixed(0)}ml/h（計${tpnVol.round()}ml）',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade700)));
        for (final s in tpnNames) {
          children.add(line('　$s'));
        }
      }
      if (ppnVol > 0) {
        children.add(line(
            'PPN  ${(ppnVol / 24).toStringAsFixed(0)}ml/h（計${ppnVol.round()}ml）',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.cyan.shade700)));
        for (final s in ppnNames) {
          children.add(line('　$s'));
        }
      }
    }
    children.add(const SizedBox(height: 4));
    children.add(Text(
      'IN ${(plan.totalVolumeMl + pnRoundDelta).round()}ml, 熱量 ${plan.totalKcal.round()}kcal, '
      'タンパク ${plan.totalProteinG.toStringAsFixed(1)}g (${protPerKg.toStringAsFixed(1)}g/kg)',
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
    ));
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

}

class _LegendChip extends StatelessWidget {
  const _LegendChip(
      {required this.color, required this.label, required this.line});
  final Color color;
  final String label;
  final bool line;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: line ? 16 : 12,
            height: line ? 3 : 12,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}
