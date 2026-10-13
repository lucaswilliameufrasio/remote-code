import 'package:flutter/material.dart';
import 'design.dart';

void notice(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(error.toString())));
}

Future<String?> askText(BuildContext context, String title,
    {String hint = '', String value = ''}) async {
  final controller = TextEditingController(text: value);
  final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
              title: Text(title),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(hintText: hint),
                  onSubmitted: (s) {
                    if (s.trim().isNotEmpty) Navigator.pop(c, s.trim());
                  }),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () {
                      if (controller.text.trim().isNotEmpty) {
                        Navigator.pop(c, controller.text.trim());
                      }
                    },
                    child: const Text('Confirmar'))
              ]));
  // Dispose after the dialog route has finished its closing animation.
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}

class InfoBox extends StatelessWidget {
  final String text;
  final IconData icon;
  const InfoBox(this.text, {super.key, this.icon = Icons.info_outline});

  @override
  Widget build(BuildContext context) {
    final isError = icon == Icons.error_outline || icon == Icons.cloud_off;
    final color = isError ? AppColors.danger : AppColors.accent;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: smallRadius,
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
