import 'package:flutter/material.dart';
import 'package:weeing_app/screens/lobby/pc_tabs_screen.dart';

class DeviceRow extends StatefulWidget {
  final String ip;
  final String name;
  final String? deviceId;
  final Color color;
  final bool enabled;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const DeviceRow({
    super.key,
    required this.ip,
    required this.name,
    required this.deviceId,
    required this.color,
    required this.enabled,
    this.onRename,
    this.onDelete,
  });

  @override
  State<DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<DeviceRow> {
  // 연속 탭(더블탭 등)으로 같은 PC의 PcTabsScreen이 두 개 이상 쌓여 각자
  // WebRTC 연결/폴링 타이머를 따로 돌리는 걸 막는 가드. 눌러서 push한 화면이
  // pop되어 돌아올 때 풀어준다.
  bool _navigating = false;

  void _handleTap() {
    if (_navigating) return;
    setState(() => _navigating = true);
    debugPrint('[DeviceRow] Navigate to PcTabsScreen with ip: ${widget.ip}');
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                PcTabsScreen(ip: widget.ip, deviceId: widget.deviceId),
          ),
        )
        .then((_) {
      if (mounted) setState(() => _navigating = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final nameStyle = TextStyle(
      fontSize: 16,
      color: enabled ? widget.color : Colors.grey,
      fontWeight: enabled ? FontWeight.w500 : FontWeight.w400,
    );
    final ipStyle = TextStyle(
      fontSize: 12,
      color: enabled ? Colors.black54 : Colors.grey,
    );

    return InkWell(
      onTap: (enabled && !_navigating) ? _handleTap : null,
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
                  Text(widget.name, style: nameStyle),
                  if (widget.name != widget.ip) Text(widget.ip, style: ipStyle),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '이름 수정',
              onPressed: widget.onRename,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
