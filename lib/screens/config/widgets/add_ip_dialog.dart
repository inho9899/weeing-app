import 'package:flutter/material.dart';

/// IP 추가 다이얼로그의 결과: (IP 주소, 이 기기를 부를 명칭)
typedef AddDeviceResult = ({String ip, String name});

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
  final _ipController = TextEditingController();
  final _nameController = TextEditingController();
  String? _ipErrorText;
  String? _nameErrorText;

  @override
  void dispose() {
    _ipController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('PC 추가'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ipController,
            decoration: InputDecoration(
              labelText: 'IP 주소',
              hintText: '예: 192.168.0.1',
              errorText: _ipErrorText,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: '명칭',
              hintText: '예: 거실 PC',
              errorText: _nameErrorText,
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
            final ip = _ipController.text.trim();
            final name = _nameController.text.trim();

            setState(() {
              _ipErrorText = widget.ipRegex.hasMatch(ip)
                  ? null
                  : '올바른 IP 형식(xxx.xxx.xxx.xxx)으로 다시 입력하세요.';
              _nameErrorText = name.isEmpty ? '명칭을 입력하세요.' : null;
            });
            if (_ipErrorText != null || _nameErrorText != null) return;

            Navigator.of(context).pop((ip: ip, name: name));
          },
          child: const Text('확인'),
        ),
      ],
    );
  }
}

/// AddIpDialog를 표시하고 결과 {ip, name}을 반환
Future<AddDeviceResult?> showAddIpDialog(BuildContext context, RegExp ipRegex) {
  return showDialog<AddDeviceResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AddIpDialog(ipRegex: ipRegex),
  );
}
