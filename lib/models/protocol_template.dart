/// 投与プロトコル（Day別の目標到達率テンプレート）。
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
