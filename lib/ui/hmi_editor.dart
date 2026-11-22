import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/project.dart';
import '../sim/plc.dart';
import 'theme.dart';

/// Addresses an HMI control can show or switch.
const List<String> _contactRefs = [...kPlcInputs, 'Z1', 'Z2', 'Z3', 'Z4', ...kPlcOutputs, ...kPlcMemory, ...kPlcTimers];

Future<void> showHmiEditor(BuildContext context, AppState app, PlacedDevice hmi) {
  return showDialog<void>(context: context, builder: (_) => _HmiEditor(app: app, hmi: hmi));
}

class _HmiEditor extends StatefulWidget {
  const _HmiEditor({required this.app, required this.hmi});

  final AppState app;
  final PlacedDevice hmi;

  @override
  State<_HmiEditor> createState() => _HmiEditorState();
}

class _HmiEditorState extends State<_HmiEditor> {
  late final List<Map<String, dynamic>> _items = [
    for (final item in widget.hmi.data['widgets'] as List<dynamic>? ?? const []) Map<String, dynamic>.of(item as Map<String, dynamic>),
  ];

  static const _types = {'push': 'Tombol tekan', 'toggle': 'Saklar', 'lamp': 'Lampu'};

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return AlertDialog(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
      title: Text('Layar ${widget.hmi.tag}', style: uiText(17, tokens.text, weight: 700)),
      content: SizedBox(
        width: 520,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Terhubung ke PLC pertama di proyek. Tombol biasanya memakai bit M, lampu boleh bit apa saja.', style: uiText(13, tokens.textMuted, height: 1.4)),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    Padding(
                      key: ObjectKey(_items[i]),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 130,
                            child: DropdownButtonFormField<String>(
                              initialValue: _items[i]['type'] as String,
                              style: uiText(13, tokens.text),
                              items: [for (final entry in _types.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
                              onChanged: (value) => setState(() => _items[i]['type'] = value),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              initialValue: _items[i]['label'] as String,
                              style: uiText(13, tokens.text),
                              decoration: const InputDecoration(hintText: 'Label'),
                              onChanged: (value) => _items[i]['label'] = value,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 90,
                            child: DropdownButtonFormField<String>(
                              initialValue: _items[i]['ref'] as String,
                              style: uiText(13, tokens.text),
                              menuMaxHeight: 280,
                              items: [for (final ref in _contactRefs) DropdownMenuItem(value: ref, child: Text(ref))],
                              onChanged: (value) => setState(() => _items[i]['ref'] = value),
                            ),
                          ),
                          IconButton(iconSize: 18, tooltip: 'Hapus', onPressed: () => setState(() => _items.removeAt(i)), icon: Icon(Icons.delete_outline, color: tokens.error)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _items.length >= 8 ? null : () => setState(() => _items.add({'type': 'push', 'label': 'TOMBOL', 'ref': 'M1'})),
                child: Text('Tambah elemen', style: uiText(13, tokens.text, weight: 500)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Batal')),
        FilledButton(
          onPressed: () {
            widget.app.setHmiWidgets(widget.hmi, _items);
            Navigator.of(context).pop();
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
