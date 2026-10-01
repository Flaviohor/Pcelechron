import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:get/get.dart';

/// 智云课堂（classroom.zju.edu.cn）客户端：CAS 换 token + 回放关联匹配。
///
/// ## 登录（经验报告·二：CAS SSO → 智云 Bearer Token 兑换链路）
///
/// 1. 统一认证拿到 `iPlanetDirectoryPro`（复用 ZjuAm.getSsoCookie）；
/// 2. 携带它请求 `zjuam/cas/login?service=<智云回调>`；
/// 3. CAS 302 带票（ticket=ST-xxx）→ 访问回调
///    `classroom.zju.edu.cn/api/v1/cas/login?ticket=...`；
/// 4. 响应 JSON 的 `data.token` 即 JWT Bearer，持久化双缓存，
///    401 时清缓存重登并重放请求。
///
/// ## 核心业务 API（经验报告·二.2 的四个端点）
///
/// - `GET /api/v1/course/my-courses`（term_id/year）：本学期选修课列表；
/// - `POST /api/v1/course/search`（keyword/page）：全局搜索候选课程；
/// - `GET /api/v1/course/lesson-replay`（course_id）：回放小节
///   （`sub_videos`：sub_id、录制时间、播放地址）。
///
/// 播放间直达 URL（用户实测确认）：
/// `https://classroom.zju.edu.cn/livingroom?course_id=<id>&sub_id=<sub_id>&tenant_code=112`
///
/// ## 课程匹配（经验报告·三）
///
/// - `cleanCourseName` 规整括号、剥末尾班级号；`extractCoreCourseName`
///   进一步剥教学方式修饰符（网络/线上/MOOC/研讨等）；
/// - 梯队：等级/罗马数字冲突防御（甲≠乙、I≠II 直接 false，防串课）→
///   归一化全等 → 核心课名相等 → 核心去符号子串包含（≥3）；
/// - 多教师拆分后任一交叉命中者优先锁定本班课堂。
class ClassroomService {
  ClassroomService._();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
  static const _casLoginUrl = 'https://zjuam.zju.edu.cn/cas/login';
  static const _classroomBase = 'https://classroom.zju.edu.cn';
  static const _classroomCasCallback = '$_classroomBase/api/v1/cas/login';
  static const _myCoursesUrl = '$_classroomBase/api/v1/course/my-courses';
  static const _searchUrl = '$_classroomBase/api/v1/course/search';
  static const _lessonReplayUrl = '$_classroomBase/api/v1/course/lesson-replay';

  /// Token 持久化 key（经验报告：内存 + 本地双缓存，只有 401 才重登）。
  /// 存 originalWebPageBox，退出登录清缓存时一并清掉。
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

  /// 在智云课堂里解析本课程：匹配 + 回放小节 + 最近一节。
  ///
  /// 返回 null 的三种情况调用方都应视为「不展示卡片」：我的课程/搜索里
  /// 都没有这门课（尚未上过）、没有回放小节、查找过程失败（如不在校园
  /// 网）。账号里确实存在回放小节，才说明可看。
  static Future<ClassroomMatch?> resolveCourse({
    required String courseName,
    String? teacher,
    required String? username,
    required String? password,
  }) async {
    final cacheKey = '$courseName|$teacher';
    if (_matchCache.containsKey(cacheKey)) return _matchCache[cacheKey];

    // zjuam CAS 登录偶发超时（诊断日志实测），失败后等 2 秒重试一次。
    _ClassroomSession session;
    try {
      session = await _ensureSession(username: username, password: password);
    } on Object {
      await Future<void>.delayed(const Duration(seconds: 2));
      session = await _ensureSession(username: username, password: password);
    }

    final teacherSet = _teachersOf(teacher);

    // 候选来源一：我的课程（本学期选修课列表）。
    var candidates = await _fetchMyCourses(session);
    if (candidates == null) {
      // 401：token 失效，重登一次再试（经验报告「Token 双层缓存与自愈」）。
      _forgetToken();
      session = await _ensureSession(username: username, password: password);
      candidates = await _fetchMyCourses(session) ?? const [];
    }
    var matched = _pickBest(candidates, courseName, teacherSet);

    // 候选来源二：全局搜索（多重关键词降级检索，经验报告二.4/三.4）。
    if (matched == null) {
      final keywords = <String>{
        cleanCourseName(courseName),
        extractCoreCourseName(courseName),
      }..removeWhere((k) => k.isEmpty);
      for (final keyword in keywords) {
        final found = await _searchCourses(session, keyword) ?? const [];
        matched = _pickBest(found, courseName, teacherSet);
        if (matched != null) break;
      }
    }

    if (matched == null) {
      DiagnosticLogService.instance.record(
        module: 'classroom',
        operation: 'match',
        message: '我的课程 ${candidates.length} 门与搜索均未命中「$courseName」',
      );
      _matchCache[cacheKey] = null;
      return null;
    }

    // 回放小节：有 sub_videos 才展示卡片（尚未上课/回放未生成 → 隐藏）。
    final subs = await _fetchLessonReplays(session, matched.courseId);
    if (subs == null || subs.isEmpty) {
      DiagnosticLogService.instance.record(
        module: 'classroom',
        operation: 'match',
        message: '「${matched.title}」无回放小节，隐藏入口卡片',
      );
      _matchCache[cacheKey] = null;
      return null;
    }

    DiagnosticLogService.instance.record(
      module: 'classroom',
      operation: 'match',
      message: '「$courseName」命中「${matched.title}」（course_id='
          '${matched.courseId}），${subs.length} 节回放',
    );
    final match = ClassroomMatch(
      course: matched,
      subCount: subs.length,
      latestSubId: subs.last.subId,
      latestSubTitle: subs.last.title,
    );
    _matchCache[cacheKey] = match;
    return match;
  }

  // ===== 候选课程来源 =====

  /// GET /api/v1/course/my-courses——本学期选修课；401 返回 null。
  static Future<List<ClassroomCourse>?> _fetchMyCourses(
      _ClassroomSession session) async {
    final now = DateTime.now();
    final yearStart = now.month >= DateTime.september ? now.year : now.year - 1;
    // 秋冬学期（9 月起至次年 1 月）为第一学期，春夏为第二学期。
    final termIndex =
        (now.month >= DateTime.september || now.month == 1) ? 1 : 2;
    final termId = '$yearStart-${yearStart + 1}-$termIndex';

    final attempts = <Map<String, String>>[
      {'term_id': termId, 'year': '$yearStart'},
      const {},
    ];
    for (final query in attempts) {
      final uri = Uri.parse(_myCoursesUrl).replace(queryParameters: query);
      final request = await session.httpClient.openUrl('GET', uri);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Authorization', 'Bearer ${session.token}');
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      if (response.statusCode == HttpStatus.unauthorized) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        continue; // 参数形态不对等场景：换下一组查询参数。
      }
      final payload = decodeJsonMap(body, context: '智云课堂我的课程');
      final courses = <ClassroomCourse>[];
      for (final raw in _iterableOf(payload['courses'])) {
        final course = _courseFromJson(raw);
        if (course != null) courses.add(course);
      }
      if (courses.isNotEmpty) return courses;
    }
    return const [];
  }

  /// POST /api/v1/course/search——全局搜索；401 返回 null。
  static Future<List<ClassroomCourse>?> _searchCourses(
      _ClassroomSession session, String keyword) async {
    final uri = Uri.parse(_searchUrl).replace(queryParameters: {'page': '1'});
    final request = await session.httpClient.openUrl('POST', uri);
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Authorization', 'Bearer ${session.token}');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'keyword': keyword, 'page': 1}));
    final response = await request.close().timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout(),
        );
    if (response.statusCode == HttpStatus.unauthorized) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    final payload = decodeJsonMap(body, context: '智云课堂搜索');
    final courses = <ClassroomCourse>[];
    for (final raw in _iterableOf(payload['list'])) {
      final course = _courseFromJson(raw);
      if (course != null) courses.add(course);
    }
    return courses;
  }

  /// 宽松字段抽取：course_id/id、title/name、teacher/realname/lecturer。
  static ClassroomCourse? _courseFromJson(Object? raw) {
    final map = asStringMap(raw);
    if (map == null) return null;
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
    return ClassroomCourse(
      courseId: courseId,
      title: title,
      realname: teacher,
    );
  }

  /// GET /api/v1/course/lesson-replay——回放小节；401 返回 null。
  static Future<List<ClassroomReplaySub>?> _fetchLessonReplays(
      _ClassroomSession session, int courseId) async {
    final uri = Uri.parse(_lessonReplayUrl)
        .replace(queryParameters: {'course_id': '$courseId'});
    final request = await session.httpClient.openUrl('GET', uri);
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Authorization', 'Bearer ${session.token}');
    final response = await request.close().timeout(
          const Duration(seconds: 8),
          onTimeout: () => throw requestTimeout(),
        );
    if (response.statusCode == HttpStatus.unauthorized) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    final payload = decodeJsonMap(body, context: '智云课堂回放小节');
    final subs = <ClassroomReplaySub>[];
    for (final raw in _iterableOf(payload['sub_videos'])) {
      final map = asStringMap(raw);
      if (map == null) continue;
      final subId = _asId(map['sub_id'] ?? map['id']);
      if (subId == null || subId <= 0) continue;
      subs.add(ClassroomReplaySub(
        subId: subId,
        title:
            (asString(map['sub_title']) ?? asString(map['title']) ?? '').trim(),
        recordedAt: _parseTime(map['record_time'] ??
            map['recordTime'] ??
            map['time'] ??
            map['created_at'] ??
            map['start_time']),
      ));
    }
    // 按录制时间升序（缺时间的排最前），迭代序最后一节即最近一节。
    subs.sort((a, b) {
      final at = a.recordedAt, bt = b.recordedAt;
      if (at != null && bt != null) return at.compareTo(bt);
      if (at != null) return 1;
      if (bt != null) return -1;
      return 0;
    });
    return subs;
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString().trim())?.toLocal();
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

  /// 梯队匹配 + 教师交叉校验，返回最优候选（经验报告三.2）。
  static ClassroomCourse? _pickBest(List<ClassroomCourse> candidates,
      String courseName, Set<String> teacherSet) {
    ClassroomCourse? best;
    var bestScore = -1;
    for (final candidate in candidates) {
      if (!matchesCourseName(
          courseName, candidate.title, teacherSet, candidate.realname)) {
        continue;
      }
      // 同分时教师交叉命中的优先，其次保持先到先得。
      var score = 1;
      final lecturer = _normalize(candidate.realname);
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

  /// PHP 关联数组兼容：List 直接用，Map 取 values（经验报告三.4）。
  static Iterable<Object?> _iterableOf(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }
}

/// 梯队式课程名匹配（经验报告三.2「matchesCourseName」）。
///
/// Tier 1 等级/罗马数字冲突防御（甲≠乙、I≠II 直接 false，防串课）；
/// Tier 2 归一化完全相等；Tier 3 核心课名相等；Tier 4 特殊学科（Python、
/// 大学英语分级）；Tier 5 宽松子串包含（核心词 ≥3）。[remoteTeacher]
/// 非空时做教师交叉校验：同名单任一教师命中即可，多教师拆分后比对。
bool matchesCourseName(
    String localName, String remoteName, Set<String> teacherSet,
    [String remoteTeacher = '']) {
  final cleanedLocal = cleanCourseName(localName);
  final cleanedRemote = cleanCourseName(remoteName);
  final coreLocal = extractCoreCourseName(localName);
  final coreRemote = extractCoreCourseName(remoteName);
  if (coreLocal.isEmpty || coreRemote.isEmpty) return false;

  // Tier 1：等级与罗马数字冲突防御。
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

  // Tier 4：特殊学科——大学英语分级（级别一致即视为同课）。
  if (_collegeEnglishLevel(coreLocal) != null &&
      _collegeEnglishLevel(coreLocal) == _collegeEnglishLevel(coreRemote)) {
    return true;
  }

  // Tier 5：宽松子串包含（核心词 ≥3）。
  if (coreLocal.length >= 3 &&
      (coreRemote.contains(coreLocal) || coreLocal.contains(coreRemote))) {
    return true;
  }

  // 教师交叉兜底：课名包含且任一教师命中（同名多班场景）。
  final lecturer = remoteTeacher.replaceAll(RegExp(r'\s+'), '').trim();
  if (coreLocal.length >= 3 &&
      (coreRemote.contains(coreLocal) || coreLocal.contains(coreRemote)) &&
      teacherSet.isNotEmpty &&
      lecturer.isNotEmpty &&
      teacherSet.any((t) => lecturer.contains(t) || t.contains(lecturer))) {
    return true;
  }
  return false;
}

String _stripSymbols(String input) =>
    input.replaceAll(RegExp(r'[^0-9A-Za-z\u4e00-\u9fa5]'), '');

String? _gradeTag(String name) {
  final m = RegExp(r'[([](甲|乙|丙|丁|戊)[)]').firstMatch(name);
  return m?.group(1);
}

String? _romanTag(String name) {
  final m = RegExp(r'(I{1,3}|IV|V)$').firstMatch(name.trim());
  return m?.group(1);
}

String? _collegeEnglishLevel(String name) {
  final m = RegExp(r'大学英语\s*(I{1,3}|IV|V|[1-5])').firstMatch(name);
  return m?.group(1);
}

/// 基础清洗（经验报告三.1 `cleanCourseName`）：规整括号、剥末尾班级号。
String cleanCourseName(String courseName) {
  var cleaned = courseName.trim();
  cleaned = cleaned.replaceAll('（', '(').replaceAll('）', ')');
  cleaned = cleaned.replaceAll('【', '[').replaceAll('】', ']');
  cleaned = cleaned.replaceAll(RegExp(r'[\(\[]\s*\d+\s*(班)?\s*[\)\]]$'), '');
  cleaned = cleaned.replaceAll(RegExp(r'-\d+$'), '');
  return cleaned.trim();
}

/// 深度提取核心课名（经验报告三.1 `extractCoreCourseName`）：
/// 剥荣誉/教学模式修饰符与班级号，保留等级与罗马数字。
String extractCoreCourseName(String name) {
  var s = name.trim();
  s = s.replaceAll(
      RegExp(r'[((]\s*(?:荣誉|honor)\s*[)\]]', caseSensitive: false), '');
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

/// 一次成功解析的智云课堂课程：匹配条目 + 回放小节数 + 最近一节。
class ClassroomMatch {
  final ClassroomCourse course;
  final int subCount;
  final int latestSubId;
  final String latestSubTitle;

  const ClassroomMatch({
    required this.course,
    required this.subCount,
    required this.latestSubId,
    this.latestSubTitle = '',
  });
}

/// 「我的课程」/搜索里的一条候选课程。
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

/// lesson-replay 里的一条回放小节。
class ClassroomReplaySub {
  final int subId;
  final String title;
  final DateTime? recordedAt;

  const ClassroomReplaySub({
    required this.subId,
    required this.title,
    required this.recordedAt,
  });
}

class _ClassroomSession {
  final HttpClient httpClient;
  final String token;

  const _ClassroomSession({required this.httpClient, required this.token});
}
