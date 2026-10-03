import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

/// 智云课堂（Zhiyun, classroom.zju.edu.cn）服务——按《智云课堂功能开发
/// 实现全景技术报告》实现。
///
/// ## 鉴权：带 service 的一次性统一认证登录 → tgmedia 会话 → 智云 _token
///
/// zjuam CAS 的 service 白名单实测**不含** classroom.zju.edu.cn（no_auth
/// 页），认 tgmedia.cmc.zju.edu.cn。而「携 iPlanet 复用换票」的老路已被
/// 向 Keycloak（Wisdomgarden SSO）迁移中的 CAS 废弃——1.3.5.11 实测 CAS
/// 未按 iPlanet 为 tgmedia 签发票据（zdbk 同样中招，302 甩到
/// id.zju.edu.cn 的 Keycloak logout）。因此采用浏览器同款的一次性登录：
///
/// 1. `zjuam/cas/login?service=<tgmedia 认证入口>` 取登录表单（execution
///    与 JSESSIONID 绑定）；
/// 2. RSA 公钥加密密码后携 service 提交，CAS 校验通过即 302 跳回
///    tgmedia 并下发登录会话 Cookie（1.3.5.12 实测 Location 不带
///    ticket——tgmedia 挂 OpenAM Agent，认 iPlanetDirectoryPro）；
/// 3. 凭全套会话 Cookie 从 tgmedia 入口起跳（1.3.5.15 逐跳日志实测）：
///    Agent 放行 → tgmedia 首页 → yjapi casapi → zjuam CAS
///    OAuth2.0/authorize（此处认登录签发的 CASTGC，缺了会被踢回登录
///    表单）→ 带 code 一路走回 tgmedia/classroom，会话落成 `_token`
///    cookie；
/// 4. 之后所有智云 API 携带 `Authorization: Bearer <token>`。
///
/// 网络层：校外部分线路到 classroom/tgmedia 等真实 IP 被黑洞，
/// `ZjuIngressFallback`（lib/http/zju_ingress_fallback.dart）把这些主机
/// 钉到共享 ingress，TLS 的 SNI 与证书校验不变。
///
/// Token 双层缓存与自愈（报告·一/二.1）：内存 `_cachedZhiyunToken` +
/// optionsBox `zhiyun_token` 持久化；任何 API 遇 401 即 `_reloginZhiyun`
/// （清缓存 → 重新 `_loginZhiyunCas` → 重放原请求）。
///
/// ## 核心业务 API（报告·二.2）
///
/// - `GET /api/v1/course/my-courses`（term_id/year）：学期选修课列表；
/// - `POST /api/v1/course/search`（keyword/page）：全局搜索候选；
/// - `GET /api/v1/course/lesson-replay`（course_id）：回放小节 `sub_videos`
///   （sub_id、录制时间、播放地址）。
///
/// 播放间直达 URL：`https://classroom.zju.edu.cn/livingroom?course_id=
/// <course_id>&sub_id=<sub_id>&tenant_code=112`（用户实测确认）。
///
/// ## PHP 后端异构防御（报告·三.4）
///
/// 关联数组经 json_encode 会变成 Object（Map），空表/连续索引则是
/// Array（List）：解析一律 List/Map 双形态兼容，严禁 as List 强转。
class ZhiyunService {
  ZhiyunService._();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// tgmedia 认证入口（auType=cmc）：作为 zjuam CAS 的 service 使用。
  /// CAS 白名单只认 tgmedia（见类注释），换票后 302 带票跳回此 URL。
  static const _ssoEntryUrl =
      'https://tgmedia.cmc.zju.edu.cn/index.php?r=auth/login&auType=cmc'
      '&tenant_code=112&forward=https%3A%2F%2Fclassroom.zju.edu.cn%2F';
  static const _maxRedirectHops = 24;
  static const _zhiyunBase = 'https://classroom.zju.edu.cn';
  static const _userInfoUrl = '$_zhiyunBase/api/v1/user/info';
  static const _myCoursesUrl = '$_zhiyunBase/api/v1/course/my-courses';
  static const _searchUrl = '$_zhiyunBase/api/v1/course/search';
  static const _lessonReplayUrl = '$_zhiyunBase/api/v1/course/lesson-replay';
  static const _tenantCode = '112';

  /// Token 双层缓存：内存静态变量 + optionsBox 持久化（报告·二.1）。
  static const _tokenKey = 'zhiyun_token';
  static String? _cachedZhiyunToken;

  /// 显式绑定优先（报告·三.3）：只要曾经成功匹配过，强制视为可录播。
  static String _bindingKey(String courseName, String? teacher) =>
      'zhiyun_bind_${md5.convert(utf8.encode('$courseName|$teacher')).toString()}';

  static final HttpClient _client = HttpClient()..autoUncompress = true;

  static DatabaseHelper? get _db {
    try {
      return Get.find<DatabaseHelper>(tag: 'db');
    } on Object {
      return null;
    }
  }

  // ===== Token：双层缓存 + 自愈 =====

  static Future<String> _getToken({
    required String? username,
    required String? password,
  }) async {
    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      throw const ZhiyunException('未登录，无法访问智云课堂');
    }
    final cached = _cachedZhiyunToken;
    if (cached != null && cached.isNotEmpty) return cached;
    final persisted = _db?.getCachedWebPage(_tokenKey) ?? '';
    if (persisted.isNotEmpty) {
      _cachedZhiyunToken = persisted;
      return persisted;
    }
    final token = await _loginZhiyunCas(username, password);
    _cachedZhiyunToken = token;
    _db?.setCachedWebPage(_tokenKey, token);
    return token;
  }

  /// CAS 静默换票：带 service 的一次性完整登录（浏览器同款）→ 凭全套
  /// 登录会话 Cookie 从 tgmedia 入口起链 → classroom `_token` cookie。
  ///
  /// 链路（1.3.5.15 逐跳日志实测）：tgmedia Agent 放行 → tgmedia 首页 →
  /// yjapi casapi → zjuam CAS OAuth2.0/authorize → 带 code 回走 →
  /// classroom。其中 authorize 认登录 POST 签发的 CASTGC；只带 iPlanet
  /// 会被踢回登录表单，链路卡死。
  static Future<String> _loginZhiyunCas(
      String username, String password) async {
    final (sessionCookies, chainStart) =
        await _loginForZhiyunTicket(username, password);

    final jar = ZhiyunCookieJar();
    for (final cookie in sessionCookies) {
      if (cookie.name == 'iPlanetDirectoryPro') {
        // iPlanet 挂父域：tgmedia 等挂 OpenAM Agent 的主机靠它建会话。
        jar.set('zju.edu.cn', cookie.name, cookie.value);
      } else {
        // 其余（CASTGC 等 CAS 会话）按签发域归档：authorize 静默放行
        // 需要，但不外泄给链路上的其它浙大主机。
        jar.set(cookie.domain ?? 'zjuam.zju.edu.cn', cookie.name,
            cookie.value);
      }
    }
    // Cookie 名单（仅名字，不含值）：authorize 是否放行可直接对账。
    DiagnosticLogService.instance.record(
      module: 'zhiyun',
      operation: 'ssoCookies',
      message:
          '链路会话 Cookie：${sessionCookies.map((c) => c.name).join('、')}',
    );

    var currentUrl = chainStart;
    var reachedClassroom = false;
    var lastBody = '';
    // 链路总时限：逐跳超时管得住单跳，管不住「跳得慢」的重定向环。
    final chainStopwatch = Stopwatch()..start();
    for (var hop = 0; hop < _maxRedirectHops; hop++) {
      if (chainStopwatch.elapsed > const Duration(seconds: 45)) {
        throw ZhiyunException(
            '智云课堂登录链路超时（已 $hop 跳，停留在 ${currentUrl.host}）');
      }
      final HttpClientRequest request;
      try {
        request = await _client.openUrl('GET', currentUrl).timeout(
              const Duration(seconds: 10),
              onTimeout: () => throw const ZhiyunException('统一认证请求超时'),
            );
      } on SocketException catch (error) {
        // DNS 失效域名（如已下线的通行证 zuinfo）不再以裸 SocketException
        // 形态漏到卡片，翻译成可读文案并留诊断。
        DiagnosticLogService.instance.record(
          module: 'zhiyun',
          operation: 'ssoHopError',
          requestUri: currentUrl,
          error: error,
        );
        throw ZhiyunException('无法解析或连接 ${currentUrl.host}；需校园网/VPN');
      }
      request.followRedirects = false;
      request.headers.set('User-Agent', _userAgent);
      for (final cookie in jar.cookiesFor(currentUrl)) {
        request.cookies.add(cookie);
      }
      final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('统一认证请求超时'),
          );
      // 逐跳留痕：重定向环 / 卡点域名可直接从诊断日志读出。
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'ssoHop',
        requestUri: currentUrl,
        statusCode: response.statusCode,
        location: response.headers.value(HttpHeaders.locationHeader),
        message: 'SSO 第${hop + 1}跳',
      );
      for (final raw
          in response.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
        jar.store(currentUrl, raw);
      }
      final body = await _readBodyWithTimeout(response);

      final target = _nextRedirectTarget(currentUrl, response, body);
      if (target != null) {
        currentUrl = target;
        continue;
      }      reachedClassroom = currentUrl.host == 'classroom.zju.edu.cn' ||
          body.contains('classroom.zju.edu.cn') ||
          body.contains('_token');
      lastBody = body;
      break;
    }

    if (!reachedClassroom) {
      final snippet = lastBody.length > 160
          ? lastBody.substring(0, 160).replaceAll("\n", " ")
          : lastBody;
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'ssoStuck',
        message: 'SSO 未完成，停留在 ${currentUrl.host}',
        error: snippet,
      );
      throw ZhiyunException('智云课堂 SSO 未完成（停留在 ${currentUrl.host}）；需校园网/VPN 访问');
    }

    // 首页预热，确保 classroom 域会话 cookie 齐全。
    final warmUp = await _client.openUrl('GET', Uri.parse('$_zhiyunBase/'));
    warmUp.followRedirects = true;
    warmUp.headers.set('User-Agent', _userAgent);
    for (final cookie in jar.cookiesFor(Uri.parse('$_zhiyunBase/'))) {
      warmUp.cookies.add(cookie);
    }
    final warmUpResponse = await warmUp.close().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
        );
    // 预热体的读取同样限时：超时就跳过（_token 已在 jar 里，不阻塞登录）。
    await warmUpResponse.drain<void>().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );

    final token = jar.tokenFor('classroom.zju.edu.cn');
    if (token == null || token.isEmpty) {
      throw const ZhiyunException('智云课堂登录态缺失（_token cookie 未下发）');
    }
    return token;
  }

  /// 一次性带 service 的统一认证登录；把 ZjuAm 的异常翻译成卡片可展示的
  /// 单行短句（细节已由诊断日志记录）。
  static Future<(List<Cookie>, Uri)> _loginForZhiyunTicket(
      String username, String password) async {
    try {
      return await ZjuAm.loginForServiceCallback(
        _client,
        username,
        password,
        Uri.parse(_ssoEntryUrl),
        context: '智云课堂统一认证',
      );
    } on Exception catch (error) {
      final message = error.toString().split('\n').first.trim();
      throw ZhiyunException(
          message.isEmpty ? '统一认证登录失败' : '统一认证登录失败（$message）');
    }
  }

  /// 从重定向响应里解析下一跳：Location 头 → Refresh 头 → HTML/JS 内联。
  static Uri? _nextRedirectTarget(
      Uri current, HttpClientResponse response, String body) {
    final location = response.headers.value(HttpHeaders.locationHeader);
    final resolved = _resolveRedirect(current, location);
    if (resolved != null) return resolved;

    final refresh = response.headers.value('refresh');
    if (refresh != null) {
      for (final part in refresh.split(';')) {
        final t = part.trim();
        if (t.toLowerCase().startsWith('url=')) {
          final resolvedRefresh = _resolveRedirect(current, t.substring(4));
          if (resolvedRefresh != null) return resolvedRefresh;
        }
      }
    }

    final patterns = [
      RegExp(r'''url=([^"'\s>]+)''', caseSensitive: false),
      RegExp(r'''location\.href\s*=\s*["']([^"']+["'])'''),
      RegExp(r'''window\.location\s*=\s*["']([^"']+)['"]'''),
      RegExp(r'''window\.location\.replace\(["']([^"']+)["']\)'''),
      RegExp(r'''location\.replace\(["']([^"']+)["']\)'''),
      RegExp(
          r'''(?:top|self|parent)\.location(?:\.href)?\s*=\s*["']([^"']+)['"]'''),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(body);
      if (match != null) {
        final resolvedHtml = _resolveRedirect(current, match.group(1));
        if (resolvedHtml != null &&
            _isTrustedInlineTarget(current, resolvedHtml)) {
          return resolvedHtml;
        }
      }
    }
    return null;
  }

  /// 页面内联（HTML/JS）跳转只信任本站与已参与本链路的浙大主机：
  /// CAS 登录表单等页面嵌着的历史系统链接（如 zuinfo）会被 `url=`
  /// 类宽泛正则误认成跳转目标（1.3.5.16 实测 zuinfo 幽灵跳转）。
  /// Location / Refresh 头是服务端下发的，不经此过滤。
  static bool _isTrustedInlineTarget(Uri current, Uri target) {
    if (target.host == current.host) return true;
    const trustedHosts = {
      'zjuam.zju.edu.cn',
      'classroom.zju.edu.cn',
      'tgmedia.cmc.zju.edu.cn',
      'yjapi.cmc.zju.edu.cn',
      'courses.zju.edu.cn',
      'identity.zju.edu.cn',
    };
    return trustedHosts.contains(target.host);
  }

  static Uri? _resolveRedirect(Uri current, String? target) {
    if (target == null) return null;
    var trimmed = target.trim();
    if (trimmed.length >= 2) {
      final first = trimmed[0];
      final last = trimmed[trimmed.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    if (trimmed.isEmpty) return null;
    try {
      return current.resolve(trimmed);
    } on FormatException {
      return Uri.tryParse(trimmed);
    }
  }

  /// 自愈：清空双层缓存（401 / token 失效时调用）。
  static void _reloginZhiyun() {
    _cachedZhiyunToken = null;
    _db?.setCachedWebPage(_tokenKey, '');
  }

  // ===== 基础请求：401 自愈 + 统一解析 =====

  /// 限时读取响应体：`close()` 的超时管不到读流，钉扎入口/隧道若把
  /// body 拖住不结束，无界 join() 会让卡片永远转圈。
  static Future<String> _readBodyWithTimeout(HttpClientResponse response) {
    return response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂响应读取超时'),
        );
  }

  /// GET 一个智云 API 并解析 JSON；401 时重登并重放一次。
  static Future<Map<String, dynamic>> _getJson(
      Uri uri, String token, void Function(String) setToken) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final request = await _client.openUrl('GET', uri).timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      final body = await _readBodyWithTimeout(response);
      if (response.statusCode == HttpStatus.unauthorized && attempt == 0) {
        // token 失效：自愈后重放。
        _reloginZhiyun();
        token = _cachedZhiyunToken ?? '';
        if (token.isEmpty) {
          throw const ZhiyunException('智云课堂 token 自愈失败');
        }
        continue;
      }
      return decodeJsonMap(body, context: '智云课堂接口 $uri');
    }
    throw const ZhiyunException('智云课堂请求失败');
  }

  // ===== 核心业务 API（报告·二.2） =====

  /// GET /api/v1/user/info——校验 token 并拿用户 ID。
  static Future<String?> fetchUserId() async {
    final token = _cachedZhiyunToken;
    if (token == null || token.isEmpty) return null;
    final payload = await _getJson(
        Uri.parse(_userInfoUrl), token, (t) => _cachedZhiyunToken = t);
    final user = asStringMap(payload['user']) ?? asStringMap(payload['data']);
    return user?['user_id']?.toString() ??
        user?['id']?.toString() ??
        asString(user?['user_no']);
  }

  /// GET /api/v1/course/my-courses——本学期选修课列表。
  static Future<List<ZhiyunCourse>> _fetchMyCourses(String token) async {
    final now = DateTime.now();
    final yearStart = now.month >= DateTime.september ? now.year : now.year - 1;
    final termIndex =
        (now.month >= DateTime.september || now.month == 1) ? 1 : 2;
    final attempts = <Map<String, String>>[
      {
        'term_id': '$yearStart-${yearStart + 1}-$termIndex',
        'year': '$yearStart',
      },
      const {},
    ];
    for (final query in attempts) {
      final uri = Uri.parse(_myCoursesUrl).replace(queryParameters: query);
      final payload = await _getJson(uri, token, (t) => _cachedZhiyunToken = t);
      final courses = <ZhiyunCourse>[];
      // PHP 后端：courses 可能是 Array 也可能是 Object（报告·三.4）。
      for (final raw in _iterableOf(payload['courses'] ?? payload['list'])) {
        final map = asStringMap(raw);
        if (map == null) continue;
        final course = _courseFromJson(map);
        if (course != null) courses.add(course);
      }
      if (courses.isNotEmpty) return courses;
    }
    return const [];
  }

  /// GET /api/v1/course/lesson-replay——回放小节（sub_videos）。
  static Future<List<ZhiyunSub>> _fetchLessonReplays(
      String token, int courseId) async {
    final uri = Uri.parse(_lessonReplayUrl)
        .replace(queryParameters: {'course_id': '$courseId'});
    final payload = await _getJson(uri, token, (t) => _cachedZhiyunToken = t);
    final subs = <ZhiyunSub>[];
    for (final raw in _iterableOf(payload['sub_videos'])) {
      final map = asStringMap(raw);
      if (map == null) continue;
      final subId = _asId(map['sub_id'] ?? map['id']);
      if (subId == null || subId <= 0) continue;
      subs.add(ZhiyunSub(
        subId: subId,
        title:
            (asString(map['sub_title']) ?? asString(map['title']) ?? '').trim(),
        recordedAt:
            DateTime.tryParse(asString(map['record_time']) ?? '')?.toLocal(),
      ));
    }
    // 按录制时间升序（缺时间靠前），迭代序最后一节即最近一节。
    subs.sort((a, b) {
      final at = a.recordedAt, bt = b.recordedAt;
      if (at != null && bt != null) return at.compareTo(bt);
      if (at != null) return 1;
      if (bt != null) return -1;
      return 0;
    });
    return subs;
  }

  // ===== 对卡片暴露的解析管线 =====

  /// 解析课程 → 智云课节（直达参数）。
  ///
  /// [ZhiyunResolve.notMatched]（我的课程与搜索都没有）时卡片隐藏；
  /// 其余失败以 [ZhiyunResolve.error] 带原因返回，卡片直接展示原因，
  /// 不再静默隐藏——便于用户反馈定位。
  static Future<ZhiyunResolve> resolveCourse({
    required String courseName,
    String? teacher,
    required String? username,
    required String? password,
  }) async {
    final bindingKey = _bindingKey(courseName, teacher);

    // 显式绑定优先（报告·三.3）：曾经匹配过就直接信任绑定。
    final bound = _db?.getCachedWebPage(bindingKey) ?? '';
    if (bound.isNotEmpty) {
      final map = asStringMap(jsonDecode(bound));
      final courseId = _asId(map?['course_id']);
      final subId = _asId(map?['sub_id']);
      if (courseId != null && subId != null) {
        final token = await _getToken(username: username, password: password);
        final subs = await _fetchLessonReplays(token, courseId);
        final latest = subs.isEmpty ? subId : subs.last.subId;
        return ZhiyunResolve.ready(
          courseId: courseId,
          latestSubId: latest,
          subCount: subs.length,
          title: asString(map?['title']) ?? courseName,
          realname: asString(map?['teacher']) ?? '',
        );
      }
    }

    // zjuam CAS 登录偶发超时（诊断日志实测），失败等 2 秒重试一次。
    String token;
    try {
      token = await _getToken(username: username, password: password);
    } on ZhiyunException catch (error) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        token = await _getToken(username: username, password: password);
      } on ZhiyunException catch (retryError) {
        return ZhiyunResolve.error(
            '${retryError.message}（首次：${error.message}）');
      }
    }

    // 候选一：我的课程。
    var candidates = await _fetchMyCourses(token);
    var matched = _pickBest(candidates, courseName, _teachersOf(teacher));

    // 候选二：全局搜索（多重关键词 + 多教师降级检索，报告·二.4）。
    if (matched == null) {
      final keywords = <String>{
        cleanCourseName(courseName),
        extractCoreCourseName(courseName),
      }..removeWhere((k) => k.isEmpty);
      final teachers = _teachersOf(teacher).toList();
      for (final keyword in keywords) {
        for (final t in teachers.isEmpty ? [''] : teachers) {
          final found = await _searchCourseOnline(token, keyword, t);
          matched = _pickBest(found, courseName, _teachersOf(teacher));
          if (matched != null) break;
        }
        if (matched != null) break;
      }
    }

    if (matched == null) {
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'match',
        message: '我的课程与搜索均未命中「$courseName」',
      );
      return const ZhiyunResolve.notMatched();
    }

    // 回放小节：拿到 sub_id 才算可用。
    List<ZhiyunSub>? subs;
    try {
      subs = await _fetchLessonReplays(token, matched.courseId);
    } on ZhiyunException catch (error) {
      return ZhiyunResolve.error('获取回放失败：${error.message}');
    }
    if (subs.isEmpty) {
      return const ZhiyunResolve.notMatched(); // 没上/没生成回放 → 隐藏
    }

    // 成功：写入显式绑定（报告·三.3 显式绑定优先）。
    final binding = jsonEncode({
      'course_id': matched.courseId,
      'sub_id': subs.last.subId,
      'title': matched.title,
      'teacher': matched.realname,
    });
    _db?.setCachedWebPage(bindingKey, binding);

    return ZhiyunResolve.ready(
      courseId: matched.courseId,
      latestSubId: subs.last.subId,
      subCount: subs.length,
      title: matched.title,
      realname: matched.realname,
    );
  }

  /// 多态容器兼容（报告·三.4）：List 直接用，Map 取 values。
  static Iterable<Object?> _iterableOf(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }

  /// 宽松字段抽取：course_id/id、title/name、teacher/realname/lecturer。
  static ZhiyunCourse? _courseFromJson(Map<String, dynamic> map) {
    final courseId = _asId(map['course_id'] ?? map['id']);
    if (courseId == null || courseId <= 0) return null;
    final title =
        (asString(map['title']) ?? asString(map['name']) ?? '').trim();
    if (title.isEmpty) return null;
    final teacher = (asString(map['teacher']) ??
            asString(map['realname']) ??
            asString(map['lecturer']) ??
            '')
        .trim();
    return ZhiyunCourse(courseId: courseId, title: title, realname: teacher);
  }

  static int? _asId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  /// 教务教师字段拆分：`张三,李四` / `张三/李四` / `张三、李四` 均可。
  static Set<String> _teachersOf(String? teacher) {
    if (teacher == null || teacher.trim().isEmpty) return const {};
    return teacher
        .split(RegExp(r'[,，/、;；]'))
        .map((t) => t.replaceAll(RegExp(r'\s+'), '').trim())
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  /// 梯队匹配 + 教师交叉校验，返回最优候选（报告·三.2）。
  static ZhiyunCourse? _pickBest(List<ZhiyunCourse> candidates,
      String courseName, Set<String> teacherSet) {
    ZhiyunCourse? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      if (!matchesCourseName(
          courseName, candidate.title, teacherSet, candidate.realname)) {
        continue;
      }
      var score = 1;
      final lecturer = _normalizeName(candidate.realname);
      if (teacherSet.isNotEmpty &&
          lecturer.isNotEmpty &&
          teacherSet.any((t) => lecturer.contains(t) || t.contains(lecturer))) {
        score = 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  static String _normalizeName(String input) =>
      input.replaceAll(RegExp(r'\s+'), '').trim();

  /// 全局搜索（带教师的组合与无教师降级，报告·二.4）。
  static Future<List<ZhiyunCourse>> _searchCourseOnline(
      String token, String keyword, String teacher) async {
    final uri = Uri.parse(_searchUrl).replace(queryParameters: {'page': '1'});
    final request = await _client.openUrl('POST', uri);
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'keyword': keyword, 'realname': teacher}));
    final response = await request.close().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂搜索超时'),
        );
    final body = await _readBodyWithTimeout(response);
    final payload = decodeJsonMap(body, context: '智云课堂搜索');
    final courses = <ZhiyunCourse>[];
    for (final raw in _iterableOf(payload['list'] ?? payload['courses'])) {
      final map = asStringMap(raw);
      if (map == null) continue;
      final course = _courseFromJson(map);
      if (course != null) courses.add(course);
    }
    return courses;
  }

  /// 直达 URL（报告·二.2 播放间拼接规范）。
  static String livingroomUrl(int courseId, int subId) =>
      'https://classroom.zju.edu.cn/livingroom?course_id=$courseId'
      '&sub_id=$subId&tenant_code=$_tenantCode';
}

/// 智云侧业务异常（文案直接面向用户展示）。
class ZhiyunException implements Exception {
  final String message;
  const ZhiyunException(this.message);

  @override
  String toString() => message;
}

/// resolveCourse 的结果：ready = 可直达；notMatched = 隐藏卡片；
/// error = 卡片展示原因。
class ZhiyunResolve {
  final ZhiyunResolveKind kind;
  final int? courseId;
  final int? latestSubId;
  final int subCount;
  final String title;
  final String realname;
  final String errorMessage;

  const ZhiyunResolve._({
    required this.kind,
    this.courseId,
    this.latestSubId,
    this.subCount = 0,
    this.title = '',
    this.realname = '',
    this.errorMessage = '',
  });

  const ZhiyunResolve.ready({
    required int courseId,
    required int latestSubId,
    required int subCount,
    required String title,
    required String realname,
  }) : this._(
          kind: ZhiyunResolveKind.ready,
          courseId: courseId,
          latestSubId: latestSubId,
          subCount: subCount,
          title: title,
          realname: realname,
        );

  const ZhiyunResolve.notMatched() : this._(kind: ZhiyunResolveKind.notMatched);

  const ZhiyunResolve.error(String message)
      : this._(kind: ZhiyunResolveKind.error, errorMessage: message);
}

enum ZhiyunResolveKind { ready, notMatched, error }

/// 「我的课程」/搜索里的一条候选课程。
class ZhiyunCourse {
  final int courseId;
  final String title;
  final String realname;

  const ZhiyunCourse({
    required this.courseId,
    required this.title,
    required this.realname,
  });
}

/// lesson-replay 里的一条回放小节。
class ZhiyunSub {
  final int subId;
  final String title;
  final DateTime? recordedAt;

  const ZhiyunSub({
    required this.subId,
    required this.title,
    required this.recordedAt,
  });
}

// ===== 课程名称清洗与梯队匹配（报告·三.1 / 三.2） =====

/// 基础清洗（报告 `cleanCourseName`）：规整括号、剥末尾班级号与 -数字 后缀。
String cleanCourseName(String courseName) {
  var cleaned = courseName.trim();
  cleaned = cleaned.replaceAll('（', '(').replaceAll('）', ')');
  cleaned = cleaned.replaceAll('【', '[').replaceAll('】', ']');
  cleaned = cleaned.replaceAll(RegExp(r'[\(\[]\s*\d+\s*(班)?\s*[\)\]]$'), '');
  cleaned = cleaned.replaceAll(RegExp(r'-\d+$'), '');
  return cleaned.trim();
}

/// 剥荣誉/学院标签。
String _stripHonorsTag(String name) {
  return name.replaceAll(
      RegExp(r'[((]\s*(?:荣誉|竺可桢学院|honor)\s*[)\]]', caseSensitive: false), '');
}

/// 深度提取核心课名（报告 `extractCoreCourseName`）：剥教学模式修饰符
/// （网络/线上/双语/MOOC/研讨/实验/翻转/通识等）与班级号，
/// 保留等级（甲/乙）与罗马数字（I/II）——这些是区分同名的关键。
String extractCoreCourseName(String name) {
  var s = _stripHonorsTag(name).trim();
  s = s.replaceAll('（', '(').replaceAll('）', ')');
  s = s.replaceAll('【', '[').replaceAll('】', ']');
  s = s.replaceAll(
      RegExp(
          r'[\(\[]\s*(网络|线上|线下|双语|全英文|英文|mooc|MOOC|慕课|研讨|实验|翻转|理论|通识|通识核心|选修|必修)\s*[\)\]]',
          caseSensitive: false),
      '');
  s = s.replaceAll(RegExp(r'[\(\[]\s*\d+\s*(班)?\s*[\)\]]'), '');
  s = s.replaceAll(RegExp(r'-\d+$'), '');
  return s.trim();
}

/// 去除全部非字母数字汉字（用于 Tier 5 宽松比对）。
String _stripSymbols(String input) =>
    input.replaceAll(RegExp(r'[^0-9A-Za-z\u4e00-\u9fa5]'), '');

/// 提取等级标签（甲/乙/丙/丁/戊）。
String? _gradeTag(String name) {
  final m = RegExp(r'[([](甲|乙|丙|丁|戊)[)]').firstMatch(name);
  return m?.group(1);
}

/// 提取末尾罗马数字（I/II/III/IV/V）。
String? _romanTag(String name) {
  final m = RegExp(r'(I{1,3}|IV|V)$').firstMatch(name.trim());
  return m?.group(1);
}

/// 大学英语分级级别（I-V 或 1-5）。
String? _collegeEnglishLevel(String name) {
  final m = RegExp(r'大学英语\s*(I{1,3}|IV|V|[1-5])').firstMatch(name);
  return m?.group(1);
}

/// 梯队式渐进模糊匹配（报告 `matchesCourseName`）。
///
/// Tier 1 冲突防御：等级（甲/乙/丙/丁）或罗马数字（I-V）两边都有且
/// 不一致 → 直接 false，防止《大学物理(甲)I》串到(乙)II；
/// Tier 2 归一化完全相等；Tier 3 核心课名相等；Tier 4 特殊学科
/// （Python 课、大学英语分级同级）；Tier 5 宽松子串包含（核心词 ≥3，
/// 且教师交叉命中时放宽到有包含关系即可）。[remoteTeacher] 为智云侧
/// 教师字段，多教师已在 [teacherSet] 拆分。
bool matchesCourseName(
    String localName, String remoteName, Set<String> teacherSet,
    [String remoteTeacher = '']) {
  final cleanedLocal = cleanCourseName(localName);
  final cleanedRemote = cleanCourseName(remoteName);
  final coreLocal = extractCoreCourseName(localName);
  final coreRemote = extractCoreCourseName(remoteName);
  if (coreLocal.isEmpty || coreRemote.isEmpty) return false;

  // Tier 1：冲突防御。
  final localGrade = _gradeTag(coreLocal);
  final remoteGrade = _gradeTag(coreRemote);
  if (localGrade != null && remoteGrade != null && localGrade != remoteGrade) {
    return false;
  }
  final localRoman = _romanTag(coreLocal);
  final remoteRoman = _romanTag(coreRemote);
  if (localRoman != null && remoteRoman != null && localRoman != remoteRoman) {
    return false;
  }

  // Tier 2：归一化完全相等。
  if (_stripSymbols(cleanedLocal) == _stripSymbols(cleanedRemote)) return true;

  // Tier 3：核心课名相等。
  if (_stripSymbols(coreLocal) == _stripSymbols(coreRemote)) return true;

  // Tier 4：特殊学科规则——大学英语分级同级即同课。
  final localEnglish = _collegeEnglishLevel(coreLocal);
  if (localEnglish != null &&
      localEnglish == _collegeEnglishLevel(coreRemote)) {
    return true;
  }

  // Tier 5：宽松子串包含（核心词 ≥3）。
  if (coreLocal.length >= 3 &&
      (coreRemote.contains(coreLocal) || coreLocal.contains(coreRemote))) {
    return true;
  }

  // 教师交叉兜底：课名有包含关系且任一教师命中（同名多班场景）。
  final lecturer = remoteTeacher.replaceAll(RegExp(r'\s+'), '').trim();
  if (coreLocal.length >= 2 &&
      (coreRemote.contains(coreLocal) || coreLocal.contains(coreRemote)) &&
      teacherSet.isNotEmpty &&
      lecturer.isNotEmpty &&
      teacherSet.any((t) => lecturer.contains(t) || t.contains(lecturer))) {
    return true;
  }
  return false;
}

/// 极简 cookie 罐：按域名归档，请求时带上域名后缀匹配的所有 cookie。
class ZhiyunCookieJar {
  final Map<String, Map<String, String>> _store = {};

  void set(String host, String name, String value) {
    _store.putIfAbsent(host, () => {})[name] = value;
  }

  /// 解析并归档一条 Set-Cookie；带 Domain 属性的按父域归档。
  void store(Uri requestUri, String raw) {
    final segments = raw.split(';');
    if (segments.isEmpty) return;
    final pair = segments.first;
    final eq = pair.indexOf('=');
    if (eq <= 0) return;
    final name = pair.substring(0, eq).trim();
    var value = pair.substring(eq + 1).trim();
    var host = requestUri.host;
    for (final attr in segments.skip(1)) {
      final attrPair = attr.trim();
      if (attrPair.toLowerCase().startsWith('domain=')) {
        var domain = attrPair.substring(7).trim();
        if (domain.startsWith('.')) domain = domain.substring(1);
        if (domain.isNotEmpty) host = domain;
      }
    }
    if (name.isEmpty) return;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    set(host, name, value);
  }

  List<Cookie> cookiesFor(Uri requestUri) {
    final host = requestUri.host;
    final result = <Cookie>[];
    _store.forEach((domain, cookies) {
      if (host == domain || host.endsWith('.$domain')) {
        cookies.forEach((name, value) {
          result.add(Cookie(name, value));
        });
      }
    });
    return result;
  }

  /// 取 host 及其父域下的 `_token` cookie：先原样、再百分号解码、
  /// 再 PHP 序列化兜底。
  String? tokenFor(String host) {
    String? raw;
    for (final entry in _store.entries) {
      if (raw != null) break;
      final domain = entry.key;
      if (host == domain || host.endsWith('.$domain')) {
        final value = entry.value['_token'];
        if (value != null && value.isNotEmpty) raw = value;
      }
    }
    if (raw == null) return null;
    final candidates = <String>[raw];
    try {
      candidates.add(Uri.decodeComponent(raw));
    } on ArgumentError {
      // 非法百分号编码就跳过解码分支。
    }
    final serialized = RegExp(r'\{i:\d+;s:\d+:"_token";i:\d+;s:\d+:"(.+?)";\}');
    for (final candidate in candidates) {
      var direct = candidate.trim();
      if (direct.length >= 2 &&
          direct.startsWith('"') &&
          direct.endsWith('"')) {
        direct = direct.substring(1, direct.length - 1).trim();
      }
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
