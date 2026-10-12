import 'package:flutter/material.dart';

class LobbyControls extends StatelessWidget {
  final List<String> builds;
  final String currentMap;
  final ValueChanged<String?> onMapChanged;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Widget cycle;
  final Widget startTime;

  /// builds의 값(선택/식별에 쓰는 값) → 실제로 보여줄 텍스트.
  /// 없는 항목은 값 그대로 표시한다 (예: "캐릭터명 - 빌드명" 라벨용).
  final Map<String, String>? itemLabels;

  /// currentMap이 비어있을 때(실행 중도 아니고 선택도 안 됐을 때) 보여줄 안내 문구.
  final String? hint;

  /// 드롭다운 옆 톱니 — 선택한 캐릭터의 준비·정리 단계 설정. null 이면 비활성
  /// (캐릭터를 안 골랐거나, 표시값이 캐릭터가 아니라 빌드명일 때).
  final VoidCallback? onOptionsTap;

  /// 끈 단계가 있을 때 드롭다운 아래에 보여줄 한 줄 (예: "꺼짐: 도핑"). 꺼둔 걸 잊고
  /// Start 를 누르지 않게 한다.
  final String? optionsSummary;

  const LobbyControls({
    super.key,
    required this.builds,
    required this.currentMap,
    required this.onMapChanged,
    required this.onStart,
    required this.onPause,
    required this.cycle,
    required this.startTime,
    this.itemLabels,
    this.hint,
    this.onOptionsTap,
    this.optionsSummary,
  });

  @override
  Widget build(BuildContext context) {
    const darkGrey = Color(0xFF5A5A5A);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _dropdown(darkGrey)),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: Material(
                color: onOptionsTap == null ? Colors.grey[400] : darkGrey,
                borderRadius: BorderRadius.circular(6),
                child: IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white),
                  tooltip: 'preprocess·postprocess',
                  onPressed: onOptionsTap,
                ),
              ),
            ),
          ],
        ),
        if (optionsSummary != null) ...[
          const SizedBox(height: 6),
          Text(
            optionsSummary!,
            style: const TextStyle(fontSize: 13, color: Colors.deepOrange),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _greyButton(label: 'Start', onTap: onStart),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _greyButton(label: 'Pause', onTap: onPause),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: cycle),
            const SizedBox(width: 8),
            Expanded(child: startTime),
          ],
        ),
      ],
    );
  }

  Widget _dropdown(Color darkGrey) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: darkGrey,
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentMap.isNotEmpty ? currentMap : null,
          hint: hint == null
              ? null
              : Text(
                  hint!,
                  style: TextStyle(color: Colors.grey[400]),
                  overflow: TextOverflow.ellipsis,
                ),
          isExpanded: true,
          dropdownColor: Colors.grey[850],
          iconEnabledColor: Colors.white,
          style: const TextStyle(color: Colors.white),
          items: builds
              .map(
                (b) => DropdownMenuItem(
                  value: b,
                  child: Text(
                    itemLabels?[b] ?? b,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: onMapChanged,
        ),
      ),
    );
  }

  Widget _greyButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF757575),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          padding: EdgeInsets.zero,
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
