import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xFF0A1114);
  static const surface = Color(0xFF111B1F);
  static const surfaceRaised = Color(0xFF172429);
  static const surfaceHighest = Color(0xFF1E2D32);
  static const outline = Color(0xFF2A3B40);
  static const ink = Color(0xFFE7EFEB);
  static const muted = Color(0xFF9AAEA7);
  static const accent = Color(0xFF9AE6C2);
  static const accentInk = Color(0xFF10231B);
  static const accentSoft = Color(0xFF203D31);
  static const warning = Color(0xFFFFC978);
  static const danger = Color(0xFFFF9388);
}

const appRadius = BorderRadius.all(Radius.circular(20));
const smallRadius = BorderRadius.all(Radius.circular(14));

String folderName(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String relativeAge(int millisecondsSinceEpoch) {
  if (millisecondsSinceEpoch <= 0) {
    return 'Sem atividade recente';
  }

  final elapsed = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch),
  );
  if (elapsed.inMinutes < 1) {
    return 'Agora';
  }
  if (elapsed.inHours < 1) {
    return 'Há ${elapsed.inMinutes} min';
  }
  if (elapsed.inDays < 1) {
    return 'Há ${elapsed.inHours} h';
  }
  if (elapsed.inDays < 7) {
    return 'Há ${elapsed.inDays} d';
  }

  final date = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
}

Widget eyebrow(String text, {Color color = AppColors.muted}) {
  return Text(
    text.toUpperCase(),
    style: TextStyle(
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    ),
  );
}

class StatusPill extends StatelessWidget {
  final String label;
  final bool active;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    this.active = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.muted;
    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.accentSoft : AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: active
                ? AppColors.accent.withValues(alpha: .24)
                : AppColors.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: active ? AppColors.accent : AppColors.ink,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
