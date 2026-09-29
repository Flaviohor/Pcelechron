import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';

/// 智云课堂（classroom.zju.edu.cn）客户端：SSO 登录 + 课程搜索。
///
/// ## 登录链路（经两个独立开源实现交叉验证）
///
/// 1. 持有统一认证的 iPlanetDirectoryPro cookie（复用 ZjuAm.getSsoCookie）；
/// 2. 从 `tgmedia.cmc.zju.edu.cn` 的 SSO 入口出发，手工跟随最多 24 跳重定向
///    （Location / Refresh 头、HTML meta refresh / JS location），逐跳收 cookie；
/// 3. 结束后从 classroom.zju.edu.cn 域的 `_token` cookie 里提取 Bearer token
///    （可能被百分号编码，也可能包在 PHP 序列化串里，两种都要处理）；
/// 4. `userapi/v1/infosimple` 校验登录并拿账号。
///
/// 参考：zzw4257/celechron-tauri `classroom.rs`、PeiPei233/zju-learning-assistant
/// `zju_assist.rs`、上游 issue #144。
///
/// ## 课程搜索
///
/// `pptnote/v1/searchlist?title=<课程名>&realname=<教师>`（Bearer），是官网
/// 自身搜索页调用的接口，返回 `total.list[]`（含 course_id/title/realname）。
///
/// ## 关于「直达链接」
///
/// 站点是 hash 路由 SPA，公开代码里没有构造课程页 URL 的先例（所有工具都
/// 走 API 拿数据而非跳页面）。本实现采用 `#/course/<courseId>` 作为最可能的
/// 直达路由——hash 路由拼错的后果只是落到 SPA 默认页，不会 404；调用方须
/// 同时把课程名写入剪贴板兜底（官网搜索一贴即中）。
class ClassroomService {
  ClassroomService._();

  static const _ssoEntryUrl =
      'https://tgmedia.cmc.zju.edu.cn/index.php?r=auth/login&auType=cmc'
      '&tenant_code=112&forward=https%3A%2F%2Fclassroom.zju.edu.cn%2F';
  static const _maxRedirectHops = 24;
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  static const _searchlistUrl =
      'https://classroom.zju.edu.cn/pptnote/v1/searchlist';
  static const _tenantId = '112';

  static _ClassroomSession? _session;
  static final Map<String, ClassroomCourse?> _matchCache = {};

  /// 与统一认证共享的客户端：让 ZjuAm 的 SSO cookie 缓存按账号生效。
  static final HttpClient _sharedClient = HttpClient();

  /// 登录（进程内缓存会话）。
  static Future<_ClassroomSession> _ensureSession({
    required String? username,
    required String? password,
  }) async {
    final current = _session;
    if (current != null) return current;
    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      throw ExceptionWithMessage('未登录，无法访问智云课堂');
    }
    final iPlanetCookie =
        await ZjuAm.getSsoCookie(_sharedClient, username, password);
    final session = await _login(iPlanetCookie);
    _session = session;
    return session;
  }

  static void clearSession() {
    _session = null;
    _matchCache.clear();
  }

  /// 在智云课堂里找与本课程匹配的条目。未登录/网络失败抛异常，调用方兜底。
  static Future<ClassroomCourse?> findCourse({
    required String courseName,
    String? teacher,
    required String? username,
    required String? password,
  }) async {
    final cacheKey = '$courseName|$teacher';
    if (_matchCache.containsKey(cacheKey)) return _matchCache[cacheKey];

    final session =
        await _ensureSession(username: username, password: password);
    final candidates = await _searchCourses(session, courseName, teacher);
    final best = _pickBest(candidates, courseName, teacher);
    _matchCache[cacheKey] = best;
    return best;
  }

  // ===== 登录 =====

  static Future<_ClassroomSession> _login(Cookie? iPlanetCookie) async {
    if (iPlanetCookie == null) {
      throw ExceptionWithMessage('统一认证未登录，无法访问智云课堂');
    }
    final jar = _CookieJar();
    jar.set('zjuam.zju.edu.cn', iPlanetCookie.name, iPlanetCookie.value);

    final httpClient = HttpClient()..autoUncompress = true;
    var currentUrl = Uri.parse(_ssoEntryUrl);
    var reachedClassroom = false;
    var lastBody = '';

    try {
      for (var hop = 0; hop < _maxRedirectHops; hop++) {
        final request = await httpClient.openUrl('GET', currentUrl).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout());
        request.followRedirects = false;
        request.headers.set('User-Agent', _userAgent);
        for (final cookie in jar.cookiesFor(currentUrl)) {
          request.cookies.add(cookie);
        }
        final response = await request.close().timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout(),
            );

        // 逐条收下 Set-Cookie；带 Domain 属性的按父域归档。
        for (final raw in response.headers[HttpHeaders.setCookieHeader] ?? []) {
          jar.store(currentUrl, raw);
        }
        final body = await response.transform(utf8.decoder).join();

        final target = _nextTarget(currentUrl, response, body);
        if (target != null) {
          currentUrl = target;
          continue;
        }
        reachedClassroom = currentUrl.host == 'classroom.zju.edu.cn' ||
            (currentUrl.host.endsWith('.cmc.zju.edu.cn') &&
                body.contains('classroom.zju.edu.cn'));
        lastBody = body;
        break;
      }
    } on Object {
      httpClient.close();
      rethrow;
    }

    if (!reachedClassroom) {
      final snippet = lastBody.length > 160
          ? lastBody.substring(0, 160).replaceAll('\n', ' ')
          : lastBody;
      throw ExceptionWithMessage(
          '智云课堂 SSO 未完成（停留在 ${currentUrl.host}）；校园网不可达或登录态失效',
          details: snippet);
    }

    // 首页预热：确保 classroom 域的会话 cookie 齐全。
    final warmUp = await httpClient.openUrl(
        'GET', Uri.parse('https://classroom.zju.edu.cn/'));
    warmUp.followRedirects = true;
    warmUp.headers.set('User-Agent', _userAgent);
    for (final cookie
        in jar.cookiesFor(Uri.parse('https://classroom.zju.edu.cn/'))) {
      warmUp.cookies.add(cookie);
    }
    final warmUpResponse = await warmUp.close().timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout(),
        );
    await warmUpResponse.drain<void>();

    final token = jar.tokenFor('classroom.zju.edu.cn');
    if (token == null || token.isEmpty) {
      throw ExceptionWithMessage('智云课堂登录态缺失（_token cookie 未下发）');
    }

    final infoUri =
        Uri.parse('https://classroom.zju.edu.cn/userapi/v1/infosimple');
    final infoRequest = await httpClient.openUrl('GET', infoUri);
    infoRequest.headers.set('User-Agent', _userAgent);
    infoRequest.headers.set('Authorization', 'Bearer $token');
    final infoResponse = await infoRequest.close().timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout(),
        );
    final infoBody = await infoResponse.transform(utf8.decoder).join();
    final info = decodeJsonMap(infoBody, context: '智云课堂用户信息');
    final params = asStringMap(info['params']) ?? {};
    final account = (asString(params['account']) ?? '').trim();
    final userId = (params['id']?.toString() ?? '').trim();
    if (account.isEmpty) {
      throw ExceptionWithMessage('智云课堂登录校验失败（用户信息为空）');
    }
    return _ClassroomSession(
      httpClient: httpClient,
      token: token,
      account: account,
      userId: userId,
    );
  }

  /// 从重定向响应里解析下一跳地址：Location 头 → Refresh 头 → HTML/JS 内联。
  static Uri? _nextTarget(
      Uri current, HttpClientResponse response, String body) {
    final location = response.headers.value(HttpHeaders.locationHeader);
    final resolved = _resolveUrl(current, location);
    if (resolved != null) return resolved;

    final refresh = response.headers.value('refresh');
    if (refresh != null) {
      final parts = refresh.split(';');
      for (final part in parts) {
        final t = part.trim();
        if (t.toLowerCase().startsWith('url=')) {
          final resolvedRefresh = _resolveUrl(current, t.substring(4));
          if (resolvedRefresh != null) return resolvedRefresh;
        }
      }
    }

    final patterns = [
      RegExp(r'''url=([^"'\s>]+)''', caseSensitive: false),
      RegExp(r'''location\.href\s*=\s*["']([^"']+)["']'''),
      RegExp(r'''window\.location\s*=\s*["']([^"']+)["']'''),
      RegExp(r'''window\.location\.replace\(["']([^"']+)["']\)'''),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(body);
      if (match != null) {
        final resolvedHtml = _resolveUrl(current, match.group(1));
        if (resolvedHtml != null) return resolvedHtml;
      }
    }
    return null;
  }

  static Uri? _resolveUrl(Uri current, String? target) {
    if (target == null) return null;
    final trimmed = target.trim().trimMatches('"\'');
    if (trimmed.isEmpty) return null;
    try {
      return current.resolve(trimmed);
    } on FormatException {
      return Uri.tryParse(trimmed);
    }
  }

  // ===== 课程搜索 =====

  static Future<List<ClassroomCourse>> _searchCourses(
      _ClassroomSession session, String title, String? teacher) async {
    final courses = <ClassroomCourse>[];
    for (var page = 1; page <= 3; page++) {
      final uri = Uri.parse(_searchlistUrl).replace(queryParameters: {
        'tenant_id': _tenantId,
        'tenant_code': _tenantId,
        'user_id': session.userId,
        'user_name': session.account,
        'page': '$page',
        'per_page': '16',
        'title': title,
        'realname': teacher ?? '',
        'trans': '',
        'randomKey':
            DateTime.now().microsecondsSinceEpoch.remainder(100000).toString(),
      });
      final request = await session.httpClient.openUrl('GET', uri);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer ${session.token}');
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      final body = await response.transform(utf8.decoder).join();
      final payload = decodeJsonMap(body, context: '智云课堂课程搜索');
      final code = asInt(payload['code']);
      if (code != null && code != 0) {
        throw ExceptionWithMessage(
            '智云课堂课程搜索失败：${asString(payload['msg']) ?? code}');
      }
      final total = asStringMap(payload['total']) ?? {};
      final list = asDynamicList(total['list']) ?? const [];
      for (final raw in list) {
        final item = asStringMap(raw);
        if (item == null) continue;
        final courseId = _asId(item['course_id'] ?? item['id']);
        if (courseId == null || courseId <= 0) continue;
        courses.add(ClassroomCourse(
          courseId: courseId,
          title: (asString(item['title']) ?? '').trim(),
          realname: (asString(item['realname']) ??
                  asString(item['teacher_name']) ??
                  '')
              .trim(),
        ));
      }
      final totalCount = asInt(total['total']) ?? courses.length;
      if (courses.length >= totalCount || list.isEmpty) break;
    }
    return courses;
  }

  /// 归一化后挑选最匹配的课程：名字互含 + 教师命中加分。
  static ClassroomCourse? _pickBest(
      List<ClassroomCourse> candidates, String courseName, String? teacher) {
    final target = _normalize(courseName);
    if (target.isEmpty) return null;
    final teacherKey = _normalize(teacher ?? '');
    ClassroomCourse? best;
    var bestScore = 0;
    for (final candidate in candidates) {
      final title = _normalize(candidate.title);
      if (title.isEmpty) continue;
      var score = 0;
      if (title == target) {
        score = 3;
      } else if (title.contains(target) || target.contains(title)) {
        score = title.length >= 4 || target.length >= 4 ? 2 : 0;
      }
      if (score > 0 && teacherKey.isNotEmpty) {
        final lecturer = _normalize(candidate.realname);
        if (lecturer.isNotEmpty &&
            (lecturer.contains(teacherKey) || teacherKey.contains(lecturer))) {
          score += 1;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  static String _normalize(String input) =>
      input.replaceAll(RegExp(r'\s+'), '').trim();

  static int? _asId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }
}

class ClassroomCourse {
  final int courseId;
  final String title;
  final String realname;

  const ClassroomCourse({
    required this.courseId,
    required this.title,
    required this.realname,
  });
}

class _ClassroomSession {
  final HttpClient httpClient;
  final String token;
  final String account;
  final String userId;

  const _ClassroomSession({
    required this.httpClient,
    required this.token,
    required this.account,
    required this.userId,
  });
}

/// 极简 cookie 罐：按域名归档，请求时带上域名后缀匹配的所有 cookie。
class _CookieJar {
  final Map<String, Map<String, String>> _store = {};

  void set(String host, String name, String value) {
    _store.putIfAbsent(host, () => {})[name] = value;
  }

  /// 解析并归档一条 Set-Cookie；Domain 属性决定归档域（点前缀剥掉）。
  void store(Uri requestUri, String raw) {
    final segments = raw.split(';');
    if (segments.isEmpty) return;
    final pair = segments.first;
    final eq = pair.indexOf('=');
    if (eq <= 0) return;
    var name = pair.substring(0, eq).trim();
    var value = pair.substring(eq + 1).trim();
    var host = requestUri.host;
    for (final attr in segments.skip(1)) {
      final attrPair = attr.trim();
      if (attrPair.toLowerCase().startsWith('domain=')) {
        var domain = attrPair.substring(7).trim();
        if (domain.startsWith('.')) domain = domain.substring(1);
        if (domain.isNotEmpty) host = domain;
      }
      if (attrPair.toLowerCase().startsWith('expires=') ||
          attrPair.toLowerCase().startsWith('max-age=')) {
        // 过期语义从简：会话级缓存不持久化，忽略过期属性。
        continue;
      }
      if (name.isEmpty) name = '';
    }
    if (name.isEmpty) return;
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    set(host, name, value);
  }

  List<Cookie> cookiesFor(Uri requestUri) {
    final host = requestUri.host;
    final result = <Cookie>[];
    _store.forEach((domain, cookies) {
      final matches = host == domain || host.endsWith('.$domain');
      if (matches) {
        cookies.forEach((name, value) {
          result.add(Cookie(name, value));
        });
      }
    });
    return result;
  }

  /// 取某域下的 `_token` cookie：先原样、再百分号解码、再 PHP 序列化兜底。
  String? tokenFor(String host) {
    final cookies = _store[host];
    if (cookies == null) return null;
    final raw = cookies['_token'];
    if (raw == null || raw.isEmpty) return null;
    final candidates = <String>[raw];
    try {
      candidates.add(Uri.decodeComponent(raw));
    } on ArgumentError {
      // 非法百分号编码就跳过解码分支。
    }
    final serialized = RegExp(r'\{i:\d+;s:\d+:"_token";i:\d+;s:\d+:"(.+?)";\}');
    for (final candidate in candidates) {
      final direct = candidate.trim().trimMatches('"');
      if (direct.isNotEmpty && !direct.contains(';s:')) return direct;
      final match = serialized.firstMatch(candidate);
      if (match != null) {
        final inner = match.group(1);
        if (inner != null && inner.trim().isNotEmpty) return inner.trim();
      }
    }
    return null;
  }
}

extension on String {
  String trimMatches(String chars) {
    var result = this;
    for (final c in chars.split('')) {
      result = result.trim();
      while (result.startsWith(c)) {
        result = result.substring(1);
      }
      while (result.endsWith(c)) {
        result = result.substring(0, result.length - 1);
      }
    }
    return result;
  }
}
