import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

/// 智云课堂（Zhiyun, classroom.zju.edu.cn）服务——按《智云课堂与作业提交
/// 功能开发总结及实现方案》（Helechron 移植项目文档）实现。
///
/// ## 鉴权：zjuam CAS 换票 → 智云 token 接口直通（文档·2.1）
///
/// 1. 统一认证持有根会话 Cookie `iPlanetDirectoryPro`（ZjuAm.getSsoCookie）；
/// 2. 携带它请求 `zjuam/cas/login?service=<classroom/api/login/token>`，
///    CAS 302 带票跳到 `classroom.zju.edu.cn/api/login/token?ticket=ST-x`；
/// 3. 访问该回调，智云在响应体/Set-Cookie 中下发 JWT；
/// 4. 之后所有智云 API 携带 `Authorization: Bearer <token>` 与
///    `x-tenant-code: 112`（缺 tenant 头会 401/403）。
///
/// Token 双层缓存与自愈：内存 `_cachedZhiyunToken` + optionsBox
/// `zhiyun_token` 持久化；任何 API 遇 401 即清缓存重登并重放。
///
/// ## 核心 API（文档·2.2）
///
/// - `POST /api/course/get-user-courses`：当前用户全部课程；
/// - `GET  /api/course/get-course-catalogue?course_id=`：课节目录（录播）；
/// - `POST /api/course/search-courses`：全局搜索（兜底）。
///
/// ## 课程匹配（文档·2.3）
///
/// 名称清洗与梯队匹配沿用本文件底部助手；命中候选再按打分择优：
/// 当前学期 +100、教师命中 +50、核心课名全等 +80。
///
/// ## PHP 后端异构防御
///
/// 关联数组经 json_encode 会变 Object（Map），空表/连续索引则是 Array
/// （List）：解析一律 List/Map 双形态兼容，严禁 as List 强转。
class ZhiyunService {
  ZhiyunService._();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _zhiyunBase = 'https://classroom.zju.edu.cn';
  static const _userCoursesUrl =
      '$_zhiyunBase/api/course/get-user-courses';
  static const _catalogueUrl = '$_zhiyunBase/api/course/get-course-catalogue';
  static const _searchUrl = '$_zhiyunBase/api/course/search-courses';
  static const _tokenCallbackUrl = '$_zhiyunBase/api/login/token';
  static const _tenantCode = '112';

  /// Token 双层缓存：内存静态变量 + optionsBox 持久化。
  static const _tokenKey = 'zhiyun_token';
  static String? _cachedZhiyunToken;

  /// 显式绑定优先：只要曾经成功匹配过，强制视为可录播。
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
    final token = await _loginZhiyun(username, password);
    _cachedZhiyunToken = token;
    _db?.setCachedWebPage(_tokenKey, token);
    return token;
  }

  /// 浏览器式全程跟随登录：
  ///
  /// 直连 zjuam CAS 的 service 入口在 Keycloak 迁移后被拒（1.3.5 实测
  /// HTTP 500）。与 classroom 页面自身的跳转保持一致：未认证请求
  /// `/api/login/token` 会 302 到 identity.zju.edu.cn 的 Keycloak CAS
  /// （service=https%3A//classroom.zju.edu.cn/api/login/token），经 broker
  /// 绕 zjuam 验证 iPlanet 后带票回到 classroom 下发 JWT。逐跳带 Cookie、
  /// 收 Cookie，落点响应体 / Set-Cookie / classroom 域 Cookie 里取 token。
  static Future<String> _loginZhiyun(String username, String password) async {
    final iPlanet = await ZjuAm.getSsoCookie(_client, username, password);
    if (iPlanet == null) {
      throw const ZhiyunException('统一认证未登录');
    }

    final jar = <String, Cookie>{};

    String cookieKey(Cookie cookie, Uri source) {
      final domain = (cookie.domain?.trim().isNotEmpty == true
              ? cookie.domain!.trim()
              : source.host)
          .toLowerCase()
          .replaceFirst(RegExp(r'^\.'), '');
      final path =
          cookie.path?.trim().isNotEmpty == true ? cookie.path!.trim() : '/';
      return '${cookie.name}|$domain|$path';
    }

    bool isExpired(Cookie cookie) {
      if (cookie.maxAge != null && cookie.maxAge! <= 0) return true;
      final expires = cookie.expires;
      return expires != null && expires.isBefore(DateTime.now());
    }

    void storeAll(List<Cookie> cookies, Uri source) {
      for (final cookie in cookies) {
        if (cookie.name.trim().isEmpty) continue;
        final key = cookieKey(cookie, source);
        if (isExpired(cookie)) {
          jar.remove(key);
          continue;
        }
        if (cookie.domain == null || cookie.domain!.trim().isEmpty) {
          cookie.domain = source.host.toLowerCase();
        }
        if (cookie.path == null || cookie.path!.trim().isEmpty) {
          cookie.path = '/';
        }
        jar[key] = cookie;
      }
    }

    bool matchesUri(Cookie cookie, Uri uri) {
      if (isExpired(cookie)) return false;
      if (cookie.secure && uri.scheme != 'https') return false;
      final domain = (cookie.domain ?? '')
          .trim()
          .toLowerCase()
          .replaceFirst(RegExp(r'^\.'), '');
      if (domain.isEmpty) return false;
      final host = uri.host.toLowerCase();
      if (host != domain && !host.endsWith('.$domain')) return false;
      final path =
          cookie.path == null || cookie.path!.isEmpty ? '/' : cookie.path!;
      return uri.path.startsWith(path);
    }

    final trustedSsoCookie = Cookie(iPlanet.name, iPlanet.value)
      ..domain = iPlanet.domain ?? 'zju.edu.cn'
      ..path = '/'
      ..secure = iPlanet.secure;
    storeAll([trustedSsoCookie], Uri.parse('https://zjuam.zju.edu.cn/'));

    var current = Uri.parse(_tokenCallbackUrl);
    final stopwatch = Stopwatch()..start();
    final hopTrace = <String>[];

    for (var hop = 0; hop < 16; hop++) {
      if (stopwatch.elapsed > const Duration(seconds: 45)) {
        throw const ZhiyunException('智云课堂登录链路超时');
      }
      final HttpClientRequest request;
      try {
        request = await _client.getUrl(current).timeout(
              const Duration(seconds: 10),
              onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
            );
      } on SocketException catch (error) {
        DiagnosticLogService.instance.record(
          module: 'zhiyun',
          operation: 'loginHopError',
          requestUri: current,
          error: error,
        );
        throw ZhiyunException('无法解析或连接 ${current.host}；需校园网/VPN');
      }
      request.followRedirects = false;
      request.headers.set('User-Agent', _userAgent);
      request.cookies.addAll(jar.values.where((c) => matchesUri(c, current)));
      final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      storeAll(List<Cookie>.from(response.cookies), current);
      final location = response.headers.value(HttpHeaders.locationHeader);
      final body = await _readBodyWithTimeout(response);
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'loginHop',
        requestUri: current,
        statusCode: response.statusCode,
        location: location,
        message: 'zhiyun 登录第${hop + 1}跳',
      );

      if (isHttpRedirectStatus(response.statusCode) &&
          location != null &&
          location.trim().isNotEmpty) {
        hopTrace.add('${sanitizedRequestUri(current)} → HTTP '
            '${response.statusCode} → ${location.trim()}');
        current = current.resolve(location);
        continue;
      }

      // 落点：classroom 的 token 响应。JWT 可能在响应体、Set-Cookie，
      // 或此前跳中下发的 classroom 域 Cookie 里。
      final token = _extractToken(body, response, jar);
      if (token != null && token.isNotEmpty) {
        return token;
      }
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'tokenCallback',
        requestUri: current,
        statusCode: response.statusCode,
        message: '登录落点未含 JWT',
        error: body.length > 200 ? body.substring(0, 200) : body,
      );
      // identity 的 CAS 端点按站点注册表匹配 service：迁移未接入的站点
      // 一律 400「客户端未找到」（实测 classroom/zdbk 等均未注册，仅
      // courses 已接入）。这不是客户端可绕过的状态，给用户可读的解释。
      if (current.host == 'identity.zju.edu.cn' &&
          response.statusCode == HttpStatus.badRequest) {
        throw const ZhiyunException(
            '智云课堂登录暂不可用（学校统一认证迁移中，该站点尚未接入）；'
            '可先在浏览器打开智云课堂');
      }
      throw ZhiyunException(
          '智云课堂未下发 token（落点 ${current.host}，HTTP ${response.statusCode}）');
    }
    throw ExceptionWithMessage(
      '智云课堂登录失败：重定向次数过多',
      details: hopTrace.join('\n'),
    );
  }

  static String? _extractToken(
      String body, HttpClientResponse response, Map<String, Cookie> jar) {
    try {
      final payload = decodeJsonMap(body, context: '智云 token 回调');
      final candidates = [
        payload['token'],
        asStringMap(payload['data'])?['token'],
        payload['access_token'],
        asStringMap(payload['data'])?['access_token'],
        asStringMap(payload['user'])?['token'],
      ];
      for (final candidate in candidates) {
        final value = asString(candidate)?.trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    } on Object {
      // 响应不是 JSON：继续尝试 Cookie。
    }
    for (final cookie in response.cookies) {
      final value = cookie.value.trim();
      if (value.startsWith('eyJ') && value.length > 40) {
        return value;
      }
    }
    for (final cookie in jar.values) {
      if (!cookie.name.contains('token') && cookie.name != '_token') continue;
      final value = cookie.value.trim();
      if (value.isNotEmpty && !value.contains(';s:')) return value;
    }
    return null;
  }

  static void _reloginZhiyun() {
    _cachedZhiyunToken = null;
    _db?.setCachedWebPage(_tokenKey, '');
  }

  // ===== 基础请求：Bearer + tenant 头 + 401 自愈 =====

  static Future<String> _readBodyWithTimeout(HttpClientResponse response) {
    return response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂响应读取超时'),
        );
  }

  static Future<Map<String, dynamic>> _authedJson(
    String method,
    Uri uri, {
    String? jsonBody,
    required String token,
    required void Function(String) setToken,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final request = await _client.openUrl(method, uri).timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      request.followRedirects = true;
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('x-tenant-code', _tenantCode);
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonBody);
      }
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

  // ===== 核心数据源（文档·2.2） =====

  /// 当前用户全部课程（POST /api/course/get-user-courses）。
  static Future<List<ZhiyunCourse>> _fetchMyCourses(String token) async {
    final payload = await _authedJson(
      'POST',
      Uri.parse(_userCoursesUrl),
      jsonBody: jsonEncode({'page': 1, 'size': 100, 'keyword': ''}),
      token: token,
      setToken: (t) => _cachedZhiyunToken = t,
    );
    return _coursesFromPayload(payload);
  }

  /// 全局搜索课程（POST /api/course/search-courses）。
  static Future<List<ZhiyunCourse>> _searchCourses(
      String token, String keyword) async {
    final payload = await _authedJson(
      'POST',
      Uri.parse(_searchUrl),
      jsonBody: jsonEncode({'keyword': keyword, 'page': 1, 'size': 20}),
      token: token,
      setToken: (t) => _cachedZhiyunToken = t,
    );
    return _coursesFromPayload(payload);
  }

  /// 课节目录（GET /api/course/get-course-catalogue?course_id=）。
  static Future<List<ZhiyunSub>> _fetchCatalogue(
      String token, int courseId) async {
    final uri = Uri.parse(_catalogueUrl)
        .replace(queryParameters: {'course_id': courseId.toString()});
    final payload = await _authedJson(
      'GET',
      uri,
      token: token,
      setToken: (t) => _cachedZhiyunToken = t,
    );
    final data = asStringMap(payload['data']) ?? payload;
    final subs = <ZhiyunSub>[];
    for (final raw in _iterableOf(data['list'] ?? data['catalogue'])) {
      final map = asStringMap(raw);
      if (map == null) continue;
      final sub = _subFromJson(map);
      if (sub != null) subs.add(sub);
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

  /// 兼容 PHP 双形态：list 可能在 data.list / data.courses / 顶层。
  static List<ZhiyunCourse> _coursesFromPayload(Map<String, dynamic> payload) {
    final data = asStringMap(payload['data']) ?? payload;
    final raw = data['list'] ?? data['courses'] ?? payload['list'];
    final courses = <ZhiyunCourse>[];
    for (final item in _iterableOf(raw)) {
      final map = asStringMap(item);
      if (map == null) continue;
      final course = _courseFromJson(map);
      if (course != null) courses.add(course);
    }
    return courses;
  }

  // ===== 对卡片暴露的解析管线 =====

  /// 解析课程 → 智云课节（直达参数）。
  ///
  /// [ZhiyunResolve.notMatched]（我的课程与搜索都没有 / 无回放）时卡片
  /// 隐藏；其余失败以 [ZhiyunResolve.error] 带原因返回，卡片直接展示原因。
  static Future<ZhiyunResolve> resolveCourse({
    required String courseName,
    String? teacher,
    required String? username,
    required String? password,
  }) async {
    final bindingKey = _bindingKey(courseName, teacher);

    // 显式绑定优先：曾经成功匹配过就直接信任绑定。
    final bound = _db?.getCachedWebPage(bindingKey) ?? '';
    if (bound.isNotEmpty) {
      final map = asStringMap(jsonDecode(bound));
      final courseId = _asId(map?['course_id']);
      final subId = _asId(map?['sub_id']);
      if (courseId != null && subId != null) {
        final token = await _getToken(username: username, password: password);
        final subs = await _fetchCatalogue(token, courseId);
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

    // 统一认证偶发超时（诊断日志实测），失败等 2 秒重试一次。
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

    // 候选一：我的课程（打分择优，文档·2.3）。
    final teacherSet = _teachersOf(teacher);
    var matched =
        _pickBestByScore(await _fetchMyCourses(token), courseName, teacherSet);

    // 候选二：全局搜索（清洗名 + 核心名多关键词）。
    if (matched == null) {
      final keywords = <String>{
        cleanCourseName(courseName),
        extractCoreCourseName(courseName),
      }..removeWhere((k) => k.isEmpty);
      for (final keyword in keywords) {
        final found = await _searchCourses(token, keyword);
        matched = _pickBestByScore(found, courseName, teacherSet);
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

    // 课节目录：拿到 sub_id 才算可用。
    List<ZhiyunSub> subs;
    try {
      subs = await _fetchCatalogue(token, matched.courseId);
    } on ZhiyunException catch (error) {
      return ZhiyunResolve.error('获取回放失败：${error.message}');
    }
    if (subs.isEmpty) {
      return const ZhiyunResolve.notMatched(); // 没上/没生成回放 → 隐藏
    }

    // 成功：写入显式绑定。
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

  /// 直达 URL（文档·2.4 播放间拼接规范，tenant_code 为用户实测补充）。
  static String livingroomUrl(int courseId, int subId) =>
      'https://classroom.zju.edu.cn/livingroom?course_id=$courseId'
      '&sub_id=$subId&tenant_code=$_tenantCode';

  // ===== 匹配与解析助手 =====

  /// 命中候选打分择优（文档·2.3）：当前学期 +100、教师命中 +50、
  /// 核心课名全等 +80；先过名称梯队匹配再打分。
  static ZhiyunCourse? _pickBestByScore(
      List<ZhiyunCourse> candidates, String courseName, Set<String> teacherSet) {
    ZhiyunCourse? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      if (!matchesCourseName(
          courseName, candidate.title, teacherSet, candidate.realname)) {
        continue;
      }
      var score = 0;
      if (_stripSymbols(extractCoreCourseName(courseName)) ==
          _stripSymbols(extractCoreCourseName(candidate.title))) {
        score += 80;
      }
      final lecturer = _normalizeName(candidate.realname);
      if (teacherSet.isNotEmpty &&
          lecturer.isNotEmpty &&
          teacherSet.any((t) => lecturer.contains(t) || t.contains(lecturer))) {
        score += 50;
      }
      final termLabel = _currentTermLabel();
      if (termLabel != null &&
          candidate.term.isNotEmpty &&
          candidate.term.contains(termLabel)) {
        score += 100;
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  /// 当前学期标签（秋冬：9-1 月；春夏：2-8 月）。
  static String? _currentTermLabel() {
    final now = DateTime.now();
    final year = now.year;
    final month = now.month;
    final startYear = (month >= 2 && month <= 8) || month == 1
        ? year - 1
        : year;
    return month >= 2 && month <= 8
        ? '$startYear-${startYear + 1}春夏'
        : '$startYear-${startYear + 1}秋冬';
  }

  /// 多态容器兼容：List 直接用，Map 取 values。
  static Iterable<Object?> _iterableOf(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }

  /// 宽松字段抽取：course_id/id、name/title、teacher_name/teacher、term。
  static ZhiyunCourse? _courseFromJson(Map<String, dynamic> map) {
    final courseId = _asId(map['course_id'] ?? map['id']);
    if (courseId == null || courseId <= 0) return null;
    final title =
        (asString(map['name']) ?? asString(map['title']) ?? '').trim();
    if (title.isEmpty) return null;
    final teacher = (asString(map['teacher_name']) ??
            asString(map['teacher']) ??
            asString(map['realname']) ??
            '')
        .trim();
    final term = (asString(map['term']) ?? '').trim();
    return ZhiyunCourse(
        courseId: courseId, title: title, realname: teacher, term: term);
  }

  /// 课节字段：sub_id/id、title、video_date/start_time、has_video。
  static ZhiyunSub? _subFromJson(Map<String, dynamic> map) {
    final subId = _asId(map['sub_id'] ?? map['id']);
    if (subId == null || subId <= 0) return null;
    final hasVideo = map['has_video'];
    if (hasVideo != null && asBool(hasVideo) != true) return null;
    final title = (asString(map['title']) ?? '').trim();
    final recordedAt =
        DateTime.tryParse(asString(map['video_date']) ?? '') ??
            DateTime.tryParse(asString(map['start_time']) ?? '');
    return ZhiyunSub(subId: subId, title: title, recordedAt: recordedAt);
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

  static String _normalizeName(String input) =>
      input.replaceAll(RegExp(r'\s+'), '').trim();
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
  final String term;

  const ZhiyunCourse({
    required this.courseId,
    required this.title,
    required this.realname,
    this.term = '',
  });
}

/// 课节目录里的一条回放小节。
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

// ===== 课程名称清洗与梯队匹配（文档·2.3） =====

/// 基础清洗：规整括号、剥末尾班级号与 -数字 后缀。
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

/// 深度提取核心课名：剥教学修饰符与班级号，保留等级（甲/乙）与罗马数字。
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

/// 去除全部非字母数字汉字（用于宽松比对）。
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

/// 梯队式渐进模糊匹配。
///
/// Tier 1 冲突防御：等级（甲/乙）或罗马数字（I-V）两边都有且不一致 →
/// 直接 false，防止《大学物理(甲)I》串到(乙)II；Tier 2 归一化全等；
/// Tier 3 核心课名相等；Tier 4 特殊学科（大学英语分级同级）；Tier 5
/// 宽松子串包含（核心词 ≥3，教师交叉命中时放宽）。
bool matchesCourseName(
    String localName, String remoteName, Set<String> teacherSet,
    [String remoteTeacher = '']) {
  final cleanedLocal = cleanCourseName(localName);
  final cleanedRemote = cleanCourseName(remoteName);
  final coreLocal = extractCoreCourseName(localName);
  final coreRemote = extractCoreCourseName(remoteName);
  if (coreLocal.isEmpty || coreRemote.isEmpty) return false;

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

  if (_stripSymbols(cleanedLocal) == _stripSymbols(cleanedRemote)) return true;
  if (_stripSymbols(coreLocal) == _stripSymbols(coreRemote)) return true;

  final localEnglish = _collegeEnglishLevel(coreLocal);
  if (localEnglish != null &&
      localEnglish == _collegeEnglishLevel(coreRemote)) {
    return true;
  }

  if (coreLocal.length >= 3 &&
      (coreRemote.contains(coreLocal) || coreLocal.contains(coreRemote))) {
    return true;
  }

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

/// 荣誉课程（H）标记识别（文档·2.3 防串课预留）。
bool isHonorsCourse(String name) =>
    RegExp(r'[([]\s*(?:H|荣誉)\s*[)\]]', caseSensitive: false).hasMatch(name);
