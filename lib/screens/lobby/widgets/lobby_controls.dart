import 'package:flutter/material.dart';

class LobbyControls extends StatelessWidget {
  final List<String> builds;
  final String currentMap;
  final ValueChanged<String?> onMapChanged;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Widget cycle;
  final Widget startTime;
  final bool holdStartTime;
  final ValueChanged<bool> onHoldToggle;

  const LobbyControls({
    super.key,
    required this.builds,
    required this.currentMap,
    required this.onMapChanged,
    required this.onStart,
    required this.onPause,
    required this.cycle,
    required this.startTime,
    required this.holdStartTime,
    required this.onHoldToggle,
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
            Expanded(
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () => onHoldToggle(!holdStartTime),
                    child: Container(
                      height: 32,
                      decoration: BoxDecoration(
                        color: holdStartTime ? Colors.orange : Colors.grey[400],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            holdStartTime ? Icons.lock_outline : Icons.lock_open,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            holdStartTime ? 'HOLD ON' : 'HOLD OFF',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  startTime,
                ],
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
