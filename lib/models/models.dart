/// データモデル層のバレル（まとめ再公開）。
///
/// UI・計算・永続化のすべてから参照される「共通の型」。
/// main.dart は `import 'models/models.dart';` で使用し、
/// 後方互換のため `export 'models/models.dart';` で再公開する。
library;

export 'aggregate_result.dart';
export 'bed_assignment.dart';
export 'condition_catalog.dart';
export 'design_plan.dart';
export 'patient_case.dart';
export 'product.dart';
export 'protocol_template.dart';
export 'regimen_item.dart';
export 'sex.dart';
export 'zero_menu_config.dart';
export 'zero_menu_suggestion.dart';
