import 'dart:convert';
import 'dart:io';

import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const anthropicMessage = {
  'type': 'message',
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': 'ok'},
  ],
  'stop_reason': 'end_turn',
};
const openAiCompletion = {
  'object': 'chat.completion',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': 'ok'},
      'finish_reason': 'stop',
    },
  ],
};

bool bearer(http.Request r, String key) => r.headers['authorization'] == 'Bearer $key';
bool xKey(http.Request r, String key) => r.headers['x-api-key'] == key && r.headers['anthropic-version'] != null;

void main() {
  group('base URL', () {
    test('trims endpoint paths and offers /v1 as a second guess', () {
      expect(AiConnector.candidateBases(' https://api.inferhub.dev/v1/ '), ['https://api.inferhub.dev/v1']);
      expect(AiConnector.candidateBases('https://api.deepseek.com'), ['https://api.deepseek.com', 'https://api.deepseek.com/v1']);
      expect(AiConnector.candidateBases('http://43.157.206.49:20128/v1/chat/completions'), ['http://43.157.206.49:20128/v1']);
      expect(AiConnector.candidateBases('openrouter.ai/api/v1'), ['https://openrouter.ai/api/v1']);
      expect(AiConnector.candidateBases('https://open.bigmodel.cn/api/paas/v4'), ['https://open.bigmodel.cn/api/paas/v4']);
      expect(AiConnector.candidateBases(''), isEmpty);
      expect(AiConnector.candidateBases('ftp://x'), isEmpty);
    });

    test('plain http to another machine is flagged, localhost is not', () {
      expect(AiConnector.isInsecure('http://43.157.206.49:20128/v1'), isTrue);
      expect(AiConnector.isInsecure('http://localhost:11434/v1'), isFalse);
      expect(AiConnector.isInsecure('https://api.inferhub.dev/v1'), isFalse);
    });
  });

  test('a proxy that lists models OpenAI-style for any headers but serves both formats', () async {
    final client = MockClient((r) async {
      if (r.url.path == '/v1/models') {
        return json({
          'object': 'list',
          'data': [
            {
              'id': 'deepseek-v4-pro',
              'object': 'model',
              'owned_by': 'alias',
            },
            {
              'id': 'ali/deepseek-v4-flash-0731',
              'object': 'model',
              'upstream_label': 'DeepSeek V4 Flash 0731',
              'pricing': {'official_in': 0.22, 'official_out': 0.66},
            },
          ],
        });
      }
      if (r.url.path == '/v1/messages' && xKey(r, 'k')) return json(anthropicMessage);
      if (r.url.path == '/v1/chat/completions' && bearer(r, 'k')) return json(openAiCompletion);
      return json({'error': 'not found'}, 404);
    });
    final ai = AiConnector(client: client);
    final found = await ai.connect('https://hub.example/v1', 'k');
    expect(found.baseUrl, 'https://hub.example/v1');
    expect(found.models.map((m) => m.id), ['ali/deepseek-v4-flash-0731', 'deepseek-v4-pro']);
    expect(found.models.first.label, 'DeepSeek V4 Flash 0731');
    expect(found.models.first.priceIn, 0.22);
    final checks = await ai.probeFormats(found.baseUrl, 'k', 'deepseek-v4-pro');
    expect(checks[ApiFormat.anthropic]!.ok, isTrue);
    expect(checks[ApiFormat.openai]!.ok, isTrue);
    expect(AiConnector.preferredFormat('deepseek-v4-pro', checks), ApiFormat.openai);
    expect(AiConnector.preferredFormat('claude-opus-5-5', checks), ApiFormat.anthropic);
  });

  test("Anthropic's own API: refuses a Bearer key, pages its model list, has no chat/completions", () async {
    final client = MockClient((r) async {
      if (r.url.path == '/v1/models') {
        if (!xKey(r, 'k')) return json({'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}}, 401);
        final after = r.url.queryParameters['after_id'];
        return after == null
            ? json({
                'data': [
                  {'type': 'model', 'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5'},
                ],
                'has_more': true,
                'last_id': 'claude-opus-5-5',
              })
            : json({
                'data': [
                  {'type': 'model', 'id': 'claude-haiku-5-5', 'display_name': 'Claude Haiku 5.5'},
                ],
                'has_more': false,
                'last_id': 'claude-haiku-5-5',
              });
      }
      if (r.url.path == '/v1/messages' && xKey(r, 'k')) return json(anthropicMessage);
      return json({'type': 'error', 'error': {'type': 'not_found_error', 'message': 'Not found'}}, 404);
    });
    final ai = AiConnector(client: client);
    final found = await ai.connect('https://api.anthropic.com', 'k');
    expect(found.baseUrl, 'https://api.anthropic.com/v1', reason: 'the bare host has no /models, so /v1 is tried');
    expect(found.models.map((m) => m.display), ['Claude Haiku 5.5  (claude-haiku-5-5)', 'Claude Opus 5.5  (claude-opus-5-5)']);
    final checks = await ai.probeFormats(found.baseUrl, 'k', 'claude-opus-5-5');
    expect(checks[ApiFormat.anthropic]!.ok, isTrue);
    expect(checks[ApiFormat.openai]!.ok, isFalse);
    expect(AiConnector.preferredFormat('claude-opus-5-5', checks), ApiFormat.anthropic);
  });

  test('an OpenAI-only server whose newest models want max_completion_tokens', () async {
    final client = MockClient((r) async {
      if (!bearer(r, 'k')) return json({'error': {'message': 'Incorrect API key provided'}}, 401);
      if (r.url.path == '/v1/models') {
        return json({
          'object': 'list',
          'data': [
            {'id': 'gpt-x', 'object': 'model'},
          ],
        });
      }
      if (r.url.path == '/v1/chat/completions') {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        if (body.containsKey('max_tokens')) {
          return json({'error': {'message': "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."}}, 400);
        }
        return json(openAiCompletion);
      }
      return json({'error': {'message': 'nope'}}, 404);
    });
    final ai = AiConnector(client: client);
    final found = await ai.connect('https://api.openai.example', 'k');
    expect(found.baseUrl, 'https://api.openai.example/v1');
    final checks = await ai.probeFormats(found.baseUrl, 'k', 'gpt-x');
    expect(checks[ApiFormat.openai]!.ok, isTrue);
    expect(checks[ApiFormat.anthropic]!.ok, isFalse);
  });

  test('a wrong key everywhere is reported as a refused key', () async {
    final ai = AiConnector(client: MockClient((r) async => json({'error': {'message': 'invalid api key'}}, 401)));
    await expectLater(ai.connect('https://hub.example/v1', 'bad'), throwsA(isA<AiError>().having((e) => e.message, 'message', contains('ditolak'))));
  });

  test('an endpoint without a model list still connects, so a model can be typed in', () async {
    final ai = AiConnector(client: MockClient((r) async => json({'error': 'no such route'}, 404)));
    final found = await ai.connect('https://hub.example/v1', 'k');
    expect(found.models, isEmpty);
    expect(found.modelsError, contains('404'));
  });

  test('tool calls are read from either format', () async {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/messages')) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        expect((body['tools'] as List).first['input_schema'], isNotNull);
        return json({
          'type': 'message',
          'content': [
            {'type': 'thinking', 'thinking': '...', 'signature': ''},
            {'type': 'tool_use', 'id': 'toolu_1', 'name': 'tambah_perangkat', 'input': {'jenis': 'kontaktor', 'tag': 'KM1'}},
          ],
          'stop_reason': 'tool_use',
        });
      }
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      expect((body['tools'] as List).first['function']['parameters'], isNotNull);
      return json({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {'name': 'tambah_perangkat', 'arguments': '{"jenis": "kontaktor", "tag": "KM1"}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
    });
    final ai = AiConnector(client: client);
    for (final format in ApiFormat.values) {
      final check = await ai.checkTools('https://hub.example/v1', 'k', format, 'm');
      expect(check.ok, isTrue, reason: format.name);
      expect(check.message, contains('KM1'));
    }
  });

  test('settings survive a round trip and reject unknown formats', () {
    const settings = AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'deepseek-v4-pro');
    final back = AiSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
    expect(back!.baseUrl, settings.baseUrl);
    expect(back.format, ApiFormat.openai);
    expect(AiSettings.fromJson({'baseUrl': 'x', 'model': 'y', 'format': 'gemini'}), isNull);
  });

  // Runs only with a real endpoint: BUILDWIRE_AI_URL and BUILDWIRE_AI_KEY in the environment. Never commit a key.
  final liveUrl = Platform.environment['BUILDWIRE_AI_URL'];
  final liveKey = Platform.environment['BUILDWIRE_AI_KEY'];
  test('live endpoint', () async {
    final ai = AiConnector(client: http.Client(), timeout: const Duration(seconds: 90));
    final found = await ai.connect(liveUrl!, liveKey!);
    // ignore: avoid_print
    print('base ${found.baseUrl}, models: ${found.models.map((m) => m.id).join(', ')}');
    final model = Platform.environment['BUILDWIRE_AI_MODEL'] ?? found.models.first.id;
    final checks = await ai.probeFormats(found.baseUrl, liveKey, model);
    // ignore: avoid_print
    print('formats for $model: ${checks.map((f, c) => MapEntry(f.name, c.ok ? 'ok' : c.error))}');
    for (final format in ApiFormat.values.where((f) => checks[f]!.ok)) {
      final tools = await ai.checkTools(found.baseUrl, liveKey, format, model);
      // ignore: avoid_print
      print('tools via ${format.name}: ${tools.ok} ${tools.message} (${tools.elapsed.inMilliseconds} ms)');
      expect(tools.ok, isTrue);
    }
    ai.close();
  }, skip: liveUrl == null || liveKey == null, timeout: const Timeout(Duration(minutes: 3)));
}
