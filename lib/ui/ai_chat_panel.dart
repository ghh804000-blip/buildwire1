import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../ai/ai_agent.dart';
import '../ai/ai_attachment.dart';
import '../app_state.dart';
import 'ai_settings_dialog.dart';
import 'theme.dart';

const List<String> _suggestions = [
  'Buatkan rangkaian DOL motor 3 fasa dengan lampu indikator jalan',
  'Buatkan motor forward-reverse dengan interlock',
  'Buatkan star-delta otomatis pakai PLC',
  'Periksa rangkaianku, kenapa tidak jalan?',
];

/// The assistant's chat beside the canvas.
class AiChatPanel extends StatefulWidget {
  const AiChatPanel({super.key, required this.app, this.agent, this.intro, this.suggestions, this.onClose, this.width, this.hint});

  final AppState app;

  /// Another assistant than the canvas one, e.g. the ladder editor's.
  final AiAgent? agent;
  final String? intro;
  final List<String>? suggestions;
  final VoidCallback? onClose;

  /// A fixed width instead of the canvas panel's resizable one.
  final double? width;

  /// The composer's placeholder.
  final String? hint;

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);

  AiAgent get agent => widget.agent ?? widget.app.ai;

  /// Pictures and files waiting to go with the next message.
  final List<AiAttachment> _pending = [];
  bool _loading = false;
  bool _dragging = false;
  String? _attachError;

  static const int _maxAttachments = 6;
  static const int _maxFileBytes = 20 * 1024 * 1024;

  /// Reads files into attachments, keeping the first problem to show under the composer.
  Future<void> _addFiles(List<(String, Future<Uint8List> Function(), int)> files) async {
    if (files.isEmpty || !mounted) return;
    setState(() {
      _loading = true;
      _attachError = null;
    });
    String? problem;
    for (final (name, read, size) in files) {
      if (!mounted) return;
      if (_pending.length >= _maxAttachments) {
        problem = 'Paling banyak $_maxAttachments lampiran per pesan.';
        break;
      }
      if (size > _maxFileBytes) {
        problem = '"$name" terlalu besar (maksimal 20 MB).';
        continue;
      }
      try {
        final attachment = await AiAttachment.load(name, await read());
        if (mounted) setState(() => _pending.add(attachment));
      } on FormatException catch (error) {
        problem = error.message;
      } catch (error) {
        problem = '"$name" tidak bisa dibaca: $error';
      }
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _attachError = problem;
      });
    }
  }

  Future<void> _pick() async {
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Gambar', extensions: AiAttachment.imageExtensions),
          XTypeGroup(label: 'File teks dan program', extensions: [...AiAttachment.textExtensions, ...AiAttachment.otherExtensions]),
        ],
      );
      if (!mounted) return;
      final items = <(String, Future<Uint8List> Function(), int)>[];
      for (final f in files) {
        items.add((f.name, f.readAsBytes, await f.length()));
        if (!mounted) return;
      }
      await _addFiles(items);
      if (mounted) _focus.requestFocus();
    } catch (error) {
      if (mounted) setState(() => _attachError = 'Lampiran gagal dibaca: $error');
    }
  }

  Future<void> _drop(DropDoneDetails details) async {
    if (!mounted) return;
    setState(() => _dragging = false);
    if (widget.app.aiSettings == null) return;
    try {
      final items = <(String, Future<Uint8List> Function(), int)>[];
      for (final f in details.files) {
        items.add((f.name, f.readAsBytes, await f.length()));
        if (!mounted) return;
      }
      await _addFiles(items);
    } catch (error) {
      if (mounted) setState(() => _attachError = 'Lampiran gagal dibaca: $error');
    }
  }

  /// Ctrl+V: a copied picture (a screenshot, an image copied from a browser) or files copied in Explorer become
  /// attachments. Text still pastes into the box as usual.
  Future<void> _pasteAttachments() async {
    try {
      final files = await Pasteboard.files();
      if (!mounted) return;
      if (files.isNotEmpty) {
        final items = <(String, Future<Uint8List> Function(), int)>[];
        for (final path in files) {
          final file = XFile(path);
          items.add((file.name, file.readAsBytes, await file.length()));
          if (!mounted) return;
        }
        await _addFiles(items);
        return;
      }
      final image = await Pasteboard.image;
      if (!mounted) return;
      if (image != null && image.isNotEmpty) {
        final stamp = DateTime.now();
        final name =
            'tempelan-${stamp.hour.toString().padLeft(2, '0')}${stamp.minute.toString().padLeft(2, '0')}${stamp.second.toString().padLeft(2, '0')}.png';
        await _addFiles([(name, () async => image, image.length)]);
      }
    } catch (_) {
      // The clipboard held nothing we can attach; the normal text paste already happened.
    }
  }

  @override
  void initState() {
    super.initState();
    agent.addListener(_follow);
  }

  @override
  void dispose() {
    agent.removeListener(_follow);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Keeps the newest message in view.
  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  /// Enter sends, Shift+Enter starts a new line, Ctrl+V also picks up a copied picture.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
      _pasteAttachments();
    }
    return KeyEventResult.ignored;
  }

  void _send([String? text]) {
    final message = (text ?? _input.text).trim();
    final attachments = text == null ? List<AiAttachment>.of(_pending) : const <AiAttachment>[];
    if ((message.isEmpty && attachments.isEmpty) || agent.busy || _loading) return;
    _input.clear();
    setState(() {
      if (text == null) _pending.clear();
      _attachError = null;
    });
    agent.send(message, attachments: attachments);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final app = widget.app;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = app.aiSettings != null),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _drop,
      child: Container(
        width: widget.width ?? app.aiPanelWidth,
        decoration: BoxDecoration(
          color: tokens.panel,
          border: Border(left: BorderSide(color: tokens.border)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ListenableBuilder(
                listenable: agent,
                builder: (context, _) => Column(
                  children: [
                    _header(tokens, app),
                    Divider(height: 1, color: tokens.border),
                    Expanded(
                      child: app.aiSettings == null
                          ? _setup(tokens, app)
                          : agent.entries.isEmpty
                          ? _empty(tokens)
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                              itemCount: agent.entries.length,
                              itemBuilder: (context, i) => _entry(tokens, agent.entries[i]),
                            ),
                    ),
                    if (agent.busy) _working(tokens),
                    _composer(tokens, app),
                  ],
                ),
              ),
            ),
            // Drag the left edge to make the panel wider or narrower.
            if (widget.width == null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 6,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const ValueKey('ai-panel-resize'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) => app.setAiPanelWidth(app.aiPanelWidth - details.delta.dx),
                  ),
                ),
              ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tokens.panel.withValues(alpha: 0.92),
                      border: Border.all(color: tokens.accent, width: 2),
                      borderRadius: BorderRadius.circular(Radii.control),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_download_outlined, size: 30, color: tokens.accent),
                        const SizedBox(height: 8),
                        Text('Lepas untuk melampirkan', style: uiText(14, tokens.text, weight: 600)),
                        const SizedBox(height: 4),
                        Text('Gambar, file teks, atau program .zm2/.bwlad', style: uiText(12, tokens.textMuted)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(Tokens tokens, AppState app) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
    child: Row(
      children: [
        Icon(Icons.forum_outlined, size: 18, color: tokens.text),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Asisten AI', style: uiText(14, tokens.text, weight: 700)),
              if (app.aiSettings != null) Text(app.aiSettings!.model, style: uiText(11.5, tokens.textMuted), overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('ai-new-chat'),
          tooltip: 'Percakapan baru',
          iconSize: 18,
          onPressed: agent.busy || agent.entries.isEmpty ? null : agent.reset,
          icon: const Icon(Icons.add_comment_outlined),
        ),
        IconButton(tooltip: 'Pengaturan AI', iconSize: 18, onPressed: () => showAiSettings(context, app), icon: const Icon(Icons.tune)),
        IconButton(tooltip: 'Tutup', iconSize: 18, onPressed: widget.onClose ?? app.toggleAiPanel, icon: const Icon(Icons.close)),
      ],
    ),
  );

  Widget _setup(Tokens tokens, AppState app) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.key_outlined, size: 32, color: tokens.textMuted),
        const SizedBox(height: 12),
        Text('Hubungkan AI dulu', style: uiText(15, tokens.text, weight: 600)),
        const SizedBox(height: 6),
        Text(
          'Pakai API key milikmu: Gemini, Claude, DeepSeek, OpenAI, atau endpoint lain yang kompatibel.',
          textAlign: TextAlign.center,
          style: uiText(12.5, tokens.textMuted, height: 1.45),
        ),
        const SizedBox(height: 16),
        FilledButton(key: const ValueKey('ai-panel-setup'), onPressed: () => showAiSettings(context, app), child: const Text('Atur AI')),
      ],
    ),
  );

  Widget _empty(Tokens tokens) => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const SizedBox(height: 12),
      Text(widget.agent == null ? 'Mau dirakitkan apa?' : 'Mau diprogramkan apa?', style: uiText(16, tokens.text, weight: 700)),
      const SizedBox(height: 6),
      Text(
        widget.intro ?? 'Asisten merakit langsung di kanvas, lalu mengujinya di simulator sampai jalan. Semua perubahan bisa diurungkan dengan Ctrl+Z.',
        style: uiText(12.5, tokens.textMuted, height: 1.45),
      ),
      const SizedBox(height: 8),
      Text(
        'Bisa juga melampirkan gambar rangkaian, panel, atau ladder untuk ditiru: klik ikon klip, seret file ke sini, atau tempel dengan Ctrl+V.',
        style: uiText(12.5, tokens.textMuted, height: 1.45),
      ),
      const SizedBox(height: 16),
      for (final suggestion in widget.suggestions ?? _suggestions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.control),
            onTap: () => _send(suggestion),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: tokens.border),
                borderRadius: BorderRadius.circular(Radii.control),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(suggestion, style: uiText(12.5, tokens.text))),
                  Icon(Icons.arrow_forward, size: 15, color: tokens.textMuted),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _entry(Tokens tokens, ChatEntry entry) {
    switch (entry.kind) {
      case ChatKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 40, bottom: 10, top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(Radii.control)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.attachments.isNotEmpty) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [for (final a in entry.attachments) _AttachmentChip(attachment: a, large: true)],
                  ),
                  const SizedBox(height: 8),
                ],
                SelectableText(entry.text, style: uiText(13, tokens.text, height: 1.4)),
              ],
            ),
          ),
        );
      case ChatKind.assistant:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10, top: 2),
          child: _RichText(text: entry.text),
        );
      case ChatKind.tool:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(entry.failed ? Icons.error_outline : Icons.check, size: 14, color: entry.failed ? tokens.warning : tokens.run),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(entry.text, style: uiText(12, tokens.textMuted, height: 1.35))),
            ],
          ),
        );
      case ChatKind.error:
      case ChatKind.info:
        final error = entry.kind == ChatKind.error;
        return Container(
          margin: const EdgeInsets.only(bottom: 10, top: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (error ? tokens.error : tokens.textMuted).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: SelectableText(entry.text, style: uiText(12.5, error ? tokens.error : tokens.textMuted, height: 1.4)),
        );
    }
  }

  Widget _working(Tokens tokens) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
    child: Row(
      children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.accent)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(agent.phase ?? 'Bekerja…', style: uiText(12, tokens.textMuted), overflow: TextOverflow.ellipsis),
        ),
        TextButton(key: const ValueKey('ai-stop'), onPressed: agent.stop, child: const Text('Hentikan')),
      ],
    ),
  );

  Widget _composer(Tokens tokens, AppState app) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: tokens.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pending.isNotEmpty || _loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < _pending.length; i++)
                  _AttachmentChip(key: ValueKey('ai-attachment-$i'), attachment: _pending[i], onRemove: () => setState(() => _pending.removeAt(i))),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: tokens.accent)),
                  ),
              ],
            ),
          ),
        if (_attachError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_attachError!, style: uiText(12, tokens.error, height: 1.35)),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              key: const ValueKey('ai-attach'),
              tooltip: 'Lampirkan gambar atau file (bisa juga seret ke sini atau Ctrl+V)',
              onPressed: app.aiSettings == null || agent.busy ? null : _pick,
              icon: Icon(Icons.attach_file, size: 19, color: tokens.textMuted),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: TextField(
                key: const ValueKey('ai-input'),
                controller: _input,
                focusNode: _focus,
                enabled: app.aiSettings != null,
                minLines: 1,
                maxLines: 6,
                style: uiText(13, tokens.text),
                decoration: InputDecoration(hintText: widget.hint ?? 'Minta dirakitkan, diperbaiki, atau dijelaskan…'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const ValueKey('ai-send'),
              tooltip: 'Kirim (Enter)',
              onPressed: app.aiSettings == null || agent.busy || _loading ? null : _send,
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
          ],
        ),
      ],
    ),
  );
}

/// A picture as a thumbnail, or a file as its name; with a remove button while it waits to be sent.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({super.key, required this.attachment, this.onRemove, this.large = false});

  final AiAttachment attachment;
  final VoidCallback? onRemove;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final size = large ? 120.0 : 56.0;
    final body = attachment.isImage
        ? ClipRRect(
            borderRadius: BorderRadius.circular(Radii.plate),
            child: Image.memory(attachment.image!, width: size, height: size, fit: BoxFit.cover, semanticLabel: attachment.name, gaplessPlayback: true),
          )
        : Container(
            height: large ? null : size,
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: tokens.panel,
              border: Border.all(color: tokens.border),
              borderRadius: BorderRadius.circular(Radii.plate),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_outlined, size: 16, color: tokens.textMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(attachment.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: uiText(12, tokens.text)),
                ),
              ],
            ),
          );
    // A picture opens full size on click, to check what the assistant was given.
    final labelled = Tooltip(
      message: attachment.name,
      child: attachment.isImage
          ? InkWell(
              mouseCursor: SystemMouseCursors.click,
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      InteractiveViewer(maxScale: 6, child: Image.memory(attachment.image!, semanticLabel: attachment.name)),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: IconButton.filled(tooltip: 'Tutup', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close, size: 18)),
                      ),
                    ],
                  ),
                ),
              ),
              child: body,
            )
          : body,
    );
    if (onRemove == null) return labelled;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: const EdgeInsets.only(top: 4, right: 4), child: labelled),
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: tokens.plate,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close, size: 13, color: tokens.onPlate, semanticLabel: 'Hapus ${attachment.name}'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Assistant text with light formatting: **bold**, bullet and numbered lines, and # headings.
class _RichText extends StatelessWidget {
  const _RichText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final base = uiText(13, tokens.text, height: 1.45);
    final bold = uiText(13, tokens.text, weight: 650, height: 1.45);
    List<TextSpan> spans(String line, TextStyle style) {
      final parts = line.split('**');
      return [for (var i = 0; i < parts.length; i++) TextSpan(text: parts[i].replaceAll('`', ''), style: i.isOdd ? bold : style)];
    }

    final rows = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        rows.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^#{1,4}\s+(.*)').firstMatch(line);
      final bullet = RegExp(r'^\s*[-*•]\s+(.*)').firstMatch(line);
      final numbered = RegExp(r'^\s*(\d+)[.)]\s+(.*)').firstMatch(line);
      if (heading != null) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text.rich(TextSpan(children: spans(heading.group(1)!, bold))),
          ),
        );
      } else if (bullet != null || numbered != null) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 18, child: Text(numbered != null ? '${numbered.group(1)}.' : '•', style: base)),
                Expanded(child: Text.rich(TextSpan(children: spans(numbered?.group(2) ?? bullet!.group(1)!, base)))),
              ],
            ),
          ),
        );
      } else {
        rows.add(Text.rich(TextSpan(children: spans(line, base))));
      }
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}
