import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

/// One model an endpoint offers.
class AiModel {
  const AiModel({required this.id, this.label, this.owner, this.priceIn, this.priceOut});

  final String id;

  /// A friendlier name when the endpoint gives one.
  final String? label;
  final String? owner;

  /// Dollars per million tokens, when the endpoint publishes it.
  final double? priceIn;
  final double? priceOut;

  String get display => label == null || label == id ? id : '$label  ($id)';
}

/// Whether a request format answered, and why not if it didn't.
class FormatCheck {
  const FormatCheck.ok() : ok = true, error = null;
  const FormatCheck.failed(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// What connecting to an endpoint found out.
class ConnectResult {
  ConnectResult({required this.baseUrl, required this.models, this.modelsError});

  /// The base URL that worked, which may have gained a `/v1`.
  final String baseUrl;
  final List<AiModel> models;
  final String? modelsError;
}

class ToolCheck {
  const ToolCheck({required this.ok, required this.message, required this.elapsed});

  final bool ok;
  final String message;
  final Duration elapsed;
}

/// Thrown with a message meant for the user, in Indonesian.
class AiError implements Exception {
  AiError(this.message, {this.transient = false});
  final String message;

  /// A passing problem (busy server, dropped connection, timeout) worth retrying.
  final bool transient;

  @override
  String toString() => message;
}

/// Talks to Anthropic- and OpenAI-compatible endpoints: lists models, finds out which formats an endpoint really
/// answers in, and checks a model can call tools.
///
/// The model list is not enough to tell the formats apart: proxies commonly answer `/models` in the OpenAI shape
/// whichever headers are sent, yet serve `/messages` too. So the format is decided by sending each a tiny request.
class AiConnector {
  AiConnector({http.Client? client, this.timeout = const Duration(seconds: 30)})
      : _ownsClient = client == null,
        _client = client ?? http.Client();

  final bool _ownsClient;
  http.Client _client;
  bool _closed = false;
  final Duration timeout;
  final Set<String> _completionTokensModels = {};

  static const anthropicVersion = '2023-06-01';

  static Map<String, String> headers(ApiFormat format, String key) => switch (format) {
        ApiFormat.anthropic => {'x-api-key': key, 'anthropic-version': anthropicVersion, 'content-type': 'application/json'},
        ApiFormat.openai => {'authorization': 'Bearer $key', 'content-type': 'application/json'},
      };

  /// Base URLs to try for what the user typed: trimmed, without a trailing endpoint path, and with `/v1` added as a
  /// second guess when it is missing.
  static List<String> candidateBases(String input) {
    var base = input.trim();
    if (base.isEmpty) return const [];
    if (!base.contains('://')) base = 'https://$base';
    base = base.replaceFirst(RegExp(r'/+$'), '');
    for (final tail in const ['/chat/completions', '/messages', '/models', '/completions']) {
      if (base.endsWith(tail)) base = base.substring(0, base.length - tail.length);
    }
    base = base.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty || !(uri.scheme == 'http' || uri.scheme == 'https')) return const [];
    return [base, if (!RegExp(r'(/v\d+[a-z]*|/openai)$').hasMatch(base)) '$base/v1'];
  }

  /// True when the key would travel unencrypted to another machine.
  static bool isInsecure(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host;
    return !(host == 'localhost' || host == '127.0.0.1' || host == '::1');
  }

  /// True for Google Gemini's OpenAI-compatible endpoint, which serves only OpenAI routes.
  static bool isGeminiOpenAi(String base) => Uri.tryParse(base)?.host.toLowerCase() == 'generativelanguage.googleapis.com';

  /// Finds the base URL that answers and the models on offer.
  Future<ConnectResult> connect(String input, String key) async {
    final bases = candidateBases(input);
    if (bases.isEmpty) throw AiError('Alamat endpoint tidak valid. Contoh: https://api.anthropic.com/v1');
    final errors = <AiError>[];
    for (final base in bases) {
      // Each format logs in differently (Anthropic's own API refuses a Bearer key), so try both before giving up.
      final formats = isGeminiOpenAi(base) ? const [ApiFormat.openai] : const [ApiFormat.openai, ApiFormat.anthropic];
      for (final format in formats) {
        try {
          final models = await _listModels(base, key, format);
          return ConnectResult(baseUrl: base, models: models);
        } on AiError catch (error) {
          errors.add(error);
        }
      }
    }
    final refused = errors.whereType<_AuthError>().firstOrNull;
    if (refused != null && errors.every((e) => e is _AuthError || e.message.startsWith('HTTP 404'))) throw refused;
    // Some endpoints have no model list. Keep the first base; the user can type a model name.
    return ConnectResult(baseUrl: bases.first, models: const [], modelsError: errors.firstOrNull?.message);
  }

  Future<List<AiModel>> _listModels(String base, String key, ApiFormat format) async {
    final models = <AiModel>[];
    final stripPrefix = isGeminiOpenAi(base);
    String? after;
    for (var page = 0; page < 20; page++) {
      final uri = Uri.parse('$base/models${after == null ? '' : '?after_id=${Uri.encodeQueryComponent(after)}'}');
      final json = await _send(() => _client.get(uri, headers: headers(format, key)));
      final data = json is Map<String, dynamic> ? json['data'] : (json is List ? json : null);
      if (data is! List) throw AiError('Jawaban /models tidak berisi daftar model.');
      for (final item in data) {
        final model = _parseModel(item, stripModelsPrefix: stripPrefix);
        if (model != null) models.add(model);
      }
      // Anthropic pages its list; OpenAI-style lists come whole.
      final more = json is Map<String, dynamic> && json['has_more'] == true;
      final last = json is Map<String, dynamic> ? json['last_id'] : null;
      if (!more || last is! String || last == after) break;
      after = last;
    }
    final seen = <String>{};
    models.retainWhere((m) => seen.add(m.id));
    models.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return models;
  }

  static AiModel? _parseModel(Object? item, {bool stripModelsPrefix = false}) {
    if (item is String) {
      final id = stripModelsPrefix && item.startsWith('models/') ? item.substring(7) : item;
      return AiModel(id: id);
    }
    if (item is! Map<String, dynamic>) return null;
    final rawId = item['id'] ?? item['name'] ?? item['model'];
    if (rawId is! String || rawId.isEmpty) return null;
    final id = stripModelsPrefix && rawId.startsWith('models/') ? rawId.substring(7) : rawId;
    final label = [item['display_name'], item['upstream_label'], item['name']].whereType<String>().where((s) => s.isNotEmpty && s != id && s != rawId).firstOrNull;
    final pricing = item['pricing'];
    double? price(String key) {
      if (pricing is! Map<String, dynamic>) return null;
      final value = pricing[key];
      return value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);
    }

    final owner = item['owned_by'];
    return AiModel(id: id, label: label, owner: owner is String ? owner : null, priceIn: price('official_in'), priceOut: price('official_out'));
  }

  /// Sends a tiny request in each format and reports which ones answer properly.
  Future<Map<ApiFormat, FormatCheck>> probeFormats(String base, String key, String model) async {
    Future<FormatCheck> check(ApiFormat format) async {
      try {
        final reply = await chat(base, key, format, model, [
          {'role': 'user', 'content': 'Balas dengan satu kata: ok'},
        ], maxTokens: 256);
        return reply.valid ? const FormatCheck.ok() : const FormatCheck.failed('Jawaban tidak sesuai format.');
      } on AiError catch (error) {
        return FormatCheck.failed(error.message);
      }
    }

    if (isGeminiOpenAi(base)) {
      return {
        ApiFormat.anthropic: const FormatCheck.failed('Endpoint Google Gemini hanya mendukung format OpenAI.'),
        ApiFormat.openai: await check(ApiFormat.openai),
      };
    }
    final results = await Future.wait([check(ApiFormat.anthropic), check(ApiFormat.openai)]);
    return {ApiFormat.anthropic: results[0], ApiFormat.openai: results[1]};
  }

  /// The format to use when both work: Claude models natively, everything else in the OpenAI shape.
  static ApiFormat preferredFormat(String model, Map<ApiFormat, FormatCheck> checks) {
    final anthropic = checks[ApiFormat.anthropic]?.ok ?? false;
    final openai = checks[ApiFormat.openai]?.ok ?? false;
    if (anthropic && openai) return model.toLowerCase().contains('claude') ? ApiFormat.anthropic : ApiFormat.openai;
    return anthropic ? ApiFormat.anthropic : ApiFormat.openai;
  }

  /// Asks the model to call a tool and checks it does, in the chosen format.
  Future<ToolCheck> checkTools(String base, String key, ApiFormat format, String model) async {
    final clock = Stopwatch()..start();
    const name = 'tambah_perangkat';
    final schema = {
      'type': 'object',
      'properties': {
        'jenis': {'type': 'string', 'description': 'Jenis perangkat, misalnya kontaktor atau MCB.'},
        'tag': {'type': 'string', 'description': 'Tag perangkat, misalnya KM1.'},
      },
      'required': ['jenis', 'tag'],
    };
    try {
      final reply = await chat(base, key, format, model, [
        {'role': 'user', 'content': 'Tambahkan sebuah kontaktor dengan tag KM1 ke kanvas. Gunakan alat tambah_perangkat.'},
      ], tools: [
        AiTool(name: name, description: 'Menambahkan satu perangkat listrik ke kanvas.', schema: schema),
      ], maxTokens: 1024);
      final call = reply.toolCalls.where((c) => c.name == name).firstOrNull;
      if (call == null) {
        return ToolCheck(ok: false, message: 'Model menjawab tanpa memakai alat. Model ini mungkin tidak cocok untuk merakit rangkaian.', elapsed: clock.elapsed);
      }
      final tag = call.input['tag'];
      return ToolCheck(
        ok: true,
        message: 'Model bisa memakai alat (memanggil $name dengan tag ${tag ?? '?'}).',
        elapsed: clock.elapsed,
      );
    } on AiError catch (error) {
      return ToolCheck(ok: false, message: error.message, elapsed: clock.elapsed);
    }
  }

  /// One request in either format. [messages] use the simple `{role, content}` shape; tools are translated.
  Future<AiReply> chat(String base, String key, ApiFormat format, String model, List<Map<String, Object?>> messages,
      {List<AiTool> tools = const [], int maxTokens = 4096, String? system}) async {
    switch (format) {
      case ApiFormat.anthropic:
        final body = {
          'model': model,
          'max_tokens': maxTokens,
          'system': ?system,
          'messages': messages,
          if (tools.isNotEmpty) 'tools': [for (final t in tools) {'name': t.name, 'description': t.description, 'input_schema': t.schema}],
        };
        final json = await _send(() => _client.post(Uri.parse('$base/messages'), headers: headers(format, key), body: jsonEncode(body)));
        return AiReply.fromAnthropic(json);
      case ApiFormat.openai:
        Map<String, Object?> body(String tokensField) => {
              'model': model,
              tokensField: maxTokens,
              'messages': [
                if (system != null) {'role': 'system', 'content': system},
                ...messages,
              ],
              if (tools.isNotEmpty)
                'tools': [
                  for (final t in tools)
                    {
                      'type': 'function',
                      'function': {'name': t.name, 'description': t.description, 'parameters': t.schema},
                    },
                ],
            };
        Future<Object?> post(String field) =>
            _send(() => _client.post(Uri.parse('$base/chat/completions'), headers: headers(format, key), body: jsonEncode(body(field))));
        final cacheKey = '$base|$model';
        if (_completionTokensModels.contains(cacheKey)) {
          return AiReply.fromOpenAi(await post('max_completion_tokens'));
        }
        try {
          return AiReply.fromOpenAi(await post('max_tokens'));
        } on AiError catch (error) {
          // Newer OpenAI models refuse max_tokens and want max_completion_tokens instead.
          if (!error.message.contains('max_completion_tokens')) rethrow;
          final reply = AiReply.fromOpenAi(await post('max_completion_tokens'));
          _completionTokensModels.add(cacheKey);
          return reply;
        }
    }
  }

  Future<Object?> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw AiError('Endpoint tidak menjawab dalam ${timeout.inSeconds} detik.', transient: true);
    } catch (error) {
      throw AiError('Tidak bisa terhubung ke endpoint. Periksa alamat dan koneksi internet. ($error)', transient: true);
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = null;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw _AuthError('API key ditolak (HTTP ${response.statusCode}). ${_errorText(json, text)}'.trim());
    }
    if (response.statusCode == 429) {
      throw AiError('Batas kuota atau rate-limit tercapai (HTTP 429). ${_errorText(json, text)}'.trim(), transient: true);
    }
    if (response.statusCode >= 400) {
      final code = response.statusCode;
      final detail = _errorText(json, text);
      if (code == 400 && _looksLikeInvalidKey(json, detail)) {
        throw _AuthError('API key ditolak (HTTP 400). $detail'.trim());
      }
      throw AiError('HTTP $code: $detail'.trim(), transient: code == 408 || code == 409 || code == 425 || code >= 500);
    }
    if (json == null) throw AiError('Jawaban endpoint bukan JSON.', transient: true);
    return json;
  }

  static bool _looksLikeInvalidKey(Object? json, String detail) {
    final lower = detail.toLowerCase();
    if (lower.contains('api key') || lower.contains('api_key_invalid')) return true;
    final first = json is List && json.isNotEmpty ? json.first : json;
    if (first is Map<String, dynamic>) {
      final err = first['error'];
      if (err is Map<String, dynamic> && err['details'] is List) {
        return (err['details'] as List).any((d) => d is Map && d['reason'] == 'API_KEY_INVALID');
      }
    }
    return false;
  }

  static String _errorText(Object? json, String raw) {
    if (json is List && json.isNotEmpty) return _errorText(json.first, raw);
    if (json is Map<String, dynamic>) {
      final error = json['error'];
      if (error is Map<String, dynamic> && error['message'] is String) return error['message'] as String;
      if (error is String) return error;
      if (json['message'] is String) return json['message'] as String;
    }
    final short = raw.trim();
    return short.length > 200 ? '${short.substring(0, 200)}…' : short;
  }

  /// Aborts any in-flight requests on an owned client and swaps in a fresh client for future calls.
  void cancelPending() {
    if (!_ownsClient || _closed) return;
    _client.close();
    _client = http.Client();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class _AuthError extends AiError {
  _AuthError(super.message);
}

/// A tool the model may call, described once and translated to either format.
class AiTool {
  const AiTool({required this.name, required this.description, required this.schema});

  final String name;
  final String description;
  final Map<String, Object> schema;
}

class AiToolCall {
  const AiToolCall({required this.id, required this.name, required this.input, this.badArguments = false});

  final String id;
  final String name;
  final Map<String, dynamic> input;

  /// The arguments came as text that isn't a JSON object, usually because the reply was cut off.
  final bool badArguments;
}

/// A model's answer, the same whichever format it came in.
class AiReply {
  const AiReply({required this.valid, required this.text, required this.toolCalls, required this.raw, this.truncated = false});

  /// The response had the expected shape.
  final bool valid;

  /// The model ran out of output tokens, so the text or the last tool call may be incomplete.
  final bool truncated;
  final String text;
  final List<AiToolCall> toolCalls;
  final Object? raw;

  factory AiReply.fromAnthropic(Object? json) {
    final content = json is Map<String, dynamic> ? json['content'] : null;
    if (json is! Map<String, dynamic> || content is! List) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
    final text = StringBuffer();
    final calls = <AiToolCall>[];
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      if (block['type'] == 'text' && block['text'] is String) text.write(block['text']);
      if (block['type'] == 'tool_use') {
        final input = block['input'];
        calls.add(AiToolCall(
          id: '${block['id']}',
          name: '${block['name']}',
          input: input is Map<String, dynamic> ? input : const {},
          badArguments: input != null && input is! Map<String, dynamic>,
        ));
      }
    }
    return AiReply(valid: true, text: text.toString(), toolCalls: calls, raw: json, truncated: json['stop_reason'] == 'max_tokens');
  }

  factory AiReply.fromOpenAi(Object? json) {
    final choices = json is Map<String, dynamic> ? json['choices'] : null;
    if (choices is! List || choices.isEmpty) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
    final first = choices.first;
    if (first is! Map<String, dynamic>) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
    final message = first['message'];
    if (message is! Map<String, dynamic>) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
    final calls = <AiToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final call in rawCalls) {
        if (call is! Map<String, dynamic>) continue;
        final function = call['function'];
        if (function is! Map<String, dynamic>) continue;
        Map<String, dynamic> input = const {};
        var bad = false;
        final args = function['arguments'];
        if (args is String && args.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(args);
            if (decoded is Map<String, dynamic>) {
              input = decoded;
            } else {
              bad = true;
            }
          } on FormatException {
            bad = true;
          }
        } else if (args is Map<String, dynamic>) {
          input = args;
        } else if (args != null && args is! String) {
          bad = true;
        }
        calls.add(AiToolCall(id: '${call['id']}', name: '${function['name']}', input: input, badArguments: bad));
      }
    }
    final content = message['content'];
    final finish = first['finish_reason'];
    return AiReply(valid: true, text: content is String ? content : '', toolCalls: calls, raw: json, truncated: finish == 'length');
  }
}
