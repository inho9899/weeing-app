import 'package:flutter/material.dart';
import 'package:weeing_app/screens/lobby/lobby_screen.dart';

class DeviceRow extends StatelessWidget {
  final String ip;
  final String name;
  final Color color;
  final bool enabled;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const DeviceRow({
    super.key,
    required this.ip,
    required this.name,
    required this.color,
    required this.enabled,
    this.onRename,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final nameStyle = TextStyle(
      fontSize: 16,
      color: enabled ? color : Colors.grey,
      fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
    );
    final ipStyle = TextStyle(
      fontSize: 12,
      color: enabled ? Colors.black54 : Colors.grey,
    );

    return InkWell(
      onTap: enabled
          ? () {
              debugPrint('[DeviceRow] Navigate to LobbyScreen with ip: $ip');
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LobbyScreen(ip: ip),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, style: nameStyle),
                  if (name != ip) Text(ip, style: ipStyle),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '이름 수정',
              onPressed: onRename,
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
