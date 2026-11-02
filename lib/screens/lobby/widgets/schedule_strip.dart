import 'package:flutter/material.dart';

import 'package:weeing_app/screens/schedule/models/schedule_plan.dart';

/// 로비의 Start/Pause 바로 아래 한 줄. 스케줄이 켜져 있으면 지금 단계와 다음 블록을, 꺼져 있으면
/// "탭해서 설정" 을 보여준다. Start 옆에 두는 이유: 스케줄이 켜져 있으면 Start 를 누를 필요가 없다는 걸
/// 바로 알게 하려고. 누르면 스케줄 화면으로 간다.
class ScheduleStrip extends StatelessWidget {
  /// null 이면 아직 못 읽은 것 (프록시 응답 전).
  final ScheduleStatus? status;
  final VoidCallback onTap;

  const ScheduleStrip({super.key, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = status?.enabled == true;
    final bg = on ? const Color(0xFF1F1F1F) : const Color(0xFFE6E6E9);
    final fg = on ? Colors.white : const Color(0xFF1F1F1F);
    final sub = on ? const Color(0xFFCFCFD4) : const Color(0xFF5A5A5A);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.calendar_month_outlined, size: 20, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status?.headline ?? '스케줄 확인 중',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      status?.detail ?? '프록시에 묻는 중',
                      style: TextStyle(fontSize: 12, color: sub),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: sub),
            ],
          ),
        ),
      ),
    );
  }
}
