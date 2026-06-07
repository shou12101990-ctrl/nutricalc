import 'dart:convert';
import 'dart:html';

class LocalStore {
  static const _storageKey = 'nutrition_cases';
  static const _favoritesKey = 'nutrition_favorite_products';
  static const _adoptedKey = 'nutrition_adopted_products';
  static const _overridesKey = 'nutrition_product_overrides';
  static const _noteKey = 'nutrition_note';

  Future<List<Map<String, dynamic>>> loadCases() async {
    final text = window.localStorage[_storageKey];
    if (text == null || text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<List<String>> loadFavorites() async {
    final text = window.localStorage[_favoritesKey];
    if (text == null || text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => e.toString()).toList();
  }

  Future<Map<String, Map<String, dynamic>>> loadProductOverrides() async {
    final text = window.localStorage[_overridesKey];
    if (text == null || text.trim().isEmpty) return {};
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

  Future<void> saveCases(List<dynamic> items) async {
    window.localStorage[_storageKey] =
        jsonEncode(items.map((e) => e.toMap()).toList());
  }

  Future<void> saveFavorites(List<String> favorites) async {
    window.localStorage[_favoritesKey] = jsonEncode(favorites);
  }

  Future<List<String>> loadAdoptedProducts() async {
    final text = window.localStorage[_adoptedKey];
    if (text == null || text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => e.toString()).toList();
  }

  Future<void> saveAdoptedProducts(List<String> adopted) async {
    window.localStorage[_adoptedKey] = jsonEncode(adopted);
  }

  Future<void> saveProductOverrides(
      Map<String, Map<String, dynamic>> overrides) async {
    window.localStorage[_overridesKey] = jsonEncode(overrides);
  }

  Future<String> loadNote() async {
    return window.localStorage[_noteKey] ?? '';
  }

  Future<void> saveNote(String text) async {
    window.localStorage[_noteKey] = text;
  }

  Future<bool> loadDefaultsApplied() async =>
      window.localStorage['nutrition_defaults_applied_v4'] == '1';

  Future<void> saveDefaultsApplied() async {
    window.localStorage['nutrition_defaults_applied_v4'] = '1';
  }
}
