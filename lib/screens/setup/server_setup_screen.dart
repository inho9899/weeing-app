import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:weeing_app/gateway/gateway.dart';

/// 게이트웨이(weeing-proxy) 주소를 입력받는 화면.
///
/// 사용자마다 자기 proxy 를 자기 도메인에 띄워 쓰므로 주소가 설치마다 다르다.
/// 예전엔 이 값이 Gateway 의 const 였고, 그래서 사람마다 APK 를 새로 빌드해야
/// 했다. 이 화면이 그 자리를 대신한다.
///
/// 두 가지 경로로 열린다:
///   - 최초 설정 — main() 이 저장된 주소가 없을 때 띄운다. 뒤로 갈 화면이
///     없으므로 [onSaved] 콜백으로 완료를 알린다.
///   - 나중에 수정 — ConfigScreen 에서 push 한다. 저장하면 pop(true).
class ServerSetupScreen extends StatefulWidget {
  /// 수정 모드면 현재 주소, 최초 설정이면 null.
  final String? currentBase;

  /// 최초 설정에서 저장이 끝났을 때 호출된다 (수정 모드에서는 쓰지 않는다).
  final VoidCallback? onSaved;

  const ServerSetupScreen({super.key, this.currentBase, this.onSaved});

  bool get isInitialSetup => currentBase == null;

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentBase ?? '');

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 서버에서 받아온 값을 캐싱해둔 로컬 키들.
  ///
  /// 주소가 바뀌면 이 값들은 전부 "예전 서버의 상태"가 된다. 특히
  /// device_list_v2 의 deviceId 는 새 서버에 존재하지 않는 값이어서, 그대로
  /// 두면 이름 수정·삭제가 조용히 실패한다. 그래서 주소 변경 시 함께 비운다.
  ///
  /// 키의 주인은 config_screen.dart(device_list_v2 / build_mapping /
  /// build_scheduler)와 background_task.dart(구버전 device_list)다.
  static const List<String> _serverScopedKeys = [
    'device_list_v2',
    'device_list',
    'build_mapping',
    'build_scheduler',
  ];

  Future<void> _clearServerScopedCaches() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in _serverScopedKeys) {
      await prefs.remove(key);
    }
  }

  /// 주소를 바꾸면 등록해둔 기기 목록이 무효가 된다는 걸 알리고 동의를 받는다.
  Future<bool> _confirmSwitch(String from, String to) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('서버 주소를 바꾸시겠습니까?'),
        content: Text(
          '$from\n→ $to\n\n'
          '등록해둔 기기 목록과 빌드 매핑·스케줄은 이전 서버의 정보라 '
          '새 서버에서는 쓸 수 없습니다. 목록을 비우고 새로 등록해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('바꾸기'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save() async {
    final normalized = Gateway.normalizeBase(_controller.text);
    if (normalized == null) {
      setState(() {
        _error = '주소 형식을 확인해주세요. 예: api.example.com';
      });
      return;
    }

    // 바뀐 게 없으면 확인·저장 없이 그냥 닫는다.
    if (normalized == widget.currentBase) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    // 저장 전에 실제로 게이트웨이가 떠 있는지 확인한다 — 오타를 여기서 잡지
    // 않으면 이후 모든 화면이 "네트워크 실패"로만 보여서 원인을 찾기 어렵다.
    final reachable = await Gateway.probe(normalized);
    if (!mounted) return;
    if (!reachable) {
      setState(() {
        _saving = false;
        _error = '$normalized 에 연결할 수 없습니다.\n'
            '주소가 맞는지, 그리고 weeing-proxy 가 실행 중인지 확인해주세요.';
      });
      return;
    }

    if (!widget.isInitialSetup) {
      final ok = await _confirmSwitch(widget.currentBase!, normalized);
      if (!mounted) return;
      if (!ok) {
        setState(() => _saving = false);
        return;
      }
      await _clearServerScopedCaches();
    }

    await Gateway.saveBase(normalized);
    if (!mounted) return;

    if (widget.isInitialSetup) {
      widget.onSaved?.call();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isInitialSetup ? '서버 설정' : '서버 주소 변경'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1A1A1C),
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        // 최초 설정에서는 주소 없이 넘어갈 수 없으므로 뒤로가기를 숨긴다.
        automaticallyImplyLeading: !widget.isInitialSetup,
      ),
      backgroundColor: const Color(0xFFF3F3F5),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isInitialSetup) ...[
                const Text(
                  '게이트웨이 주소를 입력해주세요',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  '이 앱은 각자 운영하는 weeing-proxy 를 통해 PC 와 통신합니다. '
                  'proxy 를 띄울 때 설정한 도메인을 입력해주세요.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF5A5A5E)),
                ),
                const SizedBox(height: 24),
              ],
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade400),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _controller,
                  enabled: !_saving,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saving ? null : _save(),
                  decoration: const InputDecoration(
                    hintText: 'api.example.com',
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.dns_outlined, size: 20),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'https:// 는 생략해도 됩니다.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8A8A8E)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5A3A3)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF9B2C2C),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '연결 확인 후 저장',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
