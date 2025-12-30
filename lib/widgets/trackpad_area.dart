import 'package:flutter/material.dart';

class TrackpadArea extends StatelessWidget {
  final GestureDetector Function(BuildContext) builder;
  const TrackpadArea({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 260,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: builder(context),
        ),
      ],
    );
  }
}
