import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:get/get.dart';

/// 智云课堂（classroom.zju.edu.cn）客户端：CAS 换 token + 「我的课程」匹配。
///
/// ## 登录链路（智云课堂开发经验总结，已在鸿蒙端验证）
///
/// 1. 统一认证拿到 `iPlanetDirectoryPro`（复用 ZjuAm.getSsoCookie）；
/// 2. 携带它请求
///    `https://zjuam.zju.edu.cn/cas/login?service=<智云回调>`，
///    service 指向智云自己的回调 `https://classroom.zju.edu.cn/api/v1/cas/login`；
/// 3. CAS 校验通过后 302 到回调地址（带 `ticket=ST-xxx`），访问回调，
///    响应 JSON 的 `data.token` 就是后续所有 API 用的 JWT Bearer。
///
/// 注意：不要走 tgmedia 的 PHP SSO 链——实测会中转到通行证(zuinfo)页面
/// 卡死，且智云有官方 CAS 回调，service 票据直换 token 更短更稳。
/// Token 持久化在 dbOptions，401 时清掉重登（经验文档一.2）。
///
/// ## 课程匹配：从「我的课程」入手 + 核心课名分层匹配
///
/// 数据源 `courseapi/v2/course-live/get-my-course-month?month=YYYY-MM`
/// （Bearer），取上月/本月/下月覆盖学期边界。**智云后端是 PHP**：关联数组
/// 序列化后 `list`/`course` 可能是 JSON Object（Map）而非 Array（List），
/// 解析必须两种形态都兼容（空列表时又可能是 `[]`）。
///
/// 课程名匹配按经验文档的分层梯队：全等 → 核心课名（剥离「网络/线上/
/// 双语/MOOC」等修饰符与班级号）相等 → 核心课名去符号后子串包含（长度
/// ≥3）→ 教师辅助判定（多教师拆分后任一命中加分）。
///
/// ## 直达链接（用户实测确认的格式）
///
/// `https://classroom.zju.edu.cn/livingroom?course_id=<id>&sub_id=<sub_id>&tenant_code=112`
/// 该页同时支持直播与回放；对整门课取迭代序最后一节（最近一节）。
class ClassroomService {
  ClassroomService._();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _casLoginUrl = 'https://zjuam.zju.edu.cn/cas/login';
  static const _classroomCasCallback =
      'https://classroom.zju.edu.cn/api/v1/cas/login';
  static const _myCourseMonthUrl =
      'https://classroom.zju.edu.cn/courseapi/v2/course-live/get-my-course-month';

  /// Token 持久化 key（经验文档一.2：Token 有效期较长，内存 + 本地双缓存，
  /// 只有 401 才重登）。存 originalWebPageBox，退出登录清缓存时一并清掉。
  static const _tokenCacheKey = 'classroom_bearer_token';

  static _ClassroomSession? _session;
  static final Map<String, ClassroomMatch?> _matchCache = {};

  /// 与统一认证共享的客户端：让 ZjuAm 的 SSO cookie 缓存按账号生效。
  static final HttpClient _sharedClient = HttpClient();

  static DatabaseHelper? get _db {
    try {
      return Get.find<DatabaseHelper>(tag: 'db');
    } on Object {
      return null;
    }
  }

  /// 登录（内存 + 持久化双层缓存）。
  static Future<_ClassroomSession> _ensureSession({
    required String? username,
    required String? password,
  }) async {
    final current = _session;
    if (current != null) return current;

    final cachedToken = _db?.getCachedWebPage(_tokenCacheKey) ?? '';
    if (cachedToken.isNotEmpty) {
      final session =
          _ClassroomSession(httpClient: _sharedClient, token: cachedToken);
      _session = session;
      return session;
    }

    if (username == null ||
        username.isEmpty ||
        password == null ||
        password.isEmpty) {
      throw ExceptionWithMessage('未登录，无法访问智云课堂');
    }
    final session = await _login(username, password);
    _db?.setCachedWebPage(_tokenCacheKey, session.token);
    _session = session;
    return session;
  }

  /// 清空内存会话与持久化 token（401 时调用；退出登录也会随缓存清理）。
  static void _forgetToken() {
    _session = null;
    try {
      unawaited(_db?.setCachedWebPage(_tokenCacheKey, ''));
    } on Object {
      // 持久化失败不影响内存会话重建。
    }
  }

  static void clearSession() {
    _forgetToken();
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

    // zjuam CAS 登录偶发 8s 超时（诊断日志实测），失败后等 2 秒重试一次。
    _ClassroomSession session;
    try {
      session = await _ensureSession(username: username, password: password);
    } on Object {
      await Future<void>.delayed(const Duration(seconds: 2));
      session = await _ensureSession(username: username, password: password);
    }

    var lessons = await _fetchMyLessons(session);
    if (lessons == null) {
      // 401：token 失效，重登一次再试（经验文档「Token 失效自动刷新」）。
      _forgetToken();
      session = await _ensureSession(username: username, password: password);
      lessons = await _fetchMyLessons(session) ?? const <ClassroomLesson>[];
    }

    // 匹配按经验文档的分层梯队执行，取最高梯队的全部课节。
    final target = _normalize(courseName);
    final targetCore = extractCoreCourseName(courseName);
    final teacherSet = _teachersOf(teacher);
    final subIds = <int>{};
    int? latestCourseId;
    int? latestSubId;
    String bestTitle = '';
    String bestRealname = '';
    var bestTier = 0;

    for (final lesson in lessons) {
      final remote = _normalize(lesson.title);
      final remoteCore = extractCoreCourseName(lesson.title);
      if (remote.isEmpty) continue;

      var tier = 0;
      if (remote == target) {
        tier = 4; // 全等
      } else if (targetCore.isNotEmpty && remoteCore == targetCore) {
        tier = 3; // 核心课名相等
      } else if (targetCore.length >= 3 &&
          (remoteCore.contains(targetCore) ||
              targetCore.contains(remoteCore))) {
        tier = 2; // 核心课名子串包含
      }
      if (tier <= 0) continue;

      if (teacherSet.isNotEmpty) {
        final lecturer = _normalize(lesson.realname);
        if (lecturer.isNotEmpty &&
            teacherSet
                .any((t) => lecturer.contains(t) || t.contains(lecturer))) {
          tier += 1; // 教师辅助加分（多教师拆分后任一命中即可）
        }
      }

      if (tier >= bestTier) {
        if (tier > bestTier) {
          bestTier = tier;
          subIds.clear();
        }
        bestTitle = lesson.title;
        bestRealname = lesson.realname;
        subIds.add(lesson.subId);
        latestCourseId = lesson.courseId;
        latestSubId = lesson.subId;
      }
    }

    DiagnosticLogService.instance.record(
      module: 'classroom',
      operation: 'match',
      message: subIds.isEmpty
          ? '我的课程共 ${lessons.length} 节，无「$courseName」的匹配'
          : '我的课程共 ${lessons.length} 节，「$courseName」按梯队 $bestTier 命中 '
              '${subIds.length} 节（course_id=$latestCourseId）',
    );
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
  ///
  /// token 失效（401）返回 null，由调用方重登后重试。
  static Future<List<ClassroomLesson>?> _fetchMyLessons(
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
      final uri = Uri.parse(_myCourseMonthUrl)
          .replace(queryParameters: {'month': month});
      final request = await session.httpClient.openUrl('GET', uri);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer ${session.token}');
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      if (response.statusCode == HttpStatus.unauthorized) {
        await response.drain<void>();
        return null; // token 失效
      }
      final body = await response.transform(utf8.decoder).join();
      final payload = decodeJsonMap(body, context: '智云课堂我的课程');

      // PHP 后端：list 可能是 Array，也可能（历史数据/空表）是 Object。
      for (final rawDay in _iterableOf(payload['list'])) {
        final day = asStringMap(rawDay);
        if (day == null) continue;
        for (final rawLesson in _iterableOf(day['course'])) {
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

  /// PHP 关联数组兼容：List 直接用，Map 取 values（见类文档「课程匹配」）。
  static Iterable<Object?> _iterableOf(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }

  static String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  // ===== 登录：CAS service 票据直换智云 token =====

  static Future<_ClassroomSession> _login(
      String username, String password) async {
    var iPlanetCookie =
        await ZjuAm.getSsoCookie(_sharedClient, username, password);
    if (iPlanetCookie == null) {
      throw ExceptionWithMessage('统一认证未登录，无法访问智云课堂');
    }
    final httpClient = HttpClient()..autoUncompress = true;
    try {
      final service = Uri.encodeComponent(_classroomCasCallback);
      final casUri = Uri.parse('$_casLoginUrl?service=$service');

      // CAS 返回 200（登录页）而非 302 带票，说明 iPlanet 已失效：
      // 清掉统一认证缓存强制重登一次再试；仍失败则把页面摘要写进日志。
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) {
          iPlanetCookie =
              await ZjuAm.getSsoCookie(_sharedClient, username, password);
          if (iPlanetCookie == null) {
            throw ExceptionWithMessage('统一认证重登失败');
          }
        }
        final cookie = iPlanetCookie!;
        final casRequest = await httpClient.openUrl('GET', casUri).timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout(),
            );
        casRequest.followRedirects = false;
        casRequest.headers.set('User-Agent', _userAgent);
        casRequest.cookies.add(Cookie(cookie.name, cookie.value));
        final casResponse = await casRequest.close().timeout(
              const Duration(seconds: 8),
              onTimeout: () => throw requestTimeout(),
            );
        final location = casResponse.headers.value(HttpHeaders.locationHeader);
        if (casResponse.statusCode == HttpStatus.movedTemporarily &&
            location != null &&
            location.contains('ticket=')) {
          return await _exchangeToken(httpClient, location);
        }
        if (attempt == 0) {
          // 第一次失败：作废缓存的统一认证会话，下一次强制重新登录。
          await ZjuAm.clearCachedSsoCookie(username);
          continue;
        }
        final summary = await responseSummaryOf(casResponse);
        throw ExceptionWithMessage(
          '统一认证会话无效，未能取得智云课堂票据',
          details: 'CAS 状态 ${casResponse.statusCode}，'
              'Location=${location ?? '<无>'}；$summary',
        );
      }
      throw ExceptionWithMessage('未能取得智云课堂票据');
    } on Object {
      httpClient.close();
      rethrow;
    }
  }

  /// 跟随回调（可能再有一跳），最终应返回含 token 的 JSON。
  static Future<_ClassroomSession> _exchangeToken(
      HttpClient httpClient, String callbackUrl) async {
    var url = Uri.parse(callbackUrl);
    String body = '';
    for (var hop = 0; hop < 5; hop++) {
      final request = await httpClient.openUrl('GET', url).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      request.followRedirects = hop < 4;
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      body = await response.transform(utf8.decoder).join();
      final next = response.headers.value(HttpHeaders.locationHeader);
      if (next != null && next.isNotEmpty) {
        url = url.resolve(next);
        continue;
      }
      break;
    }

    final payload = decodeJsonMap(body, context: '智云课堂 CAS 回调');
    final data = asStringMap(payload['data']);
    final token = (asString(data?['token']) ?? '').trim();
    if (token.isEmpty) {
      throw ExceptionWithMessage(
        '智云课堂 CAS 回调未下发 token',
        details: body.length > 300 ? body.substring(0, 300) : body,
      );
    }
    return _ClassroomSession(httpClient: httpClient, token: token);
  }

  /// 读取 CAS 200 响应体摘要（登录页 / 未授权 service 一眼可辨）。
  static Future<String> responseSummaryOf(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    final flat = body.replaceAll('\n', ' ');
    return flat.length > 200 ? flat.substring(0, 200) : flat;
  }

  static String _normalize(String input) =>
      input.replaceAll(RegExp(r'\s+'), '').trim();

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
        .map(_normalize)
        .where((t) => t.isNotEmpty)
        .toSet();
  }
}

/// 提取核心课名（经验文档「课程匹配核心算法」）：
/// 统一全角括号为半角 → 剥离教学方式修饰符（网络/线上/双语/MOOC 等）与
/// 班级号（01班/[01]/【02】）→ 去空白。保留等级与罗马数字（如 微积分（甲）I）。
String extractCoreCourseName(String name) {
  var result = name.replaceAll('（', '(').replaceAll('）', ')');
  result = result.replaceAll(
      RegExp(r'[((](?:网络|线上|线下|双语|全英文|英文|MOOC|慕课|网课)[))]',
          caseSensitive: false),
      '');
  result = result.replaceAll(RegExp(r'[([](?:\d{1,2})班[)\]]'), '');
  result = result.replaceAll(RegExp(r'[[【]\d{1,3}[】\]]'), '');
  result = result.replaceAll(RegExp(r'\s+'), '');
  return result.trim();
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

  const _ClassroomSession({required this.httpClient, required this.token});
}
