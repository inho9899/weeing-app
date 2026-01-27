import 'package:flutter/material.dart';

class CycleControl extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final FixedExtentScrollController controller;

  const CycleControl({
    super.key,
    required this.value,
    required this.onChanged,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE6E6E9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cycle',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Center(
                child: _numberPicker(
                  max: 99,
                  selected: value,
                  controller: controller,
                  width: 70,
                  onChanged: onChanged,
                ),
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
