import 'package:flutter/material.dart';

class StartTimeControl extends StatelessWidget {
  final int hour;
  final int minute;
  final ValueChanged<int> onHourChanged;
  final ValueChanged<int> onMinuteChanged;
  final FixedExtentScrollController hourController;
  final FixedExtentScrollController minuteController;

  const StartTimeControl({
    super.key,
    required this.hour,
    required this.minute,
    required this.onHourChanged,
    required this.onMinuteChanged,
    required this.hourController,
    required this.minuteController,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE6E6E9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('시', style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 4),
                      _numberPicker(
                        max: 23,
                        selected: hour,
                        controller: hourController,
                        width: 60,
                        onChanged: onHourChanged,
                      ),
                    ],
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('분', style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 4),
                      _numberPicker(
                        max: 59,
                        selected: minute,
                        controller: minuteController,
                        width: 60,
                        onChanged: onMinuteChanged,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberPicker({
    required int max,
    required int selected,
    required ValueChanged<int> onChanged,
    required FixedExtentScrollController controller,
    double width = 60,
  }) {
    final safeSelected = selected.clamp(0, max);
    return SizedBox(
      width: width,
      height: 110,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 32,
            width: width - 8,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.9),
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
          ListWheelScrollView.useDelegate(
            controller: controller,
            physics: const FixedExtentScrollPhysics(),
            perspective: 0.003,
            itemExtent: 32,
            onSelectedItemChanged: (index) {
              if (index < 0 || index > max) return;
              onChanged(index);
            },
            childDelegate: ListWheelChildBuilderDelegate(
              builder: (context, index) {
                if (index < 0 || index > max) return null;
                final bool isSelected = index == safeSelected;
                return Center(
                  child: Text(
                    index.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: isSelected ? 18 : 16,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? Colors.black : Colors.black45,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
