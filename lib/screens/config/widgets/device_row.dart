import 'package:flutter/material.dart';
import 'package:weeing_app/screens/lobby/lobby_screen.dart';

class DeviceRow extends StatelessWidget {
  final String ip;
  final Color color;
  final bool enabled;
  final VoidCallback? onDelete;

  const DeviceRow({
    super.key,
    required this.ip,
    required this.color,
    required this.enabled,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 16,
      color: enabled ? color : Colors.grey,
      fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
    );

    return InkWell(
      onTap: enabled
          ? () {
              final basePath = 'http://$ip/';
              debugPrint('[DeviceRow] Navigate to LobbyScreen with basePath: $basePath');
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LobbyScreen(basePath: basePath),
                ),
              );
            }
          : null,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              Icons.desktop_windows,
              size: 24,
              color: enabled ? Colors.black87 : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(ip, style: textStyle),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
