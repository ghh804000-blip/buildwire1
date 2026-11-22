import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../ai/ai_connector.dart';
import '../ai/ai_settings.dart';
import '../app_state.dart';
import 'theme.dart';

/// Google AI Studio's official OpenAI-compatible base URL and fast free-tier default model.
const String kGeminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai';
const String kGeminiDefaultModel = 'gemini-2.5-flash';

/// Common endpoints. Anything else is typed in as a custom address.
const List<(String, String)> kAiPresets = [
  ('Google Gemini (AI Studio)', kGeminiBaseUrl),
  ('Anthropic', 'https://api.anthropic.com/v1'),
  ('OpenAI', 'https://api.openai.com/v1'),
  ('DeepSeek', 'https://api.deepseek.com/v1'),
  ('OpenRouter', 'https://openrouter.ai/api/v1'),
  ('Ollama (lokal)', 'http://localhost:11434/v1'),
];

Future<void> showAiSettings(BuildContext context, AppState app, {AiConnector? connector}) => showDialog<void>(
      context: context,
      builder: (_) => _AiSettingsDialog(app: app, connector: connector),
    );

class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog({required this.app, this.connector});

  final AppState app;
  final AiConnector? connector;

  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  late final AiConnector _ai = widget.connector ?? AiConnector();
  final _url = TextEditingController();
  final _key = TextEditingController();
  final _typedModel = TextEditingController();
  bool _hideKey = true;

  /// What is running now, shown next to a spinner, or null when idle.
  String? _busy;
  String? _error;
  ConnectResult? _found;
  String? _model;
  Map<ApiFormat, FormatCheck>? _checks;
  ApiFormat? _format;
  ToolCheck? _tools;
  bool _manualModel = false;

  /// Bumped on every new connect or model choice, so a slow earlier answer can't overwrite a newer one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final saved = widget.app.aiSettings;
    if (saved != null) {
      _url.text = saved.baseUrl;
      _model = saved.model;
      _typedModel.text = saved.model;
      _format = saved.format;
    }
    widget.app.secrets.readKey().then((key) {
      if (mounted && key != null && _key.text.isEmpty) setState(() => _key.text = key);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _typedModel.dispose();
    if (widget.connector == null) _ai.close();
    super.dispose();
  }

  void _endpointChanged() {
    if (_found == null && _error == null && !_manualModel) return;
    setState(() {
      _generation++;
      _found = null;
      _checks = null;
      _tools = null;
      _error = null;
      _manualModel = false;
    });
  }

  String? _pickInitialModel(String baseUrl, List<String> ids) {
    if (_model != null && ids.contains(_model)) return _model;
    final typed = _typedModel.text.trim();
    if (ids.isEmpty) return typed.isNotEmpty ? typed : (AiConnector.isGeminiOpenAi(baseUrl) ? kGeminiDefaultModel : null);
    if (AiConnector.isGeminiOpenAi(baseUrl)) {
      if (ids.contains(kGeminiDefaultModel)) return kGeminiDefaultModel;
      final flash = ids.where((id) {
        final lower = id.toLowerCase();
        return lower.contains('gemini') && !lower.contains('embedding');
      }).firstOrNull;
      if (flash != null) return flash;
    }
    return ids.first;
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    setState(() {
      _busy = 'Menghubungkan dan mengambil daftar model…';
      _error = null;
      _found = null;
      _checks = null;
      _tools = null;
    });
    try {
      final found = await _ai.connect(_url.text, _key.text.trim());
      if (!mounted || generation != _generation) return;
      final ids = found.models.map((m) => m.id).toList();
      final picked = _pickInitialModel(found.baseUrl, ids);
      setState(() {
        _found = found;
        _url.text = found.baseUrl;
        _model = picked;
        if (picked != null) _typedModel.text = picked;
        _manualModel = ids.isEmpty;
      });
      if (_model != null) await _probe(generation);
    } on AiError catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.message);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = null);
    }
  }

  Future<void> _chooseModel(String? model) async {
    final trimmed = model?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (trimmed == _model && (_checks?.values.any((c) => c.ok) ?? false)) return;
    final generation = ++_generation;
    setState(() {
      _model = trimmed;
      _typedModel.text = trimmed;
      _checks = null;
      _tools = null;
      _error = null;
    });
    await _probe(generation);
    if (mounted && generation == _generation) setState(() => _busy = null);
  }

  /// Finds out which formats answer for the chosen model.
  Future<void> _probe(int generation) async {
    final found = _found, model = _model;
    if (found == null || model == null) return;
    setState(() => _busy = 'Memeriksa format Anthropic dan OpenAI untuk $model…');
    final checks = await _ai.probeFormats(found.baseUrl, _key.text.trim(), model);
    if (!mounted || generation != _generation) return;
    final any = checks.values.any((c) => c.ok);
    setState(() {
      _checks = checks;
      _format = any ? AiConnector.preferredFormat(model, checks) : null;
      if (!any) {
        _error = 'Model ini tidak menjawab di format mana pun.\n'
            'Anthropic: ${checks[ApiFormat.anthropic]!.error}\nOpenAI: ${checks[ApiFormat.openai]!.error}';
      }
    });
  }

  Future<void> _testTools() async {
    final found = _found, model = _model, format = _format;
    if (found == null || model == null || format == null) return;
    final generation = ++_generation;
    setState(() {
      _busy = 'Meminta model memakai alat…';
      _tools = null;
    });
    final result = await _ai.checkTools(found.baseUrl, _key.text.trim(), format, model);
    if (!mounted || generation != _generation) return;
    setState(() {
      _tools = result;
      _busy = null;
    });
  }

  Future<void> _save() async {
    final found = _found, model = _model, format = _format;
    if (found == null || model == null || format == null) return;
    try {
      await widget.app.saveAi(AiSettings(baseUrl: found.baseUrl, format: format, model: model), _key.text.trim());
      if (mounted) Navigator.of(context).pop();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'Gagal menyimpan pengaturan AI: $error');
    }
  }

  Future<void> _forget() async {
    try {
      await widget.app.forgetAi();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = 'Gagal menghapus pengaturan AI: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final found = _found;
    final canSave = _busy == null && found != null && _model != null && _format != null && (_checks?[_format]?.ok ?? false);
    return AlertDialog(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 4),
      title: Row(
        children: [
          Icon(Icons.vpn_key_outlined, size: 20, color: tokens.text),
          const SizedBox(width: 10),
          Text('Pengaturan AI', style: uiText(17, tokens.text, weight: 700)),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Pakai API key milikmu sendiri. Endpoint yang kompatibel dengan Anthropic atau OpenAI dideteksi otomatis.',
                style: uiText(13, tokens.textMuted, height: 1.45),
              ),
              const SizedBox(height: 16),
              _label(tokens, 'Endpoint'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (name, url) in kAiPresets)
                    ChoiceChip(
                      key: ValueKey('ai-preset-$name'),
                      label: Text(name, style: uiText(12.5, tokens.text)),
                      selected: AiConnector.candidateBases(_url.text).firstOrNull == url,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        _url.text = url;
                        if (url == kGeminiBaseUrl && !_typedModel.text.toLowerCase().contains('gemini')) {
                          _typedModel.text = kGeminiDefaultModel;
                        }
                        _endpointChanged();
                        setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('ai-url'),
                controller: _url,
                style: uiText(13.5, tokens.text),
                decoration: const InputDecoration(hintText: 'https://api.contoh.com/v1'),
                onChanged: (_) {
                  _endpointChanged();
                  setState(() {});
                },
              ),
              if (AiConnector.isInsecure(AiConnector.candidateBases(_url.text).firstOrNull ?? '')) ...[
                const SizedBox(height: 6),
                _note(tokens, Icons.lock_open_outlined, tokens.warning,
                    'Peringatan: alamat ini memakai HTTP tanpa enkripsi. API key dan percakapan dikirim plaintext — gunakan hanya di jaringan lokal/LAN yang tepercaya.'),
              ],
              const SizedBox(height: 14),
              _label(tokens, 'API key'),
              TextField(
                key: const ValueKey('ai-key'),
                controller: _key,
                obscureText: _hideKey,
                style: uiText(13.5, tokens.text),
                onChanged: (_) => _endpointChanged(),
                decoration: InputDecoration(
                  hintText: 'AIza… / sk-…  (boleh kosong untuk Ollama lokal)',
                  suffixIcon: IconButton(
                    tooltip: _hideKey ? 'Tampilkan' : 'Sembunyikan',
                    icon: Icon(_hideKey ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    onPressed: () => setState(() => _hideKey = !_hideKey),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                kIsWeb
                    ? 'Disimpan di penyimpanan browser perangkat ini dan hanya dikirim ke endpoint di atas.'
                    : defaultTargetPlatform == TargetPlatform.windows
                        ? 'Disimpan terenkripsi di komputer ini (Windows DPAPI) dan hanya dikirim ke endpoint di atas.'
                        : 'Disimpan di penyimpanan aman perangkat ini dan hanya dikirim ke endpoint di atas.',
                style: uiText(12, tokens.textMuted),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('ai-connect'),
                  onPressed: _busy != null || AiConnector.candidateBases(_url.text).isEmpty ? null : _connect,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(found == null ? 'Hubungkan' : 'Hubungkan ulang'),
                ),
              ),
              if (found != null) ...[
                const SizedBox(height: 18),
                Divider(color: tokens.border, height: 1),
                const SizedBox(height: 16),
                _label(tokens, found.models.isEmpty || _manualModel ? 'Model (ketik namanya)' : 'Model (${found.models.length} tersedia)'),
                if (found.models.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _note(tokens, Icons.info_outline, tokens.textMuted, 'Endpoint ini tidak memberi daftar model. ${found.modelsError ?? ''}'.trim()),
                  ),
                if (found.models.isEmpty || _manualModel)
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('ai-model-typed'),
                          controller: _typedModel,
                          style: uiText(13.5, tokens.text),
                          decoration: InputDecoration(
                            hintText: AiConnector.isGeminiOpenAi(found.baseUrl) ? kGeminiDefaultModel : 'nama-model',
                          ),
                          onChanged: (value) {
                            if (value.trim() != _model && (_checks != null || _tools != null || _error != null)) {
                              setState(() {
                                _generation++;
                                _checks = null;
                                _tools = null;
                                _error = null;
                              });
                            }
                          },
                          onSubmitted: _chooseModel,
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const ValueKey('ai-model-check'),
                        onPressed: _busy != null ? null : () => _chooseModel(_typedModel.text.trim()),
                        child: const Text('Periksa'),
                      ),
                    ],
                  )
                else
                  LayoutBuilder(
                    builder: (context, box) => DropdownMenu<String>(
                      key: const ValueKey('ai-model'),
                      width: box.maxWidth,
                      initialSelection: found.models.any((m) => m.id == _model) ? _model : null,
                      enableFilter: true,
                      requestFocusOnTap: true,
                      menuHeight: 320,
                      textStyle: uiText(13.5, tokens.text),
                      hintText: 'Cari model…',
                      onSelected: _chooseModel,
                      dropdownMenuEntries: [
                        for (final model in found.models)
                          DropdownMenuEntry(
                            value: model.id,
                            label: model.display,
                            trailingIcon: model.priceIn == null
                                ? null
                                : Text('\$${model.priceIn}/\$${model.priceOut}', style: uiText(11, tokens.textMuted)),
                          ),
                      ],
                    ),
                  ),
                if (found.models.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('ai-model-mode'),
                        onPressed: _busy != null ? null : () => setState(() => _manualModel = !_manualModel),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(_manualModel ? 'Pilih dari daftar model' : 'Ketik nama model manual', style: uiText(12, tokens.accent)),
                      ),
                    ),
                  ),
                if (_checks != null) ...[
                  const SizedBox(height: 14),
                  _label(tokens, 'Format'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final format in ApiFormat.values)
                        ChoiceChip(
                          key: ValueKey('ai-format-${format.name}'),
                          avatar: Icon(_checks![format]!.ok ? Icons.check_circle : Icons.cancel_outlined, size: 16,
                              color: _checks![format]!.ok ? tokens.run : tokens.textMuted),
                          label: Text('${format.label}-compatible', style: uiText(12.5, tokens.text)),
                          tooltip: _checks![format]!.error,
                          selected: _format == format,
                          showCheckmark: false,
                          onSelected: _checks![format]!.ok ? (_) => setState(() => _format = format) : null,
                        ),
                    ],
                  ),
                  if (_checks!.values.every((c) => c.ok))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Endpoint ini mendukung keduanya. Pilihan otomatis: ${AiConnector.preferredFormat(_model!, _checks!).label}.',
                          style: uiText(12, tokens.textMuted)),
                    ),
                ],
                if (_format != null && (_checks?[_format]?.ok ?? false)) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('ai-test-tools'),
                        onPressed: _busy != null ? null : _testTools,
                        icon: const Icon(Icons.handyman_outlined, size: 17),
                        label: const Text('Tes kemampuan alat'),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Memastikan model bisa merakit lewat alat aplikasi.', style: uiText(12, tokens.textMuted)),
                      ),
                    ],
                  ),
                  if (_tools != null) ...[
                    const SizedBox(height: 8),
                    _note(
                      tokens,
                      _tools!.ok ? Icons.check_circle_outline : Icons.error_outline,
                      _tools!.ok ? tokens.run : tokens.error,
                      '${_tools!.message} (${(_tools!.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} dtk)',
                    ),
                  ],
                ],
              ],
              if (_busy != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.accent)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_busy!, style: uiText(12.5, tokens.textMuted))),
                  ],
                ),
              ],
              if (found != null && AiConnector.isInsecure(found.baseUrl)) ...[
                const SizedBox(height: 12),
                _note(tokens, Icons.lock_open_outlined, tokens.warning,
                    'Koneksi aktif memakai HTTP tanpa enkripsi (plaintext). Pastikan jaringan lokal/LAN ini tepercaya sebelum menyimpan.'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                _note(tokens, Icons.error_outline, tokens.error, _error!),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      actions: [
        if (widget.app.aiSettings != null)
          TextButton(
            key: const ValueKey('ai-forget'),
            onPressed: _busy != null ? null : _forget,
            style: TextButton.styleFrom(foregroundColor: tokens.error),
            child: const Text('Hapus pengaturan'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Batal')),
        FilledButton(key: const ValueKey('ai-save'), onPressed: canSave ? _save : null, child: const Text('Simpan')),
      ],
    );
  }

  Widget _label(Tokens tokens, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: uiText(12.5, tokens.text, weight: 600)),
      );

  Widget _note(Tokens tokens, IconData icon, Color color, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
          const SizedBox(width: 6),
          Expanded(child: SelectableText(text, style: uiText(12.5, color == tokens.textMuted ? tokens.textMuted : color, height: 1.4))),
        ],
      );
}
