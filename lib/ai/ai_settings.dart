import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two request formats an AI endpoint can speak. Many proxies speak both.
enum ApiFormat {
  anthropic('Anthropic'),
  openai('OpenAI');

  const ApiFormat(this.label);
  final String label;
}

/// Where the user's AI lives. The API key is not in here: it is kept apart, encrypted, in a [SecretStore].
class AiSettings {
  const AiSettings({required this.baseUrl, required this.format, required this.model});

  /// Normalized base URL, ending before `/models`, `/messages` or `/chat/completions`.
  final String baseUrl;
  final ApiFormat format;
  final String model;

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl, 'format': format.name, 'model': model};

  static AiSettings? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final base = json['baseUrl'], model = json['model'], format = json['format'];
    if (base is! String || model is! String || format is! String) return null;
    final known = ApiFormat.values.where((f) => f.name == format);
    if (known.isEmpty) return null;
    return AiSettings(baseUrl: base, format: known.first, model: model);
  }

  static const _prefsKey = 'ai-settings';

  static AiSettings? load(SharedPreferences? prefs) {
    final raw = prefs?.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  static Future<void> save(SharedPreferences? prefs, AiSettings? settings) async {
    if (prefs == null) return;
    settings == null ? await prefs.remove(_prefsKey) : await prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
  }
}

/// Keeps the API key. On Windows the real store encrypts it with DPAPI, tied to the Windows user account.
abstract class SecretStore {
  Future<String?> readKey();
  Future<void> writeKey(String? key);
}

class SecureSecretStore implements SecretStore {
  static const _name = 'ai-api-key';
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> readKey() async {
    try {
      return await _storage.read(key: _name);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeKey(String? key) async {
    try {
      key == null || key.isEmpty ? await _storage.delete(key: _name) : await _storage.write(key: _name, value: key);
    } catch (error) {
      if (key == null || key.isEmpty) return;
      throw FormatException('Gagal menyimpan API key secara aman: $error');
    }
  }
}

class MemorySecretStore implements SecretStore {
  MemorySecretStore([this.key]);
  String? key;

  @override
  Future<String?> readKey() async => key;

  @override
  Future<void> writeKey(String? key) async => this.key = key;
}
