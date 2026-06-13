import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_store.dart';
import 'clinical/constants.dart' as ck;
import 'clinical/body_weight.dart' as cbw;
import 'clinical/energy.dart' as ce;
import 'clinical/conditions.dart' as cc;
import 'clinical/infusion.dart' as ci;
import 'clinical/refeeding.dart' as cr;
import 'clinical/refeeding_events.dart' as crev;
import 'clinical/lab_schedule.dart' as clab;
import 'clinical/en_timing.dart' as cen;
import 'clinical/micronutrients.dart' as cm;
import 'clinical/clinical_event.dart' as cev;
import 'clinical/event_overlay.dart' as cov;
import 'clinical/source_tier.dart' as cst;
import 'clinical/auto_design_engine.dart' as cad;

// データモデル層（lib/models/）。importで内部使用し、exportで後方互換に再公開。
import 'models/models.dart';
export 'models/models.dart';
import 'clinical/nutrition_calculator.dart';
export 'clinical/nutrition_calculator.dart';
// アラート/リペアエンジン（評価＋スコア）。単一プレフィックス ae にまとめる。
import 'clinical/alerts.dart' as ae;
import 'clinical/constraints.dart' as ae;
// Repair Loop(型・アクション・engine)。EvalContext は ae.EvalContext を共用。
import 'clinical/repair.dart';

part 'widgets.dart';
part 'state.dart';
part 'pages/cases_page.dart';
part 'pages/builder_page.dart';
part 'pages/note_page.dart';
part 'pages/master_page.dart';
part 'pages/auto_design.dart';

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
          NavigationDestination(icon: Icon(Icons.notes_outlined), label: 'ノート'),
        ],
      ),
    );
  }

  void _refresh() => setState(() {});
}
