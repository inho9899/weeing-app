import 'package:flutter/material.dart';

class AddIpDialog extends StatefulWidget {
  final RegExp ipRegex;

  const AddIpDialog({
    super.key,
    required this.ipRegex,
  });

  @override
  State<AddIpDialog> createState() => _AddIpDialogState();
}

class _AddIpDialogState extends State<AddIpDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('IP 주소 추가'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'IP 주소',
              hintText: '예: 192.168.0.1 또는 192.168.0.1:8000',
              errorText: _errorText,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: () {
            final text = _controller.text.trim();

            if (!widget.ipRegex.hasMatch(text)) {
              setState(() {
                _errorText = '올바른 IP 형식(xxx.xxx.xxx.xxx)으로 다시 입력하세요.';
              });
              return;
            }

            Navigator.of(context).pop(text);
          },
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// AddIpDialog를 표시하고 결과 IP를 반환
Future<String?> showAddIpDialog(BuildContext context, RegExp ipRegex) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AddIpDialog(ipRegex: ipRegex),
  );
}
