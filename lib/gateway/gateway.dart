import 'dart:convert';
import 'package:http/http.dart' as http;

/// WEEING 앱의 단일 API 관문.
///
/// 앱의 모든 원격 호출은 반드시 이 Gateway 를 거쳐 cloudflare 게이트웨이
/// (api.nongameanbun.xyz) 의 /proxy 로 전달된다. cloudflare 는 {ip, api} 를 받아
/// 대상 머신(ip)의 해당 MSA 서비스로 요청을 프록시한다.
///
///   app → https://api.nongameanbun.xyz/proxy  `{ ip, api: "{service}/{path}" }`
///       → `http://{ip}:{servicePort}/{path}`
///
/// SoT 는 msaInstaller 의 gateway.py 다. api 의 첫 세그먼트(서비스명)는
/// cloudflare .env 의 `{service}_API_PORT` 로 포트가 해석된다.
///   예) "statusChecker/status/get", "mainAction/weeing/pause", "inputHandler/mouse/move"
class Gateway {
  Gateway._();

  /// cloudflare 게이트웨이 도메인. 모든 API 는 여기를 반드시 거친다.
  static const String cloudflareBase = 'https://api.nongameanbun.xyz';

  static String get _proxyUrl => '$cloudflareBase/proxy';

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

    return http.post(
      Uri.parse(_proxyUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
  }

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
  ///   `wss://api.nongameanbun.xyz/ws?ip={ip}`
  static Uri signalingUri(String ip) {
    final wsBase = cloudflareBase.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
    return Uri.parse('$wsBase/ws').replace(queryParameters: {'ip': _hostOnly(ip)});
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
