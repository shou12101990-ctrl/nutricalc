import 'package:flutter_test/flutter_test.dart';
import 'package:nutrition_flutter_app/models/models.dart';

void main() {
  test('参照体重トリガーになる溢水・浮腫タグが患者病態カタログに登録されている', () {
    final fluidOverload = ConditionCatalog.byId('fluid_overload');
    final edema = ConditionCatalog.byId('edema');

    expect(fluidOverload, isNotNull);
    expect(edema, isNotNull);
    expect(fluidOverload!.label, '溢水・体液過剰');
    expect(edema!.label, '浮腫');
    expect(fluidOverload.suggestion, contains('参照体重'));
    expect(edema.suggestion, contains('平時/入院前体重'));
  });
}
