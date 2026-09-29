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
/// ## 课程匹配：从「我的课程」入手
///
/// `courseapi/v2/course-live/get-my-course-month?month=YYYY-MM`（Bearer）
/// 返回当月本人账号的全部课节：`list[]` 为天对象数组，每项的 `course[]`
/// 是课节对象（`id` 课程号 / `sub_id` 课节号 / `title` 课程名 / `sub_title`
/// 节次名 / `realname` 教师，均为字符串）。取上月、本月、下月三次，
/// 覆盖学期边界；天按升序排列，迭代序最后一节即最近一节。
///
/// 之所以不用搜索接口 `pptnote/v1/searchlist`：它返回的是全站可搜课程而
/// 非本人课程，搜得到不等于你的账号里有这门课的回放，实测导致「明明有课
/// 却识别成没课」。账号里确实存在的课节才是有无直播/回放的依据。
///
/// ## 直达链接（用户实测确认的格式）
///
/// `https://classroom.zju.edu.cn/livingroom?course_id=<id>&sub_id=<sub_id>&tenant_code=112`
/// 该页同时支持直播与回放；对整门课取最近一节（迭代序最后一条）。早先
/// 猜测的 `#/course/<id>` 路由是错的（只会落到官网首页）。
class ClassroomService {
  ClassroomService._();

  static const _ssoEntryUrl =
      'https://tgmedia.cmc.zju.edu.cn/index.php?r=auth/login&auType=cmc'
      '&tenant_code=112&forward=https%3A%2F%2Fclassroom.zju.edu.cn%2F';
  static const _maxRedirectHops = 24;
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  static _ClassroomSession? _session;
  static final Map<String, ClassroomMatch?> _matchCache = {};

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

  /// 在智云课堂「我的课程」里解析本课程：匹配课程 + 课节数 + 最近一节。
  ///
  /// 返回 null 的三种情况调用方都应视为「不展示卡片」：我的课程里没有
  /// 这门课（尚未上过课）、查找过程失败（如不在校园网）。账号里确实
  /// 存在课节，才说明有直播/回放可看。
  static Future<ClassroomMatch?> resolveCourse({
    required String courseName,
    String? teacher,
    required String? username,
    required String? password,
  }) async {
    final cacheKey = '$courseName|$teacher';
    if (_matchCache.containsKey(cacheKey)) return _matchCache[cacheKey];

    final session =
        await _ensureSession(username: username, password: password);
    final lessons = await _fetchMyLessons(session);

    // 归一化后挑选最匹配的课程：名字互含 + 教师命中加分。
    final target = _normalize(courseName);
    final teacherKey = _normalize(teacher ?? '');
    final subIds = <int>{};
    int? latestCourseId;
    int? latestSubId;
    String bestTitle = '';
    String bestRealname = '';
    var bestScore = 0;

    for (final lesson in lessons) {
      final title = _normalize(lesson.title);
      if (title.isEmpty) continue;
      var score = 0;
      if (title == target) {
        score = 3;
      } else if (title.contains(target) || target.contains(title)) {
        score = title.length >= 4 || target.length >= 4 ? 2 : 0;
      }
      if (score <= 0) continue;
      if (teacherKey.isNotEmpty) {
        final lecturer = _normalize(lesson.realname);
        if (lecturer.isNotEmpty &&
            (lecturer.contains(teacherKey) || teacherKey.contains(lecturer))) {
          score += 1;
        } else if (bestScore > 0) {
          // 教师写法不一致时降权而非淘汰，让同教师的课程优先。
          score -= 1;
        }
      }
      if (score >= bestScore) {
        if (score > bestScore) {
          bestScore = score;
          subIds.clear();
        }
        bestTitle = lesson.title;
        bestRealname = lesson.realname;
        subIds.add(lesson.subId);
        latestCourseId = lesson.courseId;
        latestSubId = lesson.subId;
      }
    }

    if (latestCourseId == null || latestSubId == null || subIds.isEmpty) {
      _matchCache[cacheKey] = null;
      return null;
    }
    final match = ClassroomMatch(
      course: ClassroomCourse(
        courseId: latestCourseId,
        title: bestTitle,
        realname: bestRealname,
      ),
      subCount: subIds.length,
      latestSubId: latestSubId,
    );
    _matchCache[cacheKey] = match;
    return match;
  }

  /// 拉取上月/本月/下月的「我的课程」课节，按 subId 去重。
  static Future<List<ClassroomLesson>> _fetchMyLessons(
      _ClassroomSession session) async {
    final now = DateTime.now();
    final months = <String>{
      _monthKey(DateTime(now.year, now.month - 1, 1)),
      _monthKey(now),
      _monthKey(DateTime(now.year, now.month + 1, 1)),
    };
    final lessons = <ClassroomLesson>[];
    final seenSubIds = <int>{};
    for (final month in months) {
      final uri = Uri.parse(
              'https://classroom.zju.edu.cn/courseapi/v2/course-live/get-my-course-month')
          .replace(queryParameters: {'month': month});
      final request = await session.httpClient.openUrl('GET', uri);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer ${session.token}');
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      final body = await response.transform(utf8.decoder).join();
      final payload = decodeJsonMap(body, context: '智云课堂我的课程');
      final days = asDynamicList(payload['list']) ?? const [];
      for (final rawDay in days) {
        final day = asStringMap(rawDay);
        if (day == null) continue;
        for (final rawLesson in asDynamicList(day['course']) ?? const []) {
          final lesson = asStringMap(rawLesson);
          if (lesson == null) continue;
          final courseId = _asId(lesson['id']);
          final subId = _asId(lesson['sub_id']);
          if (courseId == null || subId == null || seenSubIds.contains(subId)) {
            continue;
          }
          seenSubIds.add(subId);
          lessons.add(ClassroomLesson(
            courseId: courseId,
            subId: subId,
            title: (asString(lesson['title']) ?? '').trim(),
            subTitle: (asString(lesson['sub_title']) ?? '').trim(),
            realname: (asString(lesson['realname']) ?? '').trim(),
          ));
        }
      }
    }
    return lessons;
  }

  static String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

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

  static String _normalize(String input) =>
      input.replaceAll(RegExp(r'\s+'), '').trim();

  static int? _asId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }
}

/// 一次成功解析的智云课堂课程：匹配条目 + 课节数 + 最近一节。
class ClassroomMatch {
  final ClassroomCourse course;
  final int subCount;
  final int latestSubId;

  const ClassroomMatch({
    required this.course,
    required this.subCount,
    required this.latestSubId,
  });
}

/// 「我的课程」里的一条课节（一次上课对应一个 sub_id）。
class ClassroomLesson {
  final int courseId;
  final int subId;
  final String title;
  final String subTitle;
  final String realname;

  const ClassroomLesson({
    required this.courseId,
    required this.subId,
    required this.title,
    required this.subTitle,
    required this.realname,
  });
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
