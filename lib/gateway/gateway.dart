import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 캡차 도움(typeliecheck) 진행 상태.
/// none: 대기 중인 캡차 없음. pending: 답 입력 대기.
///
/// 예전엔 processing/resolved/failed 도 있었는데, 답을 서버에 올려두고 PC가
/// 폴링해 가져가는 경로가 사라지면서 서버가 그 상태를 만들 수 없게 됐다 —
/// 앱이 답을 대상 PC 로 직행시킨다(CaptchaHelpScreen `_submit()` 참고).
enum CaptchaState { none, pending }

CaptchaState _parseCaptchaState(String? raw) =>
    raw == 'pending' ? CaptchaState.pending : CaptchaState.none;

/// 캡차 상태 + 이 캡차가 발생한 시각.
/// occurredAt 은 PC 가 GIF 를 올린 시각이므로(서버 first_ts, weeing-proxy
/// route/captcha/db.py upsert_request 참고), "발생 후 얼마나 지났는지"
/// 판단 기준으로 쓸 수 있다 — PcTabsScreen의 빨간불/검은불 배지가 이걸 사용한다.
class CaptchaStatus {
  final CaptchaState state;
  final DateTime? occurredAt;

  const CaptchaStatus(this.state, this.occurredAt);
}

/// WEEING 앱의 단일 API 관문.
///
/// 앱의 모든 원격 호출은 반드시 이 Gateway 를 거쳐 cloudflare 게이트웨이의
/// /msa/proxy 로 전달된다. cloudflare 는 {ip, api} 를 받아 대상 머신(ip)의 해당
/// MSA 서비스로 요청을 프록시한다.
///
///   app → {게이트웨이}/msa/proxy  `{ ip, api: "{service}/{path}" }`
///       → `http://{ip}:{servicePort}/{path}`
///
/// 게이트웨이 주소는 사용자마다 다르다 — 각자 자기 weeing-proxy 를 자기 도메인에
/// 띄워 쓰기 때문이다. 그래서 코드에 박지 않고 첫 실행 때 입력받아
/// SharedPreferences 에 저장하고, 여기서 읽어 쓴다([ensureLoaded] 참고).
///
/// SoT 는 msaInstaller 의 gateway.py 다. api 의 첫 세그먼트(서비스명)는
/// cloudflare .env 의 `{service}_API_PORT` 로 포트가 해석된다.
///   예) "statusChecker/status/get", "mainAction/weeing/pause", "inputHandler/mouse/move"
class Gateway {
  /// 모든 게이트웨이 호출이 공유하는 HTTP 클라이언트.
  ///
  /// `package:http` 의 최상위 `get()`/`post()` 헬퍼는 호출마다 `Client()` 를
  /// 새로 만들고 닫는다. 즉 요청 하나가 매번 새 TCP 연결 + 새 TLS 핸드셰이크를
  /// 치른다 — 이 프록시 기준 실측으로 TCP 50.6ms + TLS 43.9ms 다. 마우스 입력
  /// 처럼 초당 수십 건이 나가는 경로에서는 이게 지연의 대부분을 차지했다.
  /// 클라이언트를 하나 붙들고 있으면 연결이 유지돼 요청당 왕복 1회로 줄어든다.
  static final http.Client _client = http.Client();
  Gateway._();

  /// 게이트웨이 주소를 저장하는 SharedPreferences 키.
  static const String _prefsKey = 'cloudflare_api_url';

  /// 메모리에 올려둔 게이트웨이 주소. [ensureLoaded] 가 채운다.
  static String? _base;

  /// 저장된 주소를 메모리로 올린다 (멱등).
  ///
  /// **isolate 마다 따로 불러야 한다.** FCM 백그라운드 핸들러나 workmanager 는
  /// main() 을 거치지 않는 별도 isolate 에서 돌기 때문에, main() 에서 한 번
  /// 불러둔 [_base] 를 그쪽에서는 볼 수 없다 (isolate 는 상태를 공유하지 않는다).
  /// 그래서 초기화를 부팅 시점 한 번으로 끝내지 않고, 네트워크를 쓰는 진입점마다
  /// 이걸 부르는 방식으로 둔다.
  static Future<String?> ensureLoaded() async {
    if (_base != null) return _base;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey)?.trim();
    if (saved != null && saved.isNotEmpty) _base = saved;
    return _base;
  }

  /// 주소가 설정돼 있는지 — main() 의 부팅 분기가 설정 화면을 띄울지 정하는 기준.
  static bool get isConfigured => _base != null;

  /// 현재 게이트웨이 주소.
  ///
  /// [ensureLoaded] 없이 부르면 던진다. 예전 기본값 같은 걸로 조용히 폴백하면
  /// 남의 서버로 요청이 나가거나 원인 모를 실패가 되므로, 차라리 여기서 터뜨린다.
  /// [captchaGifUrl]·[signalingUri] 가 동기 함수라서 이 getter 도 동기로 남겨뒀다.
  static String get cloudflareBase {
    final base = _base;
    if (base == null) {
      throw StateError(
        'Gateway 주소가 설정되지 않았습니다 (ensureLoaded 를 먼저 호출해야 합니다).',
      );
    }
    return base;
  }

  /// 사용자가 입력한 주소를 저장 가능한 형태로 다듬는다.
  ///
  /// 스킴이 없으면 https 를 붙이고 끝 슬래시를 떼며, host 가 없거나 http(s) 가
  /// 아니면 null 을 반환한다(= 입력 오류).
  static String? normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }

    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return s;
  }

  /// 이 주소에 실제로 게이트웨이가 떠 있는지 확인한다 (저장 전 검증용).
  ///
  /// /msa/services 를 쓰는 이유: GET 이고 무인증이고 대상 PC 로 라우팅되지 않는
  /// 가벼운 조회라, 프록시 자체가 살아있는지만 보는 데 딱 맞다.
  static Future<bool> probe(String base) async {
    try {
      final res = await _client
          .get(Uri.parse('$base/msa/services'))
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 주소를 저장하고 메모리 캐시까지 갱신한다.
  /// [normalizeBase] 를 통과한 값을 넘겨야 한다.
  static Future<void> saveBase(String normalized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, normalized);
    _base = normalized;
  }

  static String get _proxyUrl => '$cloudflareBase/msa/proxy';

  /// 대상 머신(ip)의 MSA 서비스로 요청을 프록시한다.
  ///
  /// [api]   : "{서비스명}/{경로}" (예: "statusChecker/status/get").
  /// [method]: 대상 엔드포인트 HTTP 메서드 (기본 POST).
  /// [params]: 추가 쿼리 파라미터 (선택).
  /// [body]  : JSON 바디 (선택).
  ///
  /// 반환되는 [http.Response] 의 statusCode·body 는 대상 서버의 응답을
  /// 그대로 통과시킨 값이다(투명 프록시). 따라서 호출부는 직접 호출과 동일하게 처리하면 된다.
  static Future<http.Response> call(
    String ip,
    String api, {
    String method = 'POST',
    Map<String, dynamic>? params,
    Object? body,
    int? timeout,
  }) {
    final cleanApi = api.startsWith('/') ? api.substring(1) : api;

    final payload = <String, dynamic>{
      'ip': _hostOnly(ip),
      'api': cleanApi,
      'method': method,
    };
    if (params != null && params.isNotEmpty) payload['params'] = params;
    if (body != null) payload['body'] = body;
    if (timeout != null) payload['timeout'] = timeout;

    return _client.post(
      Uri.parse(_proxyUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
  }

  /// 빌드 스케줄러 상태(스케줄/계정→빌드 매핑)를 조회/저장한다.
  ///
  /// [call]과 달리 기기로 라우팅되지 않고, 이 프록시 프로세스 자신이 상주 실행하는
  /// 스케줄러(cloudfare/scheduler.py)의 엔드포인트를 직접 호출한다. 앱이 꺼져 있어도
  /// 프록시가 예약된 로그인/로그아웃/빌드실행을 실행하므로, 저장은 반드시 여기로도
  /// 반영되어야 한다.
  ///
  /// 서버(원본)는 날짜별로 `{deviceIp: [request, ...]}` 형태로 저장한다(요청마다
  /// deviceIp 를 반복하지 않음). 앱 내부 모델은 계속 평평한 리스트(블록마다
  /// deviceIp 포함)를 쓰므로, 이 두 메서드에서만 서로 변환한다.
  ///
  /// 네트워크 실패 시 `fetch*`는 null(로컬 캐시로 폴백하라는 신호)을,
  /// `save*`는 false 를 반환한다.
  static Future<Map<String, List<Map<String, dynamic>>>?> fetchSchedules() async {
    try {
      final res = await _client.get(Uri.parse('$cloudflareBase/scheduler/schedules'));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final raw = body is Map ? body['resp'] : null;
      if (raw is! Map) return {};

      final result = <String, List<Map<String, dynamic>>>{};
      for (final dateEntry in raw.entries) {
        final byDevice = dateEntry.value;
        if (byDevice is! Map) continue;

        final blocks = <Map<String, dynamic>>[];
        for (final deviceEntry in byDevice.entries) {
          final deviceIp = deviceEntry.key.toString();
          final requests = deviceEntry.value;
          if (requests is! List) continue;
          for (final req in requests) {
            if (req is! Map) continue;
            blocks.add({'deviceIp': deviceIp, ...Map<String, dynamic>.from(req)});
          }
        }
        result[dateEntry.key.toString()] = blocks;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> saveSchedules(
    Map<String, List<Map<String, dynamic>>> schedules,
  ) async {
    try {
      final wireSchedules = <String, Map<String, List<Map<String, dynamic>>>>{};
      for (final dateEntry in schedules.entries) {
        final byDevice = <String, List<Map<String, dynamic>>>{};
        for (final block in dateEntry.value) {
          final deviceIp = block['deviceIp']?.toString() ?? '';
          if (deviceIp.isEmpty) continue;
          final request = Map<String, dynamic>.from(block)..remove('deviceIp');
          byDevice.putIfAbsent(deviceIp, () => []).add(request);
        }
        wireSchedules[dateEntry.key] = byDevice;
      }

      final res = await _client.post(
        Uri.parse('$cloudflareBase/scheduler/schedules'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'schedules': wireSchedules}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, String>?> fetchBuildMapping() async {
    try {
      final res = await _client
          .get(Uri.parse('$cloudflareBase/scheduler/build_mapping'))
          .timeout(const Duration(seconds: 5)); // 프록시 죽어있을 때 무한 대기 방지
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final raw = body is Map ? body['resp'] : null;
      if (raw is! Map) return {};
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> saveBuildMapping(Map<String, String> mapping) async {
    try {
      final res = await _client.post(
        Uri.parse('$cloudflareBase/scheduler/build_mapping'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'mappings': mapping}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// PC 추가 핸드셰이크: app → cloudflare → pc 흐름의 진입점.
  ///
  /// app 은 (ip, 명칭)만 보낸다. cloudflare 가 그 ip 의 PC(alarmHandler)에
  /// 직접 접속해서 별칭을 저장시키고 고유 device_id 를 받아온 뒤, 이 모바일
  /// 기기(fcmToken) 기준 device_id→명칭 매핑까지 등록한다 — 앱은 한 번의
  /// 호출로 끝난다. PC의 IP는 DHCP로 바뀔 수 있어 매핑 키로 쓰지 않는다.
  ///
  /// 성공하면 이후 이름 수정/삭제에 쓸 device_id 를 반환한다(앱이 로컬에
  /// 캐싱해둬야 PC 재접속 없이 그 작업들을 할 수 있다). 실패(네트워크/프록시
  /// 오류, PC 꺼짐 등) 시 null.
  static Future<String?> registerDeviceName(
    String ip,
    String name,
    String fcmToken,
  ) async {
    try {
      final res = await _client
          .post(
            Uri.parse('$cloudflareBase/message/devices'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': fcmToken,
              'ip': _hostOnly(ip),
              'name': name,
            }),
          )
          .timeout(const Duration(seconds: 10)); // PC 왕복까지 포함하는 호출이라 여유를 둠
      if (res.statusCode != 200) return null;
      final resp = unwrap(res);
      return resp is String && resp.isNotEmpty ? resp : null;
    } catch (_) {
      return null;
    }
  }

  /// 캐싱해둔 device_id로 명칭만 바로 수정한다 — PC 재접속 불필요, PC가 꺼져 있어도 된다.
  static Future<bool> renameDeviceName(
    String deviceId,
    String name,
    String fcmToken,
  ) async {
    try {
      final res = await _client.post(
        Uri.parse('$cloudflareBase/message/devices/rename'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': fcmToken,
          'device_id': deviceId,
          'name': name,
        }),
      );
      return res.statusCode == 200 && unwrap(res) == 0;
    } catch (_) {
      return false;
    }
  }

  /// 캐싱해둔 device_id로 명칭 매핑을 제거한다 (앱에서 PC 삭제 시).
  static Future<bool> removeDeviceName(
    String deviceId,
    String fcmToken,
  ) async {
    try {
      final res = await _client.post(
        Uri.parse('$cloudflareBase/message/devices/remove'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': fcmToken, 'device_id': deviceId}),
      );
      return res.statusCode == 200 && unwrap(res) == 0;
    } catch (_) {
      return false;
    }
  }

  /// 이 device의 캡차 도움(typeliecheck) 진행 상태를 조회한다.
  /// PC가 자동으로 못 푸는 왜곡 캡차를 GIF로 올려두면 사람이 보고 답해야 한다.
  /// 서버는 시간이 아무리 지나도 마지막 상태를 그대로 내려준다(오래됐다고
  /// none으로 감추지 않음) — "얼마나 지났는지"는 occurredAt으로 앱이 직접
  /// 판단해 배지 색으로만 표현한다. 네트워크 실패 시에는 none으로 폴백한다.
  static Future<CaptchaStatus> fetchCaptchaState(String deviceId) async {
    const none = CaptchaStatus(CaptchaState.none, null);
    try {
      final res = await _client.get(
        Uri.parse('$cloudflareBase/captcha/pending/$deviceId'),
      );
      if (res.statusCode != 200) return none;
      final resp = unwrap(res);
      if (resp is! Map) return none;
      final state = _parseCaptchaState(resp['state'] as String?);
      final firstTs = (resp['first_ts'] as num?)?.toDouble();
      final occurredAt = firstTs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((firstTs * 1000).round());
      return CaptchaStatus(state, occurredAt);
    } catch (_) {
      return none;
    }
  }

  /// 캡차 GIF를 바로 표시할 수 있는 URL (Image.network에 그대로 사용).
  static String captchaGifUrl(String deviceId) =>
      '$cloudflareBase/captcha/gif/$deviceId';

  /// 통일 응답 봉투 `{ resp, message }` 에서 `resp` 를 추출한다.
  ///
  /// 성공/실패는 HTTP 상태코드로 판단한다: 200 이 아니면 실패로 보고 null 을 반환.
  /// 200 이면 본문을 파싱해 `resp` 필드를 돌려준다(봉투가 아니면 본문 자체).
  static dynamic unwrap(http.Response res) {
    if (res.statusCode != 200) return null;
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body.containsKey('resp')) return body['resp'];
      return body;
    } catch (_) {
      return null;
    }
  }

  /// 통일 봉투에서 `message` 를 추출(없으면 null).
  static String? message(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['message'] != null) {
        return body['message'].toString();
      }
    } catch (_) {}
    return null;
  }

  /// 스트리밍/WebRTC 시그널링 WebSocket URL.
  /// cloudflare 터널이 WebSocket 을 지원하므로 도메인을 통해 대상 ip 의 스트리밍으로 브리지된다.
  ///   `wss://api.nongameanbun.xyz/streaming/ws?ip={ip}`
  static Uri signalingUri(String ip) {
    final wsBase = cloudflareBase.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
    return Uri.parse('$wsBase/streaming/ws').replace(queryParameters: {'ip': _hostOnly(ip)});
  }

  /// "http://1.2.3.4:8000/" 같은 값이 들어와도 순수 host 만 추출한다.
  ///
  /// cloudflare 는 서비스명(interface / 스트리밍)으로 포트를 결정하므로,
  /// 앱이 저장한 ip 의 포트는 라우팅에서 제거한다(머신 식별용 host 만 사용).
  static String _hostOnly(String ip) {
    var s = ip.trim();
    if (s.contains('://')) {
      final uri = Uri.tryParse(s);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
    }
    // 끝의 슬래시 제거
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    // 포트 제거 (IPv4 전용)
    final colon = s.indexOf(':');
    if (colon != -1) s = s.substring(0, colon);
    return s;
  }
}
