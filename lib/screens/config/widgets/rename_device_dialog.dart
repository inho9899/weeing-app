import 'package:flutter/material.dart';

class RenameDeviceDialog extends StatefulWidget {
  final String currentName;

  const RenameDeviceDialog({super.key, required this.currentName});

  @override
  State<RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<RenameDeviceDialog> {
  late final _controller = TextEditingController(text: widget.currentName);
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('명칭 수정'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: '명칭',
          errorText: _errorText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) {
              setState(() => _errorText = '명칭을 입력하세요.');
              return;
            }
            Navigator.of(context).pop(name);
          },
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// RenameDeviceDialog를 표시하고 새 이름을 반환 (취소 시 null)
Future<String?> showRenameDeviceDialog(BuildContext context, String currentName) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RenameDeviceDialog(currentName: currentName),
  );
}
