import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';

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
      title: 'やさしい栄養処方 NutriCalc',
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
        title: const Text('やさしい栄養処方 NutriCalc'),
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
    return GestureDetector(
      onHorizontalDragEnd: (_) {
        state.selectedCaseId = item.id;
        refresh();
        Navigator.of(context).push(MaterialPageRoute(
            builder: (c) => BuilderPage(state: state, refresh: refresh)));
      },
      child: Card(
        child: InkWell(
          onTap: () {
            state.selectedCaseId = item.id;
            refresh();
            Navigator.of(context).push(MaterialPageRoute(
                builder: (c) => BuilderPage(state: state, refresh: refresh)));
          },
          onLongPress: () {
            state.selectedCaseId = item.id;
            refresh();
            Navigator.of(context).push(MaterialPageRoute(
                builder: (c) => BuilderPage(state: state, refresh: refresh)));
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _editCaseCode(context, item),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 1行目: 患者No / ベッド / 入室日
                            Builder(builder: (ctx) {
                              final admission = item.bedHistory.where((b) => b.fromBed == null).firstOrNull;
                              final admDate = admission == null ? '' : (() {
                                final p = DateTime.tryParse(admission.changedAt);
                                return p == null ? admission.changedAt
                                    : '${p.year}/${p.month.toString().padLeft(2,'0')}/${p.day.toString().padLeft(2,'0')}';
                              })();
                              return Row(
                                children: [
                                  const Icon(Icons.person, size: 16),
                                  const SizedBox(width: 2),
                                  Text(item.caseCode,
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 10),
                                  const Icon(Icons.bed, size: 16, color: Colors.grey),
                                  const SizedBox(width: 2),
                                  Text(item.currentBed,
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                  if (admDate.isNotEmpty) ...[
                                    const SizedBox(width: 10),
                                    const Icon(Icons.login, size: 14, color: Colors.grey),
                                    const SizedBox(width: 2),
                                    Text(admDate, style: const TextStyle(fontSize: 13, color: Colors.grey)),
                                  ],
                                ],
                              );
                            }),
                            const SizedBox(height: 2),
                            Text(item.patientInfoLine,
                                style: const TextStyle(fontSize: 14)),
                            if (item.memo.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(item.memo,
                                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ],
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () {
                        state.selectedCaseId = item.id;
                        refresh();
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (c) => BuilderPage(state: state, refresh: refresh)));
                      },
                      child: const Text('計算'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _dischargeCase(context, item),
                      child: const Text('退室'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
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
    Sex sex = Sex.male;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final bedPad = bedIndex.toString().padLeft(2, '0');
          final isConflict = state.cases.any((c) => c.currentBed == bedPad);
          return AlertDialog(
          title: const Text('新規入室'),
          content: SingleChildScrollView(
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
                  ],
                ),
                TextField(
                    controller: age,
                    decoration: const InputDecoration(labelText: '年齢'),
                    keyboardType: TextInputType.number),
                TextField(
                    controller: height,
                    decoration: const InputDecoration(labelText: '身長 cm'),
                    keyboardType: TextInputType.number),
                TextField(
                    controller: weight,
                    decoration: const InputDecoration(labelText: '体重 kg'),
                    keyboardType: TextInputType.number),
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
                DropdownButtonFormField<double>(
                  initialValue: activity,
                  decoration: const InputDecoration(labelText: '活動係数'),
                  items: [for (var i = 0; i < 7; i++) _factorItem(1.0 + i * 0.1, _afHints)],
                  selectedItemBuilder: (context) => [
                    for (var i = 0; i < 7; i++)
                      Align(alignment: Alignment.centerLeft,
                            child: Text((1.0 + i * 0.1).toStringAsFixed(1))),
                  ],
                  onChanged: (v) => setLocal(() => activity = v ?? activity),
                ),
                DropdownButtonFormField<double>(
                  initialValue: stress,
                  decoration: const InputDecoration(labelText: '侵害係数'),
                  items: [for (var i = 0; i < 13; i++) _factorItem(0.9 + i * 0.1, _sfHints)],
                  selectedItemBuilder: (context) => [
                    for (var i = 0; i < 13; i++)
                      Align(alignment: Alignment.centerLeft,
                            child: Text((0.9 + i * 0.1).toStringAsFixed(1))),
                  ],
                  onChanged: (v) => setLocal(() => stress = v ?? stress),
                ),
                SliderWithLabel(
                    label: '目標蛋白 g/kg/day',
                    value: protein,
                    min: 0.6,
                    max: 2.0,
                    onChanged: (v) => setLocal(() => protein = v)),
              ],
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
                );
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
                // 入室日時
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
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
  final targetKcalController = TextEditingController(text: '1500');
  final npcnController = TextEditingController(text: '125');
  double _lipidGPerKg = 0.4;
  String glucoseSource = '70% グルコース';
  String lipidSource = 'イントラリポス20%';
  final Set<String> expandedProducts = {};
  double _enRateMlPerHour = 0;
  double _tpnRateMlPerHour = 0; // 後方互換: processCategory で使用 (内部のみ)
  double _ppnRateMlPerHour = 0; // 後方互換: processCategory で使用 (内部のみ)
  // PN使用量指定 (0 = 全量, >0 = ml指定)
  double _tpnVolumeMl = 0;
  double _ppnVolumeMl = 0;

  @override
  void initState() {
    super.initState();
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

  /// TPN/PPN使用量ml指定時にpac数を更新 (EN同様の自動調整)
  void _adjustPnUnitsForVolume(PatientCase current, String cat, double volumeMl) {
    for (final item in current.regimenItems.toList()) {
      final product = widget.state.catalog.byId(item.productId);
      if (product == null || product.category != cat) continue;
      final vol = product.volumeMl ?? 0;
      if (vol <= 0) continue;
      final needed = volumeMl <= 0
          ? item.units // 全量 → 変更なし(現在のpac数を維持)
          : (volumeMl / vol).ceil().clamp(1, 20);
      if (item.units > 0 && item.units != needed && volumeMl > 0) {
        widget.state.setUnits(current.id, product, needed);
      }
    }
    setState(() {});
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
        if (unitsOf(item) <= 0) return false;
        if (categoryKey == 'EN') {
          return product.category == 'EN' || product.category == 'EN_AUX';
        }
        return product.category == categoryKey;
      }).toList();

      // 製剤が選ばれていなければ投与速度を動かしても何も加算しない
      if (selectedItems.isEmpty) return;

      // 全量での集計（本数ベース）— Excel T19/T20/T21/T23 に対応
      double fullIN = 0, fullKcal = 0, fullProt = 0, fullFatG = 0, fullCarbG = 0;
      for (final item in selectedItems) {
        final product = widget.state.catalog.byId(item.productId)!;
        final n = unitsOf(item);
        fullIN += (product.volumeMl ?? 0) * n;
        fullKcal += (product.kcal ?? 0) * n;
        fullProt += (product.aminoAcidG ?? 0) * n;
        fullFatG += (product.fatBase ?? 0) * n;
        fullCarbG += (product.carbBase ?? 0) * n;
      }

      // 投与速度指定時は「一部投与」の按分係数をかける（Excel T26/T19）
      final factor = (rate > 0 && fullIN > 0) ? (rate * 24) / fullIN : 1.0;

      totalVolumeMl += fullIN * factor;
      totalKcal += fullKcal * factor;
      totalProteinG += fullProt * factor;
      totalFatG += fullFatG * factor;
      fatKcal += fullFatG * 9 * factor;
      carbKcal += fullCarbG * 4 * factor;
      proteinKcal += fullProt * 4 * factor;
    }

    // TPN/PPNは使用量ml指定(0=全量)を速度換算して按分
    _tpnRateMlPerHour = _tpnVolumeMl > 0 ? _tpnVolumeMl / 24 : 0;
    _ppnRateMlPerHour = _ppnVolumeMl > 0 ? _ppnVolumeMl / 24 : 0;
    processCategory('EN', _enRateMlPerHour);
    processCategory('TPN', _tpnRateMlPerHour);
    processCategory('PPN', _ppnRateMlPerHour);

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
      glucoseProduct: widget.state.catalog.byName(glucoseSource),
      aminoProduct: widget.state.catalog.byName('アミパレン'),
      lipidProduct: widget.state.catalog.byName(lipidSource),
    );
    final scratchAggregate = _aggregateFromVolumes(
      [
        widget.state.catalog.byName('アミパレン'),
        widget.state.catalog.byName(glucoseSource),
        widget.state.catalog.byName(lipidSource),
      ],
      [
        zeroMenu.aminoVolumeMl,
        zeroMenu.glucoseVolumeMl,
        zeroMenu.lipidVolumeMl
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
        if (widget.state.isFavorite(p.id)) return 4;
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
    final aminoProduct = widget.state.catalog.byName('アミパレン');
    final glucoseProduct = widget.state.catalog.byName(glucoseSource);
    final lipidProduct = widget.state.catalog.byName(lipidSource);
    final scratchTotalVolumeMl = zeroMenu.aminoVolumeMl +
        zeroMenu.glucoseVolumeMl +
        zeroMenu.lipidVolumeMl;
    final scratchInfusionRateMlPerHour = scratchTotalVolumeMl / 24;
    String formatRequiredUnits(Product? product, double requiredMl) {
      if (product == null ||
          product.volumeMl == null ||
          product.volumeMl! <= 0) {
        return '未設定';
      }
      return '${(requiredMl / product.volumeMl!).ceil()} 本';
    }

    final scratchAminoUnits =
        formatRequiredUnits(aminoProduct, zeroMenu.aminoVolumeMl);
    final scratchGlucoseUnits =
        formatRequiredUnits(glucoseProduct, zeroMenu.glucoseVolumeMl);
    final scratchLipidUnits =
        formatRequiredUnits(lipidProduct, zeroMenu.lipidVolumeMl);

    int _actualCategoryUnits(String categoryKey) {
      return current.regimenItems.fold<int>(0, (sum, item) {
        final product = widget.state.catalog.byId(item.productId);
        if (product == null) return sum;
        if (categoryKey == 'EN') {
          if (product.category != 'EN' && product.category != 'EN_AUX')
            return sum;
        } else if (product.category != categoryKey) {
          return sum;
        }
        return sum + item.units;
      });
    }

    Product? _categoryRepresentativeProduct(String categoryKey) {
      final selected = _selectedProductsForCategory(categoryKey);
      if (selected.isEmpty) return null;
      final items = current.regimenItems
          .where((item) => selected.any((p) => p.id == item.productId))
          .where((item) => item.units > 0)
          .toList();
      if (items.isNotEmpty) {
        return widget.state.catalog.byId(items.first.productId);
      }
      return selected.first;
    }

    int _rateCategoryUnits(String categoryKey, double rate) {
      if (rate <= 0) return _actualCategoryUnits(categoryKey);
      final product = _categoryRepresentativeProduct(categoryKey);
      if (product == null || (product.volumeMl ?? 0) <= 0) return 0;
      final dailyVolume = rate * 24;
      return (dailyVolume / (product.volumeMl ?? 1)).ceil();
    }

    double _rateCategoryDailyVolume(String categoryKey, double rate) {
      if (rate <= 0) {
        return current.regimenItems.fold<double>(0, (sum, item) {
          final product = widget.state.catalog.byId(item.productId);
          if (product == null) return sum;
          if (categoryKey == 'EN') {
            if (product.category != 'EN' && product.category != 'EN_AUX')
              return sum;
          } else if (product.category != categoryKey) {
            return sum;
          }
          return sum + (product.volumeMl ?? 0) * item.units;
        });
      }
      return rate * 24;
    }

    final screenH = MediaQuery.of(context).size.height;
    final _mqPad = MediaQuery.of(context).padding;
    // パネルの最大高さ = 画面高さ - ステータスバー - AppBar - ホームインジケータ - パディング16
    final maxSummaryH = (screenH - _mqPad.top - kToolbarHeight - _mqPad.bottom - 16.0)
        .clamp(200.0, screenH);

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
                        onTap: () => _editPatientParams(context, current),
                        child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.person, size: 18),
                                const SizedBox(width: 2),
                                Text(current.caseCode,
                                    style: Theme.of(context).textTheme.titleLarge),
                                const SizedBox(width: 12),
                                const Icon(Icons.bed, size: 18),
                                const SizedBox(width: 2),
                                Text(current.currentBed,
                                    style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              current.patientInfoLine,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '活動係数 ${current.activityFactor.toStringAsFixed(1)}, '
                              '侵害係数 ${current.stressFactor.toStringAsFixed(1)}, '
                              'タンパク目標 ${current.proteinGoalPerKg.toStringAsFixed(1)}g/kg',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            Text(
                              'カロリー ${targetKcal.round()} kcal, '
                              'タンパク ${targetProtein.round()} g/day',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            if (current.memo.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(current.memo,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey)),
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
                    const SizedBox(height: 12),
                    // ゼロmenu タブ
                    Visibility(
                      visible: _builderTabIndex == 1,
                      maintainState: true,
                      child: Builder(builder: (context) {
                        const kVit = 2.0; // ビタミン製剤固定量 ml
                        const kTrace = 2.0; // 微量元素製剤固定量 ml
                        const kElec = 2.0; // 電解質製剤固定量 ml
                        final totalIn = zeroMenu.aminoVolumeMl + zeroMenu.glucoseVolumeMl + zeroMenu.lipidVolumeMl + kVit + kTrace + kElec;
                        final lipidGPerKg = (zeroMenu.lipidGram / current.weightKg);
                        const rowH = 36.0;
                        Widget dataRow(String label, String val, {bool bold = false}) => SizedBox(
                          height: rowH,
                          child: Row(children: [
                            Expanded(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
                            Text(val, style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
                          ]),
                        );
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 左カード: 設定入力
                            Expanded(
                              child: Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('投与目標設定', style: Theme.of(context).textTheme.titleSmall),
                                      const Divider(),
                                      TextField(
                                        controller: targetKcalController,
                                        keyboardType: TextInputType.number,
                                        decoration: InputDecoration(
                                          labelText: '投与カロリー',
                                          suffixText: targetKcalController.text.isNotEmpty ? 'kcal' : null,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
                                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
                                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                        ),
                                        items: [
                                          for (int i = 0; i <= 10; i++)
                                            DropdownMenuItem(
                                              value: i / 10.0,
                                              child: Text((i / 10.0).toStringAsFixed(1)),
                                            ),
                                        ],
                                        onChanged: (v) => setState(() { _lipidGPerKg = v ?? _lipidGPerKg; }),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        value: glucoseSource,
                                        decoration: const InputDecoration(labelText: '糖質', isDense: true),
                                        items: const [
                                          DropdownMenuItem(value: 'ハイカリックRF', child: Text('ハイカリックRF')),
                                          DropdownMenuItem(value: '70% グルコース', child: Text('70% グルコース')),
                                          DropdownMenuItem(value: '8%グルコース', child: Text('8%グルコース')),
                                        ],
                                        onChanged: (v) => setState(() { glucoseSource = v ?? glucoseSource; }),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        value: lipidSource,
                                        decoration: const InputDecoration(labelText: '脂質', isDense: true),
                                        items: const [
                                          DropdownMenuItem(value: 'イントラリポス10%', child: Text('イントラリポス10%')),
                                          DropdownMenuItem(value: 'イントラリポス20%', child: Text('イントラリポス20%')),
                                        ],
                                        onChanged: (v) => setState(() { lipidSource = v ?? lipidSource; }),
                                      ),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        width: double.infinity,
                                        child: FilledButton(
                                          onPressed: () {
                                            current.zeroMenuConfig = ZeroMenuConfig(
                                              targetKcal: double.tryParse(targetKcalController.text) ?? targetKcal,
                                              npcNRatio: double.tryParse(npcnController.text) ?? 125,
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
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 右カード: 計算結果
                            Expanded(
                              child: Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('ゼロmenu 以下', style: Theme.of(context).textTheme.titleSmall),
                                      const Divider(),
                                      dataRow('アミパレン', '${zeroMenu.aminoVolumeMl.round()} ml'),
                                      dataRow(glucoseSource, '${zeroMenu.glucoseVolumeMl.round()} ml'),
                                      dataRow(lipidSource, '${zeroMenu.lipidVolumeMl.round()} ml'),
                                      dataRow('ビタミン製剤', '${kVit.toStringAsFixed(0)} ml'),
                                      dataRow('微量元素製剤', '${kTrace.toStringAsFixed(0)} ml'),
                                      dataRow('電解質製剤', '${kElec.toStringAsFixed(0)} ml'),
                                    ],
                                  ),
                                ),
                              ),
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
                                final effectiveCategory =
                                    activeCategories.contains(category)
                                        ? category
                                        : activeCategories.first;
                                if (effectiveCategory != category) {
                                  WidgetsBinding.instance.addPostFrameCallback(
                                      (_) => setState(
                                          () => category = effectiveCategory));
                                }
                                // EN/TPN/PPN タブ + 流量ドロップダウン（選択中カテゴリに対応）
                                // PN使用量オプション: 全量 + 200-2000ml (100ml刻み)
                                final pnVolumeOptions = <double>[0,
                                  ...List.generate(19, (i) => (i + 2) * 100.0)];
                                String pnVolLabel(double v) =>
                                    v <= 0 ? '全量' : '${v.toInt()}ml';
                                final curPnVol = effectiveCategory == 'TPN'
                                    ? _tpnVolumeMl
                                    : _ppnVolumeMl;
                                // スイッチを画面中央、DDをスイッチ右端〜右壁の中間に配置
                                return Row(
                                  children: [
                                    const Expanded(child: SizedBox()), // 左スペーサー
                                    SizedBox(
                                      width: 160,
                                      child: SegmentedButton<String>(
                                        showSelectedIcon: false,
                                        style: ButtonStyle(
                                          visualDensity: VisualDensity.compact,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        segments: activeCategories
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
                                          child: effectiveCategory == 'EN'
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
                                              value: curPnVol,
                                              isDense: true,
                                              items: pnVolumeOptions
                                                  .map((v) => DropdownMenuItem(
                                                      value: v,
                                                      child: Text(pnVolLabel(v),
                                                          style: const TextStyle(fontSize: 13))))
                                                  .toList(),
                                              onChanged: (v) {
                                                final vol = v ?? 0;
                                                if (effectiveCategory == 'TPN') {
                                                  setState(() => _tpnVolumeMl = vol);
                                                  _adjustPnUnitsForVolume(current, 'TPN', vol);
                                                } else {
                                                  setState(() => _ppnVolumeMl = vol);
                                                  _adjustPnUnitsForVolume(current, 'PPN', vol);
                                                }
                                              },
                                            ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              }),
                              const SizedBox(height: 4),
                              Text('ENは8h毎, TPN/PPNは24h毎に交換',
                                  style: Theme.of(context).textTheme.bodySmall),
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
                                final isFavorite =
                                    widget.state.isFavorite(product.id);
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
                                        onPressed: () async {
                                          await widget.state
                                              .toggleFavorite(product.id);
                                          setState(() {});
                                        },
                                        icon: Icon(
                                            isFavorite
                                                ? Icons.star
                                                : Icons.star_border,
                                            color: isFavorite
                                                ? Colors.orange
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
                                              width: 120,
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  IconButton(
                                                    onPressed: () async {
                                                      await widget.state.setUnits(current.id, product, (units - 1).clamp(0, 99));
                                                      setState(() {});
                                                    },
                                                    icon: const Icon(Icons.remove_circle_outline),
                                                  ),
                                                  Text('$units', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                                  IconButton(
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
                                          onPressed: () async {
                                            await widget.state
                                                .toggleFavorite(product.id);
                                            setState(() {});
                                          },
                                          icon: Icon(
                                              isFavorite
                                                  ? Icons.star
                                                  : Icons.star_border,
                                              color: isFavorite
                                                  ? Colors.orange
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
                constraints: BoxConstraints(maxHeight: _summaryHeight, minHeight: 80),
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
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onVerticalDragUpdate: (d) {
                          final expansion = -d.delta.dy;
                          setState(() {
                            _summaryHeight =
                                (_summaryHeight + expansion).clamp(80.0, maxSummaryH);
                          });
                          if (expansion > 0 && _listScroll.hasClients) {
                            final next = (_listScroll.offset + expansion)
                                .clamp(0.0, _listScroll.position.maxScrollExtent);
                            _listScroll.jumpTo(next);
                          }
                        },
                        onVerticalDragEnd: (_) {
                          // 上端まで引っ張ったら下端に戻す。それ以外は離した位置で止まる。
                          if (_summaryHeight >= maxSummaryH) _snapTo(80.0);
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
                                Text('サマリー', style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 8),
                                // ── 2カード: 処方+サマリー | 円グラフ（画面幅に応じてレスポンシブ）──
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
                                                ] else ...[
                                                  Builder(builder: (c) {
                                                    final ts = TextStyle(fontSize: labelFs);
                                                    final tpnUnits = _rateCategoryUnits('TPN', _tpnRateMlPerHour);
                                                    final ppnUnits = _rateCategoryUnits('PPN', _ppnRateMlPerHour);
                                                    final tpnVolume = _rateCategoryDailyVolume('TPN', _tpnRateMlPerHour);
                                                    final ppnVolume = _rateCategoryDailyVolume('PPN', _ppnRateMlPerHour);
                                                    // EN朝昼夕 (meal timingが設定されているもののみ)
                                                    final enItems = current.regimenItems.where((item) {
                                                      final p = widget.state.catalog.byId(item.productId);
                                                      return p != null && (p.category == 'EN' || p.category == 'EN_AUX') && item.hasMealTiming;
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
                                                    final hasAny = enItems.isNotEmpty || tpnUnits > 0 || ppnUnits > 0;
                                                    if (!hasAny) return const Text('(未選択)', style: TextStyle(fontSize: 12.5, color: Colors.grey));
                                                    return Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        if (enItems.isNotEmpty) ...[
                                                          mealRow('朝', (i) => i.morning),
                                                          mealRow('昼', (i) => i.noon),
                                                          mealRow('夕', (i) => i.evening),
                                                        ],
                                                        if (tpnUnits > 0) ...current.regimenItems.where((i) {
                                                          final p = widget.state.catalog.byId(i.productId);
                                                          return p != null && p.category == 'TPN' && i.units > 0;
                                                        }).map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final pacs = (_tpnVolumeMl > 0)
                                                              ? ((_tpnVolumeMl / (p.volumeMl ?? 1)).ceil())
                                                              : i.units;
                                                          final volMl = _tpnVolumeMl > 0 ? _tpnVolumeMl : (p.volumeMl ?? 0) * i.units.toDouble();
                                                          final rateMlH = (volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('TPN  ${p.name} ${pacs}本  ${rateMlH}ml/h', style: ts));
                                                        }),
                                                        if (ppnUnits > 0) ...current.regimenItems.where((i) {
                                                          final p = widget.state.catalog.byId(i.productId);
                                                          return p != null && p.category == 'PPN' && i.units > 0;
                                                        }).map((i) {
                                                          final p = widget.state.catalog.byId(i.productId)!;
                                                          final pacs = (_ppnVolumeMl > 0)
                                                              ? ((_ppnVolumeMl / (p.volumeMl ?? 1)).ceil())
                                                              : i.units;
                                                          final volMl = _ppnVolumeMl > 0 ? _ppnVolumeMl : (p.volumeMl ?? 0) * i.units.toDouble();
                                                          final rateMlH = (volMl / 24).round();
                                                          return Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('PPN  ${p.name} ${pacs}本  ${rateMlH}ml/h', style: ts));
                                                        }),
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
        child: SizedBox(
          height: _chartPanelHeight,
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
                      _chartPanelHeight =
                          (_chartPanelHeight - d.delta.dy)
                              .clamp(_chartPanelMin, maxPanel);
                    });
                  },
                  onVerticalDragEnd: (_) {
                    // 上端まで引っ張ったら下端に戻す。それ以外は離した位置で止まる。
                    if (_chartPanelHeight >= maxPanel) _chartSnapTo(_chartPanelMin);
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
      BuildContext context, PatientCase current) async {
    double activity = current.activityFactor;
    double stress = current.stressFactor;
    double protein = current.proteinGoalPerKg;
    final memoCtrl = TextEditingController(text: current.memo);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('パラメータ編集'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<double>(
                  initialValue: activity,
                  decoration: const InputDecoration(labelText: '活動係数 (AF)'),
                  items: [for (var i = 0; i < 7; i++) _factorItem(1.0 + i * 0.1, _afHints)],
                  selectedItemBuilder: (context) => [
                    for (var i = 0; i < 7; i++)
                      Align(alignment: Alignment.centerLeft,
                            child: Text((1.0 + i * 0.1).toStringAsFixed(1))),
                  ],
                  onChanged: (v) => setLocal(() => activity = v ?? activity),
                ),
                Container(
                  margin: const EdgeInsets.only(bottom: 8, top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '1.0-1.1 寝たきり体動なし　1.1-1.2 寝たきり体動あり\n'
                    '1.2-1.3 車椅子　1.3-1.4 歩行　1.5〜 積極的リハ',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                DropdownButtonFormField<double>(
                  initialValue: stress,
                  decoration: const InputDecoration(labelText: '侵害係数 (SF)'),
                  items: [for (var i = 0; i < 13; i++) _factorItem(0.9 + i * 0.1, _sfHints)],
                  selectedItemBuilder: (context) => [
                    for (var i = 0; i < 13; i++)
                      Align(alignment: Alignment.centerLeft,
                            child: Text((0.9 + i * 0.1).toStringAsFixed(1))),
                  ],
                  onChanged: (v) => setLocal(() => stress = v ?? stress),
                ),
                Container(
                  margin: const EdgeInsets.only(bottom: 8, top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '1.0 ストレスなし　1.1-1.8 手術　1.1-1.3 癌\n'
                    '1.2-1.5 感染症/発熱（敗血症 1.6）　1.2-2.0 熱傷',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                DropdownButtonFormField<double>(
                  initialValue: protein,
                  decoration:
                      const InputDecoration(labelText: '目標タンパク (g/kg/day)'),
                  items: [for (var i = 6; i <= 20; i++) i * 0.1]
                      .map((v) => DropdownMenuItem(
                          value: double.parse(v.toStringAsFixed(1)),
                          child: Text(v.toStringAsFixed(1))))
                      .toList(),
                  onChanged: (v) => setLocal(() => protein = v ?? protein),
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
    current.memo = memoCtrl.text.trim();
    await widget.state.persist();
    setState(() {});
    widget.refresh();
  }

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
      body: '①患者情報とベッド番号を入力するとHarris-Benedictの式に則り目標カロリーが算出される. そこにタンパク投与量(g/kg)も設定する.\n\n'
          '②目標カロリーを参考にEN, TPN, PPN製剤の何を何pac投与するか\n'
          '　また投与速度を指定して一部を投与する場合 (全量投与しないとき), 投与速度を入力すればそれに応じた値が出る.\n\n'
          '③EN, PN併用時にその合計が知りたい場合.\n'
          '　それぞれの使用量を選択すると計算される.\n\n'
          '④静注製剤を自らブレンドする場合 (*)\n'
          '　投与したいkcal, 蛋白量 (NPC/N比)を決めると各製剤の量 (ml)が出せる. そこからPFC balanceをみつつ脂質投与量を調整していく.\n'
          '　(*) 便宜的にゼロmenuと記載している.',
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
      category: 'Harris-Benedict',
      title: 'Harris-Benedictの式',
      color: Color(0xFFE67E22),
      body: '必要エネルギー量 = 基礎代謝 (BEE) × 活動係数 × 侵害係数 (ストレス係数)\n\n'
          '　女性 BEE = 665 + 9.6×体重kg + 1.8×身長cm − 4.7×年齢\n'
          '　男性 BEE =  66 + 13.7×体重kg + 5.0×身長cm − 6.8×年齢\n\n'
          '適応条件: 体重 25〜125kg, 身長 151〜200cm, 年齢 21〜70歳',
    ),
    _NoteSection(
      category: '活動係数\n侵害係数',
      title: '活動係数 AF',
      color: Color(0xFFE91E8C),
      body: '寝たきり体動なし            1.0 – 1.1\n'
          '寝たきり体動あり            1.1 – 1.2\n'
          'ベッド外活動 (車椅子)   1.2 – 1.3\n'
          'ベッド外活動 (歩行)       1.3 – 1.4\n'
          '積極的なリハビリ            1.5以上',
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
          '熱傷                                                                1.2 – 2.0　(広範囲熱傷 2.1)',
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
      body: '■ Na\n'
          '・不可避損失量: 食塩 1.5g = Na 600mg = Na 25.5 mEq\n'
          '・高血圧ガイドラインの 6g (Na 102 mEq) を超えないように投与.\n\n'
          '他記載中',
    ),
    _NoteSection(
      category: 'ビタミン',
      title: 'ビタミン',
      color: Color(0xFF9C27B0),
      body: '■ ビタミンB1\n'
          '・体内貯蔵量が 30mg と少なく早期に欠乏症を呈する.\n'
          '・1日に 3mg 程度補う.\n\n'
          '他記載中',
    ),
    _NoteSection(
      category: '微量元素',
      title: '微量元素',
      color: Color(0xFFFF7043),
      body: '記載中',
    ),
  ];

  static final _categoryColors = <String, Color>{
    _allLabel: Color(0xFF4CAF50),
    'つかいかた': Color(0xFF4A90D9),
    'EN': Color(0xFF2E7D32),
    'TPN': Color(0xFF1565C0),
    'PPN': Color(0xFF00838F),
    'Harris-Benedict': Color(0xFFE67E22),
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

  @override
  Widget build(BuildContext context) {
    // EN選択時はEN_AUXも含めて表示、JSON順を維持
    final items = category == 'EN'
        ? widget.state.catalog.products
            .where((p) => p.category == 'EN' || p.category == 'EN_AUX')
            .toList()
        : widget.state.catalog.byCategory(category);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'EN', label: Text('EN')),
              ButtonSegment(value: 'TPN', label: Text('TPN')),
              ButtonSegment(value: 'PPN', label: Text('PPN')),
            ],
            selected: {category},
            onSelectionChanged: (newSel) =>
                setState(() => category = newSel.first),
          ),
        ),
        const SizedBox(height: 8),
        Text('院内採用薬を選択してください',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        ...items.map((p) => _productCard(p)),
      ],
    );
  }

  Widget _productCard(Product p) {
    final isAdopted = widget.state.isAdopted(p.id);
    final typeColor =
        p.productType == '医薬品' ? Colors.red.shade100 : Colors.green.shade100;
    final typeTextColor =
        p.productType == '医薬品' ? Colors.red.shade900 : Colors.green.shade900;

    return Card(
      child: ExpansionTile(
        leading: IconButton(
          onPressed: () async {
            await widget.state.toggleAdopted(p.id);
            setState(() {});
          },
          icon: Icon(isAdopted ? Icons.circle : Icons.circle_outlined,
              color: isAdopted ? Colors.blue : null),
        ),
        title: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(p.name,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            _miniTag(p.productType, bg: typeColor, fg: typeTextColor),
            if (p.content.isNotEmpty)
              _miniTag(p.content,
                  bg: Colors.blueGrey.shade50, fg: Colors.blueGrey.shade900),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    '${p.volumeMlString} / ${p.kcalString} / ${p.aminoString}'),
              ),
              IconButton(
                tooltip: '容量を編集',
                icon: const Icon(Icons.edit, size: 18),
                onPressed: () => _editProductVolume(p),
              ),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
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
              InfoChip(label: '脂質 @g', value: p.fatBase?.toString() ?? '-'),
              InfoChip(label: '糖質 @g', value: p.carbBase?.toString() ?? '-'),
            ],
          ),
          const SizedBox(height: 8),
          // コメントと編集ボタン
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
        ],
      ),
    );
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
  });
  final String productId;
  int units;
  int morning;
  int noon;
  int evening;

  bool get hasMealTiming => morning > 0 || noon > 0 || evening > 0;

  Map<String, dynamic> toMap() => {
        'productId': productId,
        'units': units,
        'morning': morning,
        'noon': noon,
        'evening': evening,
      };
  factory RegimenItem.fromMap(Map<String, dynamic> map) => RegimenItem(
        productId: map['productId'] as String,
        units: map['units'] as int,
        morning: (map['morning'] as int?) ?? 0,
        noon: (map['noon'] as int?) ?? 0,
        evening: (map['evening'] as int?) ?? 0,
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
    this.memo = '',
  });

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
      );
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

  static double targetEnergy(PatientCase item) {
    final bee = item.sex == Sex.male
        ? 66 + 13.7 * item.weightKg + 5 * item.heightCm - 6.8 * item.age
        : 665 + 9.6 * item.weightKg + 1.8 * item.heightCm - 4.7 * item.age;
    return (bee * item.activityFactor * item.stressFactor);
  }

  static double targetProtein(PatientCase item) =>
      item.weightKg * item.proteinGoalPerKg;

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
  }) {
    final aminoMlPerGram = (aminoProduct?.volumeMl ?? 500) /
        ((aminoProduct?.aminoAcidG ?? 50) == 0
            ? 50
            : (aminoProduct?.aminoAcidG ?? 50));
    final proteinGram = (6.25 * targetKcal) / (npcNRatio + 6.25 * 4);
    final aminoVolumeMl = proteinGram * aminoMlPerGram;
    final lipidGram = lipidGramPerKg * weightKg;
    final lipidVolumeMl = lipidProduct == null
        ? 0.0
        : lipidGram /
            ((lipidProduct.fatBase ?? 20) / (lipidProduct.volumeMl ?? 100));
    final glucoseKcal = (targetKcal - proteinGram * 4 - lipidGram * 9)
        .clamp(0, double.infinity);
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

    // タンパク不足を高濃度AA(PPN)で補正してitemsに追加するヘルパー
    //   (kcal・タンパクとも当日目標を超えない範囲で本数を足す)
    void addPpnProtein(List<DesignItem> items, double curKcal, double curProt) {
      if (curProt >= dayTargetProt * 0.9) return;
      final aminos = ppnProducts.where((p) => (p.aminoAcidG ?? 0) > 0).toList()
        ..sort((a, b) => ((b.aminoAcidG ?? 0) / (b.volumeMl ?? 1))
            .compareTo((a.aminoAcidG ?? 0) / (a.volumeMl ?? 1)));
      if (aminos.isEmpty) return;
      final pp = aminos.first;
      int add = 0;
      while (curProt < dayTargetProt * 0.9 &&
          curProt + (pp.aminoAcidG ?? 0) <= dayTargetProt &&
          curKcal + (pp.kcal ?? 0) <= dayTargetKcal) {
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

    // PN主剤候補(採用TPN全て)。日ごとに密度の違う製剤(エルネオパ1号/2号等)から最適を選ぶ
    final pnBases = tpnProducts
        .where((p) => (p.kcal ?? 0) > 0 && (p.volumeMl ?? 0) > 0)
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
        // PN主剤を1号/2号等で振り、IN・kcalが最適なものを採用
        // PN使用量が袋の50%未満の場合は別製剤を優先(スコアペナルティ付き)
        for (final pb in pnBases) {
          final plan = completePlan(enItems, pb);
          // プラン内のPNアイテムを特定して使用量比を確認
          double planScore = scoreOf(plan, enKcal);
          final bagVol = pb.volumeMl ?? 1;
          for (final it in plan.items) {
            if (it.units == null && it.name == pb.name) {
              final usageRatio = it.volumeMl / bagVol;
              if (usageRatio < 0.5) {
                // 50%未満の端数使用 → 別製剤があれば乗り換えを促す
                planScore += (0.5 - usageRatio) * 20;
              }
            }
          }
          if (planScore < bestScore) {
            bestScore = planScore;
            best = plan;
            bestEnKcal = enKcal;
          }
        }
      }
    }
    // PNのみ(TPN)でINが過大になる時の代替: ゼロmenu(高濃度静注ブレンド)
    if (mode == 'TPN') {
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
    // ── EN ──
    'F2α', 'テルミール2.0α', 'グルセルナREX', 'リーナレンMP',
    'ヘパス', 'ペプチーノ', 'ペプタメンAF', 'ペプタメンスタンダード',
    'エネーボ', 'エレンタール', 'アミノレバン',
    // ── EN補助（6種すべて） ──
    'REF P1', 'GFO', 'サンファイバー', 'オルニュート', 'ブイ・クレスゼリー', '一挙千菜',
    // ── TPN（ミキシッド・ビーエヌツイン・ハイカリック1-3号 を除く） ──
    'エルネオパNF1号', 'エルネオパNF2号',
    'ワンパル1号', 'ワンパル2号',
    'ネオパレン1号', 'ネオパレン2号',
    'フルカリック1号', 'フルカリック2号', 'フルカリック3号',
    'ハイカリックRF', '70% グルコース',
    // ── PPN（キドミン・ネオアミユー・アミノレバン・モノヘパミン を除く） ──
    'ビーフリード', 'プラスアミノ', 'パレプラス', 'パレセーフ',
    'ツインパル', 'アミパレン', 'アミゼットB', 'プロテアミン12',
    'イントラリポス10%', 'イントラリポス20%', '8%グルコース', '5%グルコース',
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

  bool isAdopted(String productId) => adoptedProductIds.contains(productId);

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
          caseCode: 'CASE-001',
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
      final defaultIds = catalog.products
          .where((p) => defaults.contains(p.name.trim()))
          .map((p) => p.id);
      adopted = (<String>{...adopted, ...defaultIds}).toList();
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
      if (units <= 0) {
        current.regimenItems.removeAt(existingIndex);
      } else {
        current.regimenItems[existingIndex].units = units;
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
  int _rampDays = 5; // PNでfull nutritionまで漸増する日数
  int _enStartDay = 6; // EN導入するDay番号(食上げ開始日)
  int _totalDays = 5; // シミュレーション全体の日数 (= _enStartDay + EN食上げ7日 -1)
  Product? _pnProduct; // PN(中心静脈栄養)主剤
  late DateTime _startDate; // 栄養開始日
  late List<double> _dayPercents; // 各Dayの達成目標%
  late List<String> _dayModes; // 各Dayのクラス
  late List<String> _dayEnDose; // 各DayのEN投与 ('0'/'r20'(速度)/'p3'(pac))

  // EN食上げ固定シーケンス(7日): 10→20→30→40ml/h → 1pac朝昼夕(3) → 2pac朝昼夕(6) → EN単独full
  static const _enRampSequence = ['r10', 'r20', 'r30', 'r40', 'p3', 'p6', 'p6'];
  static const _enRampDays = 7;

  @override
  void initState() {
    super.initState();
    final tpn = _adopted('TPN');
    final cfg = widget.current.autoDesignConfig;
    if (cfg != null) {
      // 保存済み設定を復元 (rampDays・開始日・PN製剤のみ。日別は固定シーケンスから再生成)
      _rampDays = (cfg['rampDays'] as num?)?.toInt() ?? 5;
      _enStartDay = (cfg['enStartDay'] as num?)?.toInt() ?? (_rampDays + 1);
      _startDate =
          DateTime.tryParse(cfg['startDate'] as String? ?? '') ?? DateTime.now();
      final pid = cfg['pnProductId'] as String?;
      _pnProduct = pid != null ? widget.state.catalog.byId(pid) : (tpn.isNotEmpty ? tpn.first : null);
    } else {
      final p = widget.state.protocols.firstWhere(
          (e) => e.id == widget.current.selectedProtocolId,
          orElse: () => widget.state.protocols.first);
      _rampDays = p.percentages.length;
      _enStartDay = _rampDays + 1;
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
      'pnProductId': _pnProduct?.id,
      'startDate': _startDate.toIso8601String(),
    };
    widget.state.persist();
  }

  List<Product> _adopted(String cat) => widget.state.catalog
      .byCategory(cat)
      .where((p) => widget.state.isAdopted(p.id))
      .toList();

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
      _ => mode,
    };
    // PN部分がゼロmenuにフォールバックした場合の表記
    final label = (mode == 'TPN+EN' && planIsZero) ? 'EN+ゼロmenu' : baseLabel;
    final color = switch (mode) {
      'TPN' => Colors.blue,
      'TPN+EN' => Colors.teal,
      'EN' => Colors.green,
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
  void _rebuildDays() {
    if (_enStartDay < 1) _enStartDay = 1;
    _totalDays = _enStartDay + _enRampDays - 1;
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
      if (day < _enStartDay) return 'TPN'; // EN導入前はPNのみ
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      if (step == _enRampDays - 1) return 'EN'; // 最終ステップはEN単独full
      return 'TPN+EN'; // 食上げ中はPN+EN併用(PN自動減量)
    });
    _dayEnDose = List.generate(n, (i) {
      final day = i + 1;
      if (day < _enStartDay) return '0';
      final step = (day - _enStartDay).clamp(0, _enRampDays - 1);
      return _enRampSequence[step];
    });
  }

  @override
  Widget build(BuildContext context) {
    final targetKcal = NutritionCalculator.targetEnergy(widget.current);
    final targetProt = NutritionCalculator.targetProtein(widget.current);
    final pcts = _dayPercents;
    // お気に入り製剤を先頭に並べて優先選択させる
    List<Product> sortFav(List<Product> list) {
      final fav = list.where((p) => widget.state.isFavorite(p.id)).toList();
      final rest = list.where((p) => !widget.state.isFavorite(p.id)).toList();
      return [...fav, ...rest];
    }
    final enList = sortFav(_adopted('EN'));
    final tpnAll = sortFav(_adopted('TPN'));
    final tpnList = tpnAll;
    final ppnList = sortFav(_adopted('PPN'));
    // _pnProduct が採用TPNに無ければ先頭にフォールバック
    if (_pnProduct == null || !tpnAll.any((p) => p.id == _pnProduct!.id)) {
      _pnProduct = tpnAll.isNotEmpty ? tpnAll.first : null;
    }
    // プランを逐次生成して minEnKcal(単調増加制約)を引き継ぐ
    double prevEnKcal = 0;
    final dayPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final pct = pcts[i];
      final plan = NutritionCalculator.designDay(
        mode: _dayModes[i],
        dayTargetKcal: targetKcal * pct / 100,
        dayTargetProt: targetProt * pct / 100,
        weightKg: widget.current.weightKg,
        enProducts: enList,
        enRateMlH: _rateOf(_dayEnDose[i]),
        enPac: _pacOf(_dayEnDose[i]),
        pnProduct: _pnProduct,
        tpnProducts: tpnList,
        ppnProducts: ppnList,
        glucoseProduct: widget.state.catalog.byName('70% グルコース'),
        aminoProduct: widget.state.catalog.byName('アミパレン'),
        lipidProduct: widget.state.catalog.byName('イントラリポス20%'),
        minEnKcal: prevEnKcal,
      );
      dayPlans.add(plan);
      if (plan.enKcal > 0) prevEnKcal = plan.enKcal;
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
                  // 設定を3行テーブル形式（ラベル列を固定幅で揃える）
                  Table(
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    columnWidths: const {
                      0: IntrinsicColumnWidth(), // ラベル列（最長に合わせる）
                      1: IntrinsicColumnWidth(), // 値列
                    },
                    children: [
                      // 行1: 栄養開始日
                      TableRow(children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 8, bottom: 6),
                          child: Text('栄養開始日:',
                              style: TextStyle(fontSize: 13)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: TextButton(
                            style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                            onPressed: () async {
                              final picked = await _quickPickDate(context, _startDate);
                              if (picked != null) {
                                setState(() => _startDate = picked);
                                widget.onSettingsChanged?.call();
                              }
                            },
                            child: Text(
                                '${_startDate.year}/${_startDate.month.toString().padLeft(2, '0')}/${_startDate.day.toString().padLeft(2, '0')}',
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ),
                      ]),
                      // 行2: full nutrition達成
                      TableRow(children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 8, bottom: 6),
                          child: Text('full nutrition達成:',
                              style: TextStyle(fontSize: 13)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Day ', style: TextStyle(fontSize: 13)),
                              DropdownButton<int>(
                                value: _rampDays,
                                isDense: true,
                                items: List.generate(14, (i) => i + 1)
                                    .map((d) => DropdownMenuItem(
                                        value: d, child: Text('$d')))
                                    .toList(),
                                onChanged: (v) => setState(() {
                                  _rampDays = v ?? _rampDays;
                                  _enStartDay = _rampDays + 1;
                                  _rebuildDays();
                                }),
                              ),
                            ],
                          ),
                        ),
                      ]),
                      // 行3: EN導入時期
                      TableRow(children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Text('EN導入時期:',
                              style: TextStyle(fontSize: 13)),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Day ', style: TextStyle(fontSize: 13)),
                            DropdownButton<int>(
                              value: _enStartDay.clamp(1, 21),
                              isDense: true,
                              items: List.generate(21, (i) => i + 1)
                                  .map((d) => DropdownMenuItem(
                                      value: d, child: Text('$d')))
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _enStartDay = v ?? _enStartDay;
                                _rebuildDays();
                              }),
                            ),
                          ],
                        ),
                      ]),
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
          ...List.generate(pcts.length, (i) {
            final pct = pcts[i];
            final dayKcal = targetKcal * pct / 100;
            final dayProt = targetProt * pct / 100;
            final mode = _dayModes[i];
            final showEn = mode == 'EN' || mode == 'TPN+EN';
            final showPn = mode == 'TPN' || mode == 'TPN+EN';
            // 逐次生成済みのプランを使用（minEnKcal単調増加制約適用済み）
            final plan = dayPlans[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                onTap: () => _showDayDetail(i, plan, dayKcal, dayProt),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(_dateOf(i),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
                          Text(
                              '(Day${i + 1})',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 4),
                          // 目標% or "full nutrition"（常にgreen）
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              pct >= 100
                                  ? 'full nutrition'
                                  : '目標 ${pct.toStringAsFixed(0)}%',
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
                                color: Colors.pink.shade50,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.pink.shade200, width: 0.8),
                              ),
                              child: Text(_doseLabel(_dayEnDose[i]),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.pink.shade700)),
                            ),
                          ],
                          const Spacer(),
                          const Icon(Icons.touch_app,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          _modeBadge(mode,
                              planIsZero: plan.label == 'ZERO'),
                        ],
                      ),
                      const Divider(height: 16),
                      _planBody(plan, dayKcal, dayProt, mode),
                    ],
                  ),
                ),
              ),
            );
          }),
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
      final fav = list.where((p) => widget.state.isFavorite(p.id)).toList();
      final rest = list.where((p) => !widget.state.isFavorite(p.id)).toList();
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
      if (p != null && (p.category == 'EN' || p.category == 'EN_AUX')) {
        s += it.kcal;
      }
    }
    return s;
  }

  Widget _buildBarCharts(double targetKcal, List<double> pcts,
      List<Product> en, List<Product> tpn, List<Product> ppn) {
    final targetProt = NutritionCalculator.targetProtein(widget.current);
    // 逐次生成して minEnKcal 単調増加制約を適用
    double prevEnKcalChart = 0;
    final designPlans = <DesignPlan>[];
    for (int i = 0; i < pcts.length; i++) {
      final p = NutritionCalculator.designDay(
              mode: _dayModes[i],
              dayTargetKcal: targetKcal * pcts[i] / 100,
              dayTargetProt: targetProt * pcts[i] / 100,
              weightKg: widget.current.weightKg,
              enProducts: en,
              enRateMlH: _rateOf(_dayEnDose[i]),
              enPac: _pacOf(_dayEnDose[i]),
              pnProduct: _pnProduct,
              tpnProducts: tpn,
              ppnProducts: ppn,
              glucoseProduct: widget.state.catalog.byName('70% グルコース'),
              aminoProduct: widget.state.catalog.byName('アミパレン'),
              lipidProduct: widget.state.catalog.byName('イントラリポス20%'),
              minEnKcal: prevEnKcalChart,
            );
      if (p.enKcal > 0) prevEnKcalChart = p.enKcal;
      designPlans.add(p);
    }

    // 栄養開始日が未来の場合、今日から開始日前日まで空白(0)を先頭に追加
    final today = DateTime.now();
    final startNorm =
        DateTime(_startDate.year, _startDate.month, _startDate.day);
    final todayNorm = DateTime(today.year, today.month, today.day);
    final preDays = startNorm.difference(todayNorm).inDays.clamp(0, 60);
    final emptyPlan = DesignPlan(label: 'Day', items: const []);
    final plans = [
      ...List.filled(preDays, emptyPlan),
      ...designPlans,
    ];

    final enKcals = plans.map(_enKcalOfPlan).toList();
    final ins = plans.map((p) => p.totalVolumeMl).toList();
    final prots = plans.map((p) => p.totalProteinG).toList();
    final n = plans.length;

    // 日付ラベル: 同月内は日のみ, 月が変わる初日はmm/dd
    final dates = List.generate(n, (i) => todayNorm.add(Duration(days: i)));
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
    final maxAA = prots.fold<double>(1, (a, b) => a > b ? a : b) * 1.15;
    const hidden = AxisTitles(sideTitles: SideTitles(showTitles: false));
    // 日付軸を上(topTitles)に配置 → BarChart の上端より上に日付が来る
    final topDateTitles = AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        getTitlesWidget: (v, m) {
          final i = v.round();
          if (i < 0 || i >= n) return const SizedBox.shrink();
          return Text(dateLabel(i),
              style: const TextStyle(
                  fontSize: 12, letterSpacing: -0.5, height: 1.0));
        },
      ),
    );

    // 共通の透明な線グラフビルダー（独立スケール・minY=0で軸より下に出ない）
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
          clipData: const FlClipData.all(), // minY=0より下にはみ出さない
          lineTouchData: const LineTouchData(enabled: false),
        ));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('栄養の推移', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _LegendChip(
                    color: Colors.yellow.shade700, label: 'EN(kcal)', line: false),
                _LegendChip(
                    color: Colors.green.shade300, label: 'PN(kcal)', line: false),
                _LegendChip(color: Colors.purple.shade200, label: 'IN(ml)', line: true),
                _LegendChip(color: Colors.pink.shade300, label: 'AA(g)', line: true),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 240,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (n == 0) return;
                  final chartWidth = (context.findRenderObject() as RenderBox?)
                          ?.size.width ??
                      300;
                  final barWidth = (chartWidth - 24) / n;
                  final idx = (details.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
                  setState(() {
                    // 同じバーをもう一度タップで解除
                    _selectedBarIdx = (_selectedBarIdx == idx) ? -1 : idx;
                  });
                },
                child: MouseRegion(
                onHover: (e) {
                  if (n == 0) return;
                  final chartWidth = (context.findRenderObject() as RenderBox?)
                          ?.size.width ??
                      300;
                  final barWidth = (chartWidth - 24) / n;
                  final idx = (e.localPosition.dx / barWidth)
                      .floor()
                      .clamp(0, n - 1);
                  if (idx != _hoveredBarIdx) {
                    setState(() => _hoveredBarIdx = idx);
                  }
                },
                onExit: (_) => setState(() => _hoveredBarIdx = -1),
                child: Stack(
                children: [
                  // ① 積み上げ棒: カロリー内訳 (PN+EN)、独立スケール
                  BarChart(BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    minY: 0,
                    maxY: maxKcal,
                    barTouchData: BarTouchData(enabled: false),
                    barGroups: List.generate(n, (i) {
                      final enK = enKcals[i];
                      final total = plans[i].totalKcal;
                      final otherK = (total - enK).clamp(0.0, double.infinity);
                      return BarChartGroupData(x: i, barRods: [
                        BarChartRodData(
                          toY: total,
                          width: 16,
                          borderRadius: BorderRadius.circular(2),
                          rodStackItems: [
                            BarChartRodStackItem(
                                0, enK, Colors.yellow.shade700), // EN 下
                            BarChartRodStackItem(
                                enK, total, Colors.green.shade300), // PN 上
                          ],
                        ),
                      ]);
                    }),
                    titlesData: FlTitlesData(
                      bottomTitles: hidden,
                      leftTitles: hidden,
                      topTitles: topDateTitles, // 日付を上に
                      rightTitles: hidden,
                    ),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  )),
                  // ② 合計IN: マーカー付き線、独立スケール
                  lineLayer(ins, maxIn, Colors.purple.shade200),
                  // ③ AA(タンパク)投与量: マーカー付き線、独立スケール
                  lineLayer(prots, maxAA, Colors.pink.shade300),
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
                    // 棒の高さ比率からY位置を推定
                    const chartH = 240.0;
                    const topReserved = 22.0;
                    final drawH = chartH - topReserved;
                    final barRatio = maxKcal > 0
                        ? (plans[idx].totalKcal / maxKcal).clamp(0.0, 1.0)
                        : 0.0;
                    final barTopY =
                        topReserved + drawH * (1.0 - barRatio) - 8;
                    final chartW = (context.findRenderObject() as RenderBox?)
                            ?.size.width ??
                        300;
                    final barW = (chartW - 24) / n;
                    final barCenterX = barW * idx + barW / 2;
                    const tipW = 136.0;
                    final tipX =
                        (barCenterX - tipW / 2).clamp(0.0, chartW - tipW);
                    return Positioned(
                      left: tipX,
                      top: barTopY.clamp(0.0, chartH - 80),
                      child: Container(
                        width: tipW,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 6),
                        decoration: BoxDecoration(
                          color: isPinned
                              ? const Color(0xFFF0F4FF)  // タップ固定: 薄青
                              : const Color(0xFFFFF8E7), // ホバー: ベージュ
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(dateLabel(idx),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold)),
                                if (isPinned)
                                  GestureDetector(
                                    onTap: () => setState(
                                        () => _selectedBarIdx = -1),
                                    child: Icon(Icons.close,
                                        size: 13,
                                        color: Colors.grey.shade500),
                                  ),
                              ],
                            ),
                            if (plan.items.isEmpty)
                              const Text('栄養開始前',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey))
                            else ...[
                              Text(
                                  'IN ${plan.totalVolumeMl.round()}ml',
                                  style:
                                      const TextStyle(fontSize: 11)),
                              Text(
                                  '${plan.totalKcal.round()}kcal',
                                  style:
                                      const TextStyle(fontSize: 11)),
                              Text(
                                  'タンパク ${plan.totalProteinG.toStringAsFixed(1)}g'
                                  '${w > 0 ? '\n(${(plan.totalProteinG / w).toStringAsFixed(1)}g/kg)' : ''}',
                                  style:
                                      const TextStyle(fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
                ],
                ), // Stack
              ), // MouseRegion
              ), // GestureDetector
            ),
          ],
        ),
      ),
    );
  }

  // Dayカードのタップで処方詳細(何を何pac)をダイアログ表示
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
              if (plan.items.isEmpty)
                const Text('（条件を満たす組み合わせなし）',
                    style: TextStyle(color: Colors.red)),
              ...plan.items.map((it) {
                final cat = widget.state.catalog.byName(it.name)?.category;
                final isEnCat = cat == 'EN' || cat == 'EN_AUX';
                final isEnPacItem = it.units != null && isEnCat;
                final isEnRateItem = it.units == null && isEnCat;
                String line;
                if (isZero) {
                  line = '${it.name}：${it.volumeMl.round()}ml';
                } else if (isEnPacItem) {
                  final mp = (it.units! / 3).round().clamp(1, it.units!);
                  line = '${it.name}：朝昼夕${mp}pac (${it.volumeMl.round()}ml/day)';
                } else if (isEnRateItem) {
                  final rml = it.volumeMl / 24;
                  final pex = (rml * 8 / (widget.state.catalog.byName(it.name)?.volumeMl ?? 200)).ceil();
                  line = '${it.name}：${rml.toStringAsFixed(0)}ml/h  朝昼夕${pex}pac';
                } else if (it.units != null) {
                  line = '${it.name}：${it.units}pac (${it.volumeMl.round()}ml, ${it.ratePerHour.round()}ml/h)';
                } else {
                  line = '${it.name}：${it.volumeMl.round()}ml (${it.ratePerHour.round()}ml/h)';
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child:
                      Text(line, style: const TextStyle(fontSize: 14)),
                );
              }),
              const Divider(height: 20),
              Text(
                'IN ${plan.totalVolumeMl.round()}ml ／ 熱量 ${plan.totalKcal.round()}kcal ／ '
                'タンパク ${plan.totalProteinG.toStringAsFixed(1)}g'
                '${w > 0 ? ' (${(plan.totalProteinG / w).toStringAsFixed(1)}g/kg)' : ''}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13),
              ),
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

  Widget _planBody(
      DesignPlan plan, double targetKcal, double targetProt, String mode) {
    if (plan.items.isEmpty) {
      return const Text('（条件を満たす組み合わせなし）',
          style: TextStyle(color: Colors.red, fontSize: 12));
    }
    final w = widget.current.weightKg;
    final protPerKg = w > 0 ? plan.totalProteinG / w : 0.0;
    final isZero = mode == 'ZERO' || plan.label == 'ZERO';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...plan.items.map((it) {
          // ゼロmenuは各製剤の使用量(ml)だけ記載
          if (isZero) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('${it.name}  ${it.volumeMl.round()}ml',
                  style: const TextStyle(fontSize: 12.5)),
            );
          }
          // EN製剤(pac指定): 間欠的→"朝昼夕Npac"  持続→"Nml/h 朝昼夕Npac, 交換時残破棄"
          // PN静注: "_ml (_ml/h)"
          final cat = widget.state.catalog.byName(it.name)?.category;
          final isEnPac = it.units != null && (cat == 'EN' || cat == 'EN_AUX');
          final isEnRate = it.units == null && (cat == 'EN' || cat == 'EN_AUX');
          String dispStr;
          if (isEnPac) {
            final mealPac = (it.units! / 3).round().clamp(1, it.units!);
            dispStr = '${it.name}  朝昼夕${mealPac}pac (${it.volumeMl.round()}ml/day)';
          } else if (isEnRate) {
            final rateMlH = it.volumeMl / 24;
            final pacPerExchange = (rateMlH * 8 / (widget.state.catalog.byName(it.name)?.volumeMl ?? 200)).ceil();
            dispStr = '${it.name}  ${rateMlH.toStringAsFixed(0)}ml/h  朝昼夕${pacPerExchange}pac';
          } else {
            // PN静注: 流速は整数表記
            final unitStr = it.units != null
                ? '${it.units}pac (${it.volumeMl.round()}ml)'
                : '${it.volumeMl.round()}ml';
            dispStr = '${it.name}  $unitStr  (${it.ratePerHour.round()}ml/h)';
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(dispStr, style: const TextStyle(fontSize: 12.5)),
          );
        }),
        const SizedBox(height: 4),
        Text(
          'IN ${plan.totalVolumeMl.round()}ml, 熱量 ${plan.totalKcal.round()}kcal, '
          'タンパク ${plan.totalProteinG.toStringAsFixed(1)}g (${protPerKg.toStringAsFixed(1)}g/kg)'
          '${isZero ? ', ${(plan.totalVolumeMl / 24).toStringAsFixed(1)}ml/h' : ''}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ],
    );
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
