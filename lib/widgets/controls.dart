import 'package:flutter/material.dart';

class LobbyControls extends StatelessWidget {
  final List<String> builds;
  final String currentMap;
  final ValueChanged<String?> onMapChanged;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Widget cycle;
  final Widget startTime;
  final TextEditingController commandController;
  final VoidCallback onSend;
  final VoidCallback onConvertMode;

  const LobbyControls({
    super.key,
    required this.builds,
    required this.currentMap,
    required this.onMapChanged,
    required this.onStart,
    required this.onPause,
    required this.cycle,
    required this.startTime,
    required this.commandController,
    required this.onSend,
    required this.onConvertMode,
  });

  @override
  Widget build(BuildContext context) {
    const darkGrey = Color(0xFF5A5A5A);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: darkGrey,
            borderRadius: BorderRadius.circular(6),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: currentMap.isNotEmpty ? currentMap : null,
              isExpanded: true,
              dropdownColor: Colors.grey[850],
              iconEnabledColor: Colors.white,
              style: const TextStyle(color: Colors.white),
              items: builds
                  .map(
                    (b) => DropdownMenuItem(
                      value: b,
                      child: Text(b),
                    ),
                  )
                  .toList(),
              onChanged: onMapChanged,
            ),
          ),
        ),
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
        const SizedBox(height: 20),
        TextField(
          controller: commandController,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: '메시지 입력...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _greyButton(
                label: 'Send',
                onTap: onSend,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _greyButton(
                label: '한/영 전환',
                onTap: onConvertMode,
              ),
            ),
          ],
        ),
      ],
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
