import 'package:flutter/material.dart';

class LobbyHeader extends StatelessWidget {
  final String hostText;
  final VoidCallback onInfoTap;

  /// 대상 PC 의 입력 제어 상태. 아직 조회 전이거나 조회에 실패했으면 null —
  /// 이 경우 스위치를 비활성으로 흐리게 두어 "꺼짐"으로 오해하지 않게 한다.
  final bool? inputEnabled;

  /// 스위치 토글. null 이면 스위치를 비활성으로 그린다.
  final ValueChanged<bool>? onInputToggle;

  const LobbyHeader({
    super.key,
    required this.hostText,
    required this.onInfoTap,
    this.inputEnabled,
    this.onInputToggle,
  });

  @override
  Widget build(BuildContext context) {
    final known = inputEnabled != null;
    final on = inputEnabled ?? false;

    return Row(
      children: [
        Text(
          hostText,
          style: const TextStyle(
            color: Colors.red,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        // 입력 제어 on/off. off 는 대상 PC 의 키보드·마우스를 전부 막는
        // 차단 스위치라, 지금 어느 쪽인지 한눈에 보이도록 라벨을 같이 둔다.
        Text(
          !known
              ? '입력 ?'
              : on
                  ? '입력 ON'
                  : '입력 OFF',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: !known
                ? Colors.grey
                : on
                    ? Colors.green
                    : Colors.grey,
          ),
        ),
        Switch(
          value: on,
          onChanged: known ? onInputToggle : null,
          activeColor: Colors.green,
        ),
        IconButton(
          onPressed: onInfoTap,
          icon: const Icon(Icons.info_outline),
        ),
      ],
    );
  }
}
