import 'package:flutter/material.dart';

import '../app_state.dart';
import '../templates.dart';
import 'theme.dart';

Future<void> showTemplatesDialog(BuildContext context, AppState app) {
  final tokens = context.tokens;
  Widget option({required Key key, required String title, required String text, required VoidCallback onTap}) => InkWell(
        key: key,
        borderRadius: BorderRadius.circular(Radii.control),
        hoverColor: tokens.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: uiText(14, tokens.text, weight: 600)),
              const SizedBox(height: 3),
              Text(text, style: uiText(13, tokens.textMuted)),
            ],
          ),
        ),
      );

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
      title: Text('Mulai proyek', style: uiText(17, tokens.text, weight: 700)),
      contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              option(
                key: const ValueKey('template-empty'),
                title: 'Kanvas kosong',
                text: 'Mulai dari nol.',
                onTap: () {
                  Navigator.of(dialogContext).pop();
                  app.newProject();
                },
              ),
              for (final template in kTemplates)
                option(
                  key: ValueKey('template-${template.id}'),
                  title: template.name,
                  text: template.description,
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    app.applyTemplate(template);
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Batal'))],
    ),
  );
}
