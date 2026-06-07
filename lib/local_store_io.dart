import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalStore {
  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_cases.json');
  }

  Future<File> _favoritesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_favorites.json');
  }

  Future<File> _productOverridesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_product_overrides.json');
  }

  Future<File> _adoptedProductsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_adopted_products.json');
  }

  Future<File> _noteFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_note.txt');
  }

  Future<List<Map<String, dynamic>>> loadCases() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<List<String>> loadFavorites() async {
    final file = await _favoritesFile();
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => e.toString()).toList();
  }

  Future<Map<String, Map<String, dynamic>>> loadProductOverrides() async {
    final file = await _productOverridesFile();
    if (!await file.exists()) return {};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

  Future<void> saveCases(List<dynamic> items) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(items.map((e) => e.toMap()).toList()));
  }

  Future<void> saveFavorites(List<String> favorites) async {
    final file = await _favoritesFile();
    await file.writeAsString(jsonEncode(favorites));
  }

  Future<List<String>> loadAdoptedProducts() async {
    final file = await _adoptedProductsFile();
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return [];
    final decoded = jsonDecode(text) as List;
    return decoded.map((e) => e.toString()).toList();
  }

  Future<void> saveAdoptedProducts(List<String> adopted) async {
    final file = await _adoptedProductsFile();
    await file.writeAsString(jsonEncode(adopted));
  }

  Future<void> saveProductOverrides(
      Map<String, Map<String, dynamic>> overrides) async {
    final file = await _productOverridesFile();
    await file.writeAsString(jsonEncode(overrides));
  }

  Future<String> loadNote() async {
    final file = await _noteFile();
    if (!await file.exists()) return '';
    return await file.readAsString();
  }

  Future<void> saveNote(String text) async {
    final file = await _noteFile();
    await file.writeAsString(text);
  }

  Future<bool> loadDefaultsApplied() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/nutrition_defaults_applied_v4.txt').exists();
  }

  Future<void> saveDefaultsApplied() async {
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/nutrition_defaults_applied_v4.txt').writeAsString('1');
  }
}
