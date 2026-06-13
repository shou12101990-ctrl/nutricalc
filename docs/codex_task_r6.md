# Codex 実装タスク R6（auto_design.dart / lib/clinical 担当）

ratified 方針は docs/codex_collab_round1.md「ラウンド5」を参照。あなた(Codex)の担当範囲のみ実装する。
**Claude著の凍結モジュールは編集しない**: `lib/clinical/{event_overlay,source_tier,micronutrient_obligations,refeeding_bundle}.dart`、
`lib/clinical/energy.dart` の `EnergyResult`（`actualWeightKg`=真の実体重 / `referenceWeightKg`=参照体重 は確定済み）。
完了条件: `dart analyze` エラー0 / `flutter test` 全緑 / `flutter build web --no-pub` 成功。新規ロジックにはユニットテストを追加。

## タスク1: engine を「メタデータ専用の read-model」として live UI に結線（#1(b)）
方針: `auto_design.dart` の既存軽量オーバーレイ(`_derived*`/`_overlayForDay`)＋既存solverは**本番のまま**。
`AutoDesignEngine.build` で**処方を作り直さない**（solver drift回避）。engineは表示メタデータの供給のみ。

1. `_AutoDesignPageState` に `AutoDesignResult? _engineResult` を持ち、**memoized getter / キャッシュ**で1回だけ構築する。
   無効化トリガー: `_rebuildDays()`・臨床イベント編集(追加/編集/削除)・患者情報変更。毎 card/chart helper では呼ばない。
2. ページの設定値→`AutoDesignInput` のマッピングを書く:
   weightKg=`widget.current.weightKg`、usualOrPrehospitalWeightKg=`widget.current.usualWeightKg`、
   conditionTags、events=`_clinicalEvents`、rampDays=`_rampDays`、enStartDay=`_enStartDay`、
   oralRehabStartDay、totalDays=`_totalDays`、estimatedFullKcal=`NutritionCalculator.targetEnergy(widget.current)`、
   refeedingTier=`_refeedingTier`、feedingStartDay=1、krtFluidCaloriesStatus/eventEnergyCapKcalByDay は既存入力から。
3. surface（既存UIに足すだけ・solver出力は変えない）:
   - 各DayカードにエネルギーBand: `_engineResult.energyTargets[i].classify(plan.totalKcal)` を green/amber/red の小ドット＋tooltip。
   - 各DayカードにタンパクBand: `proteinTargets[i].classify(plan.totalProteinG / NutritionCalculator.referenceWeightKg(widget.current))`。
     **分母は referenceWeightKg（参照体重）を使う**（真の実体重ではない）。
   - `_engineResult.alerts` を day 別にまとめ、既存のアラート/詳細UI（`_showDayRepairSheet`/アラートリンク）に統合表示（情報severityも）。
   - `_engineResult.sourceBadges` をグローバルの凡例として1箇所に（カードの per-day source badge は既存実装を流用）。
   - `obligations` は既存の採血(lab_schedule)/微量栄養素パネルに綺麗に対応できる範囲で後追いでよい。
4. テスト: `AutoDesignEngine.build` の入出力（band境界・day別alert集約）を `test/clinical/auto_design_engine_test.dart` に追加。

## タスク2: チャートのイベントシェード層（#4-1）
`auto_design.dart` のトレンドチャート（fl_chart の棒＋線が乗る plot 領域）に、決定論的な `Stack` シェード層を1枚足す。
- 1日1セル（plot幅/n）で、その日に有効なオーバーレイがあれば淡色 tint。色は**優先度**で決める:
  RRT(紫/teal) > route/EN hold(amber/red) > energy/protein/fluid(deepOrange/blue)。`resolveDayOverlay(_clinicalEvents, day)` を使用。
- 日付軸（既存 dateCell 群）に小さなイベントマーカー（既存アイコン様式）を重ね、可視数に上限を設け超過は `+n`。
- 既存の棒/線/凡例の座標・ゼロ基線を**動かさない**こと（shadeは最背面の `Positioned.fill`/`Stack` 最下層）。
- 既存の hover ツールチップ・アラートリンクの当たり判定を壊さない。

## 注意
- `nutrition_calculator.dart` の `referenceWeightKg(item)` は確定済み。band分母・参照体重表示はこれを使う。
- 重複実装回避: カードのイベント/ソースバッジ(`_eventBadgesForDay`)・`Template → Derived` パネルは実装済み。重ねて作らない。
- 完了したら docs/codex_collab_round1.md に「R6実装済み」を1行追記。
