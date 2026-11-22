import 'dart:convert';
import 'dart:io';

import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/ui/ai_settings_dialog.dart';
import 'package:buildwire/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Quiet extends SoundPlayer {
  @override
  Future<void> preload(Iterable<String> names) async {}
}

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  testWidgets('connecting finds the models and formats, tests tools, and saves the key apart from the settings', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final secrets = MemorySecretStore();
    final app = AppState(defs, null, sound: Quiet(), secrets: secrets);
    final client = MockClient((r) async {
      if (r.url.path == '/v1/models') {
        return json({
          'object': 'list',
          'data': [
            {'id': 'deepseek-v4-flash', 'object': 'model'},
            {'id': 'deepseek-v4-pro', 'object': 'model'},
          ],
        });
      }
      if (r.url.path == '/v1/messages') {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        if (body['tools'] != null) {
          return json({
            'type': 'message',
            'content': [
              {'type': 'tool_use', 'id': 't1', 'name': 'tambah_perangkat', 'input': {'jenis': 'kontaktor', 'tag': 'KM1'}},
            ],
          });
        }
        return json({
          'type': 'message',
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
        });
      }
      if (r.url.path == '/v1/chat/completions') {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final message = body['tools'] != null
            ? {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'c1',
                    'type': 'function',
                    'function': {'name': 'tambah_perangkat', 'arguments': '{"jenis":"kontaktor","tag":"KM1"}'},
                  },
                ],
              }
            : {'role': 'assistant', 'content': 'ok'};
        return json({
          'choices': [
            {'message': message},
          ],
        });
      }
      return json({'error': 'nope'}, 404);
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(false),
      home: Builder(
        builder: (context) => TextButton(onPressed: () => showAiSettings(context, app, connector: AiConnector(client: client)), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('ai-url')), 'hub.example');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'sk-test');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ai-save'))).onPressed, isNull, reason: 'nothing to save yet');
    await tester.tap(find.byKey(const ValueKey('ai-connect')));
    await tester.pumpAndSettle();

    expect(find.text('Model (2 tersedia)'), findsOneWidget);
    expect(find.text('https://hub.example/v1'), findsOneWidget, reason: 'the /v1 that worked is filled in');
    expect(find.textContaining('mendukung keduanya'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-test-tools')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Model bisa memakai alat'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();
    expect(app.aiSettings!.baseUrl, 'https://hub.example/v1');
    expect(app.aiSettings!.model, 'deepseek-v4-flash');
    expect(app.aiSettings!.format, ApiFormat.openai);
    expect(secrets.key, 'sk-test');
    expect(jsonEncode(app.aiSettings!.toJson()), isNot(contains('sk-test')), reason: 'the key never goes into preferences');
    app.dispose();
  });

  testWidgets('Google Gemini preset picks gemini-2.5-flash by default and allows manual model entry', (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final secrets = MemorySecretStore();
    final app = AppState(defs, null, sound: Quiet(), secrets: secrets);
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/messages')) fail('Gemini preset should not hit Anthropic /messages');
      if (r.url.host == 'generativelanguage.googleapis.com' && r.url.path == '/v1beta/openai/models') {
        return json({
          'object': 'list',
          'data': [
            {'id': 'models/embedding-001', 'object': 'model'},
            {'id': 'models/gemini-2.5-flash', 'object': 'model'},
          ],
        });
      }
      if (r.url.host == 'generativelanguage.googleapis.com' && r.url.path == '/v1beta/openai/chat/completions') {
        return json({
          'choices': [
            {'message': {'role': 'assistant', 'content': 'ok'}},
          ],
        });
      }
      return json({'error': 'nope'}, 404);
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(false),
      home: Builder(
        builder: (context) => TextButton(onPressed: () => showAiSettings(context, app, connector: AiConnector(client: client)), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ai-preset-Google Gemini (AI Studio)')));
    await tester.pump();
    expect(find.text(kGeminiBaseUrl), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'AIza-test-key');
    await tester.tap(find.byKey(const ValueKey('ai-connect')));
    await tester.pumpAndSettle();

    expect(find.text('Model (2 tersedia)'), findsOneWidget);
    expect(tester.widget<DropdownMenu<String>>(find.byKey(const ValueKey('ai-model'))).initialSelection, 'gemini-2.5-flash');

    await tester.ensureVisible(find.byKey(const ValueKey('ai-model-mode')));
    await tester.tap(find.byKey(const ValueKey('ai-model-mode')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-model-typed')), 'gemini-2.5-pro');
    await tester.ensureVisible(find.byKey(const ValueKey('ai-model-check')));
    await tester.tap(find.byKey(const ValueKey('ai-model-check')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();
    expect(app.aiSettings!.baseUrl, kGeminiBaseUrl);
    expect(app.aiSettings!.model, 'gemini-2.5-pro');
    expect(app.aiSettings!.format, ApiFormat.openai);
    expect(secrets.key, 'AIza-test-key');
    expect(jsonEncode(app.aiSettings!.toJson()), isNot(contains('AIza-test-key')));
    app.dispose();
  });
}
