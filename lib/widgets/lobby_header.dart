import 'package:flutter/material.dart';

class LobbyHeader extends StatelessWidget {
  final String hostText;
  final VoidCallback onInfoTap;

  const LobbyHeader({super.key, required this.hostText, required this.onInfoTap});

  @override
  Widget build(BuildContext context) {
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
        IconButton(
          onPressed: onInfoTap,
          icon: const Icon(Icons.info_outline),
        ),
      ],
    );
  }
}
