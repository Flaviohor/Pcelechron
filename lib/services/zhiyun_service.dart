import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/http/zjuServices/zjuam.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

/// 智云课堂（Zhiyun, classroom.zju.edu.cn）服务。
///
/// 登录与数据管线**完整移植自 Helechron 项目**（github.com/Kepler16f/
/// Helechron，lib/services/zhiyun_service.dart，2026-10 实测可用）：
///
/// ## 登录（tgmedia 入口 + 扁平 Cookie 罐）
///
/// 1. `ZjuAm.getSsoCookie` 取得 iPlanetDirectoryPro；
/// 2. 从 tgmedia 认证入口起（index.php?r=auth/login&auType=cmc&
///    tenant_code=112&forward=…classroom…），跟随最多 12 跳 302，逐跳
///    带/收 Cookie——**Cookie 罐按 name|domain 扁平存**（不做 path 维度
///    划分，避免同名多 path 的旧 Cookie 混入链路破坏会话）；
/// 3. `_token` 从 Cookie（含 PHP 序列化形态）、URL query 参数三处提取，
///    **不限定域名**（tgmedia 域下发的 _token 可直接作 classroom API 的
///    Bearer）；
/// 4. `/userapi/v1/infosimple` 校验并拉取学号与用户 ID。
///
/// 历史教训：zjuam 直连 CAS 的 service=classroom 已被服务端拒绝（no_auth/
/// 500），identity Keycloak 迁移当前未接入 classroom（400 客户端未找到），
/// 因此此 tgmedia 链是当前唯一可用路径。
///
/// ## 数据接口（Helechron 同款）
///
/// - `courseapi/v3/multi-search/get-course-detail?course_id=`（sub_list）；
/// - `courseapi/v2/course/catalogue?course_id=`（备用目录）；
/// - `pptnote/v1/searchlist?tenant_id=112&title=&realname=`（在线检索）。
///
/// 所有请求带 `Authorization: Bearer <token>` 与
/// `Cookie: _token=<token>; token=<token>`（Helechron 实测必需）。
class ZhiyunService {
  ZhiyunService._();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36';

  static const _zhiyunBase = 'https://classroom.zju.edu.cn';
  static const _tenantCode = '112';

  /// tgmedia 认证入口：当前唯一可用的智云 SSO 起点。
  static const _ssoEntryUrl =
      'https://tgmedia.cmc.zju.edu.cn/index.php?r=auth/login&auType=cmc'
      '&tenant_code=112&forward=https%3A%2F%2Fclassroom.zju.edu.cn%2F';

  static const _tokenKey = 'zhiyun_token';
  static const _accountKey = 'zhiyun_account';
  static const _userIdKey = 'zhiyun_user_id';

  /// Token 双层缓存：内存静态变量 + optionsBox 持久化。
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

  static void _reloginZhiyun() {
    _cachedZhiyunToken = null;
    _db?.setCachedWebPage(_tokenKey, '');
  }

  /// tgmedia 入口全链跟随登录（Helechron 算法移植）。
  static Future<String> _loginZhiyun(String username, String password) async {
    final ssoCookie = await ZjuAm.getSsoCookie(_client, username, password);
    if (ssoCookie == null) {
      throw const ZhiyunException('统一认证未登录');
    }

    // 扁平 Cookie 罐：按 name|domain 存，不做 path 维度划分——同名多 path
    // 的旧 Cookie 混入链路会破坏 CAS 会话（此前自研链失败的教训之一）。
    final cookieJar = <String, Cookie>{};

    void storeCookie(Cookie cookie, Uri source) {
      final domain = (cookie.domain == null || cookie.domain!.trim().isEmpty
              ? source.host
              : cookie.domain!)
          .toLowerCase()
          .replaceFirst(RegExp(r'^\.'), '');
      cookie.path = '/';
      cookieJar['${cookie.name}|$domain'] = cookie;
    }

    List<Cookie> cookiesFor(Uri uri) {
      final host = uri.host.toLowerCase();
      return cookieJar.values.where((cookie) {
        final domain = (cookie.domain ?? '')
            .toLowerCase()
            .replaceFirst(RegExp(r'^\.'), '');
        return domain.isEmpty || host == domain || host.endsWith('.$domain');
      }).toList();
    }

    final trustedSso = Cookie(ssoCookie.name, ssoCookie.value)
      ..domain = 'zju.edu.cn'
      ..path = '/';
    storeCookie(trustedSso, Uri.parse('https://zjuam.zju.edu.cn/'));

    // 兜底（浏览器同款）：链路与 Helechron 一致，但若中途踢到 zjuam CAS
    // 登录表单（authorize 拿不到 TGT 会话时会发生，getSsoCookie 的
    // JSESSIONID 在 ZjuAm 内部被丢弃），就就着当前表单、当前会话提交
    // 密码——Cookie 只带 zjuam 精确域的（JSESSIONID/_csrf），排除父域
    // iPlanet（1.3.5.19 实测带上 iPlanet 提交会被 CAS 以 200 拒绝）。
    var current = Uri.parse(_ssoEntryUrl);
    final stopwatch = Stopwatch()..start();
    String? token;
    var formSubmits = 0;

    for (var hop = 0; hop < 12; hop++) {
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
      request.cookies.addAll(cookiesFor(current));
      final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );

      for (final cookie in response.cookies) {
        storeCookie(cookie, current);
        final String decoded;
        try {
          decoded = Uri.decodeComponent(cookie.value);
        } on ArgumentError {
          continue;
        }
        // 1) PHP 序列化形态：{i:…;s:…:"_token";…s:…:"<token>";}
        final match = RegExp(r'\{i:\d+;s:\d+:"_token";i:\d+;s:\d+:"([^"]+)";\}')
            .firstMatch(decoded);
        if (match != null) {
          token = match.group(1);
        }
        // 2) 直接以 _token / token 命名的 Cookie
        if (token == null && (cookie.name == '_token' || cookie.name == 'token')) {
          if (decoded.contains('_token')) {
            token = RegExp(r'"([^"]{20,})"').firstMatch(decoded)?.group(1) ??
                cookie.value;
          } else {
            token = cookie.value;
          }
        }
      }

      // 3) URL query 参数里的 token / _token
      if (current.queryParameters.containsKey('token')) {
        token = current.queryParameters['token'];
      }
      if (current.queryParameters.containsKey('_token')) {
        token = current.queryParameters['_token'];
      }

      final location = response.headers.value(HttpHeaders.locationHeader);
      final body = await _readBodyWithTimeout(response);
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'loginHop',
        requestUri: current,
        statusCode: response.statusCode,
        location: location,
        message: '登录第${hop + 1}跳'
            '${token != null ? '（已获得 _token）' : ''}',
      );

      if (isHttpRedirectStatus(response.statusCode) &&
          location != null &&
          location.isNotEmpty) {
        current = current.resolve(location);
        if (current.queryParameters.containsKey('token')) {
          token = current.queryParameters['token'];
        }
        if (current.queryParameters.containsKey('_token')) {
          token = current.queryParameters['_token'];
        }
        continue;
      }

      // 落在 zjuam CAS 登录表单（200 + execution）：authorize 找不到 TGT
      // 会话时踢到这里——浏览器同款动作是「就着当前表单、当前会话提交
      // 密码」。两个关键细节（1.3.5.26 教训，POST 被 302 回表单）：
      // 1) POST 到表单 action（/cas/login 纯路径，**不带 query**）——
      //    service 由服务端会话（execution）保管，带上 ?service= 反而
      //    会被 CAS 以 302 回踢；
      // 2) 提交表单里**全部**隐藏字段（execution/_eventId/ys 等），不是
      //    只发 execution——漏掉 ys 等字段同样被拒。
      // Cookie 只带 zjuam 精确域（该会话的 JSESSIONID/_csrf），排除父域
      // iPlanet（1.3.5.19 实测带上会被 CAS 拒）。
      if (formSubmits < 2 &&
          response.statusCode == HttpStatus.ok &&
          current.host == 'zjuam.zju.edu.cn' &&
          current.path.startsWith('/cas/login') &&
          body.contains('name="execution"')) {
        formSubmits++;
        // 提取表单全部隐藏字段（浏览器同款提交）。
        final hiddenFields = <String, String>{};
        for (final tagMatch
            in RegExp(r'<input[^>]*type="hidden"[^>]*>').allMatches(body)) {
          final tag = tagMatch.group(0) ?? '';
          final name = RegExp(r'name="([^"]+)"').firstMatch(tag)?.group(1);
          final value = RegExp(r'value="([^"]*)"').firstMatch(tag)?.group(1);
          if (name != null && name.isNotEmpty) {
            hiddenFields[name] = value ?? '';
          }
        }
        final execution = hiddenFields['execution'];
        DiagnosticLogService.instance.record(
          module: 'zhiyun',
          operation: 'loginFormSubmit',
          requestUri: current,
          message: '在 CAS 登录表单提交密码（第 $formSubmits 次，'
              '隐藏字段：${hiddenFields.keys.join('、')}）',
        );
        if (execution != null && execution.isNotEmpty) {
          try {
            final pwdEnc = await _encryptZjuamPassword(password);
            // POST 到表单 action（纯路径，不带 query）。
            final formAction =
                Uri.https('zjuam.zju.edu.cn', '/cas/login');
            final formRequest = await _client.postUrl(formAction).timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => throw const ZhiyunException('统一认证请求超时'),
                );
            formRequest.followRedirects = false;
            formRequest.headers.set('User-Agent', _userAgent);
            formRequest.headers.contentType = ContentType(
                'application', 'x-www-form-urlencoded', charset: 'utf-8');
            for (final cookie in cookieJar.values) {
              if (cookie.domain == 'zjuam.zju.edu.cn') {
                formRequest.cookies.add(cookie);
              }
            }
            // 全部隐藏字段 + 用户名/密码/rememberMe（浏览器同款）。
            final fields = Map<String, String>.from(hiddenFields);
            fields['username'] = username;
            fields['password'] = pwdEnc;
            fields['rememberMe'] = 'true';
            fields['_eventId'] ??= 'submit';
            formRequest.add(utf8.encode(Uri(queryParameters: fields).query));
            final formResponse = await formRequest.close().timeout(
                  const Duration(seconds: 10),
                  onTimeout: () => throw const ZhiyunException('统一认证请求超时'),
                );
            for (final cookie in formResponse.cookies) {
              storeCookie(cookie, current);
            }
            final formLocation =
                formResponse.headers.value(HttpHeaders.locationHeader);
            await _readBodyWithTimeout(formResponse);
            DiagnosticLogService.instance.record(
              module: 'zhiyun',
              operation: 'loginFormSubmit',
              requestUri: formAction,
              statusCode: formResponse.statusCode,
              location: formLocation,
              message: '表单提交响应（第 $formSubmits 次）',
            );
            if (isHttpRedirectStatus(formResponse.statusCode) &&
                formLocation != null &&
                formLocation.isNotEmpty) {
              current = current.resolve(formLocation);
              if (current.queryParameters.containsKey('token')) {
                token = current.queryParameters['token'];
              }
              if (current.queryParameters.containsKey('_token')) {
                token = current.queryParameters['_token'];
              }
              continue;
            }
            // 200/其它：密码被拒或表单重出——回到循环顶部重新 GET 当前
            // URL 再试一次（formSubmits 已限 2 次）。
            continue;
          } on ZhiyunException {
            // 加密/提交失败：落回正常流程，由 loginFailed 带停留点。
          }
        }
      }
      break;
    }

    if (token == null || token.isEmpty) {
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'loginFailed',
        requestUri: current,
        message: '链路结束仍未获得 _token',
      );
      throw ZhiyunException('智云课堂登录未获得 _token（链路停留在 ${current.host}）');
    }

    // 校验 token 并拉取账号信息（失败不阻塞——token 可能仍可用）。
    await _verifyToken(token);
    return token;
  }

  static Future<void> _verifyToken(String token) async {
    try {
      final infoUri = Uri.parse('$_zhiyunBase/userapi/v1/infosimple');
      final infoReq = await _client.getUrl(infoUri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      infoReq.headers.set('Authorization', 'Bearer $token');
      infoReq.headers.set('Cookie', '_token=$token; token=$token');
      infoReq.headers.set('User-Agent', _userAgent);
      final infoResp = await infoReq.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
          );
      if (infoResp.statusCode == 200) {
        final body = await _readBodyWithTimeout(infoResp);
        final json = decodeJsonMap(body, context: '智云用户信息');
        final params = asStringMap(json['params']);
        final account = asString(params?['account']);
        if (account != null && account.isNotEmpty) {
          _db?.setCachedWebPage(_accountKey, account);
        }
        final userId = asString(params?['id']);
        if (userId != null && userId.isNotEmpty) {
          _db?.setCachedWebPage(_userIdKey, userId);
        }
      } else {
        await infoResp.drain<void>();
      }
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'zhiyun',
        operation: 'verifyToken',
        message: '智云 Token 校验失败（不阻塞使用）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  // ===== 基础请求：Bearer + _token Cookie 头 =====

  static Future<String> _readBodyWithTimeout(HttpClientResponse response) {
    return response.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂响应读取超时'),
        );
  }

  /// 取统一认证 RSA 公钥并加密密码（浏览器同款），返回 128 位十六进制
  /// 密文。公钥接口无会话依赖，表单重认证与带 service 登录共用。
  static Future<String> _encryptZjuamPassword(String password) async {
    final request = await _client
        .getUrl(Uri.parse('https://zjuam.zju.edu.cn/cas/v2/getPubKey'))
        .timeout(const Duration(seconds: 8),
            onTimeout: () => throw const ZhiyunException('统一认证请求超时'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 8),
        onTimeout: () => throw const ZhiyunException('统一认证请求超时'));
    final body = await _readBodyWithTimeout(response);
    final publicKey = decodeJsonMap(
        body, context: '统一认证 RSA 公钥；HTTP ${response.statusCode}');
    final modulusStr = asString(publicKey['modulus']);
    final exponentStr = asString(publicKey['exponent']);
    if (modulusStr == null || exponentStr == null) {
      throw ZhiyunException(
          '统一认证 RSA 公钥字段缺失；响应摘要：${responseSummary(body)}');
    }
    try {
      final modInt = BigInt.parse(modulusStr, radix: 16);
      final expInt = BigInt.parse(exponentStr, radix: 16);
      final pwdInt = BigInt.parse(
          utf8.encode(password).map((e) => e.toRadixString(16)).join(),
          radix: 16);
      return pwdInt.modPow(expInt, modInt).toRadixString(16).padLeft(128, '0');
    } on Object {
      throw const ZhiyunException('统一认证：密码加密失败');
    }
  }

  static Future<Map<String, dynamic>> _authedJson(
      String token, Uri uri) async {
    final request = await _client.getUrl(uri).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
        );
    request.followRedirects = true;
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Cookie', '_token=$token; token=$token');
    final response = await request.close().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw const ZhiyunException('智云课堂请求超时'),
        );
    final body = await _readBodyWithTimeout(response);
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const _ZhiyunUnauthorized();
    }
    return decodeJsonMap(body, context: '智云课堂接口 $uri');
  }

  // ===== 数据源（Helechron 同款） =====

  /// 课节目录：优先 v3 get-course-detail 的 sub_list，备用 v2 catalogue。
  static Future<List<ZhiyunSub>> _fetchCatalogue(
      String token, int courseId) async {
    final account = _db?.getCachedWebPage(_accountKey) ?? '';
    try {
      final detailUri = Uri.parse(
              '$_zhiyunBase/courseapi/v3/multi-search/get-course-detail')
          .replace(queryParameters: {
        'course_id': courseId.toString(),
        if (account.isNotEmpty) 'student': account,
      });
      final json = await _authedJson(token, detailUri);
      final ok = json['code'] == 0 ||
          json['code'] == '0' ||
          json['success'] == true;
      if (ok) {
        final data =
            asStringMap(json['data']) ?? asStringMap(json['result']);
        final subListMap = data?['sub_list'];
        final items = <Map<String, dynamic>>[];
        if (subListMap is Map) {
          _extractSubList(subListMap, items);
        } else if (data?['list'] is List) {
          for (final item in data!['list'] as List) {
            final map = asStringMap(item);
            if (map != null) items.add(map);
          }
        }
        final subs = _subsFromItems(items);
        if (subs.isNotEmpty) return subs;
      }
    } on _ZhiyunUnauthorized {
      rethrow;
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'zhiyun',
        operation: 'catalogueV3',
        message: 'v3 课程详情失败，尝试 v2 目录',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final catalogueUri =
        Uri.parse('$_zhiyunBase/courseapi/v2/course/catalogue')
            .replace(queryParameters: {'course_id': courseId.toString()});
    final json2 = await _authedJson(token, catalogueUri);
    final result = asStringMap(json2['result']);
    final rawData = result?['data'] ?? json2['data'] ?? json2['list'];
    final items = <Map<String, dynamic>>[];
    for (final raw in _iterableOf(rawData)) {
      final map = asStringMap(raw);
      if (map != null) items.add(map);
    }
    return _subsFromItems(items);
  }

  /// 在线检索课程（pptnote searchlist；教师/无教师两轮降级）。
  static Future<ZhiyunCourse?> _searchCourse(
      String token, String courseName, String? teacher) async {
    final account = _db?.getCachedWebPage(_accountKey) ?? '';
    final userId = _db?.getCachedWebPage(_userIdKey) ?? '';
    final cleaned = cleanCourseName(courseName);
    final coreName = extractCoreCourseName(courseName);
    final titleCandidates = <String>[cleaned];
    if (coreName.isNotEmpty && coreName != cleaned) {
      titleCandidates.add(coreName);
    }

    // 智云 realname 参数不支持多教师拼接，取第一个。
    String? singleTeacher;
    final teacherSet = _teachersOf(teacher);
    if (teacherSet.isNotEmpty) singleTeacher = teacherSet.first;

    for (final titleKeyword in titleCandidates) {
      final teacherCandidates = <String?>[
        if (singleTeacher != null && singleTeacher.isNotEmpty) singleTeacher,
        null,
      ];
      for (final candidateTeacher in teacherCandidates) {
        final uri = Uri.parse('$_zhiyunBase/pptnote/v1/searchlist')
            .replace(queryParameters: {
          'tenant_id': _tenantCode,
          'user_id': userId,
          'user_name': account,
          'page': '1',
          'per_page': '16',
          'title': titleKeyword,
          if (candidateTeacher != null && candidateTeacher.isNotEmpty)
            'realname': candidateTeacher,
          'trans': '',
          'tenant_code': _tenantCode,
          'randomKey': DateTime.now().millisecondsSinceEpoch.toString(),
        });
        final json = await _authedJson(token, uri);
        final total = asStringMap(json['total']);
        final list = asDynamicList(total?['list']) ?? const [];
        for (final item in list) {
          final map = asStringMap(item);
          if (map == null) continue;
          final courseId = _asId(map['course_id'] ?? map['id']);
          if (courseId == null || courseId <= 0) continue;
          final title = asString(map['title']) ?? '';
          final itemTeacher = asString(map['realname']) ?? '';
          if (!matchesCourseName(courseName, title, teacherSet, itemTeacher)) {
            continue;
          }
          return ZhiyunCourse(
            courseId: courseId,
            title: title,
            realname: itemTeacher,
          );
        }
      }
    }
    return null;
  }

  /// sub_list 是四层嵌套 Map（年 → 月 → 周 → 课节列表）。
  static void _extractSubList(
      Map subListMap, List<Map<String, dynamic>> target) {
    for (final yearVal in subListMap.values) {
      if (yearVal is Map) {
        for (final monthVal in yearVal.values) {
          if (monthVal is Map) {
            for (final weekVal in monthVal.values) {
              if (weekVal is List) {
                for (final sub in weekVal) {
                  final map = asStringMap(sub);
                  if (map != null) target.add(map);
                }
              }
            }
          }
        }
      }
    }
  }

  /// 课节列表 → ZhiyunSub（按录制时间升序，末位即最近一节）。
  static List<ZhiyunSub> _subsFromItems(List<Map<String, dynamic>> items) {
    final subs = <ZhiyunSub>[];
    for (final map in items) {
      final subId = _asId(map['sub_id'] ?? map['id']);
      if (subId == null || subId <= 0) continue;
      final title =
          (asString(map['title']) ?? asString(map['sub_title']) ?? '').trim();
      DateTime? recordedAt;
      final startAt = int.tryParse(asString(map['start_at']) ?? '');
      if (startAt != null && startAt > 0) {
        recordedAt = DateTime.fromMillisecondsSinceEpoch(
            startAt > 100000000000 ? startAt : startAt * 1000);
      } else {
        recordedAt = DateTime.tryParse(asString(map['date']) ?? '') ??
            DateTime.tryParse(asString(map['video_date']) ?? '');
      }
      subs.add(ZhiyunSub(subId: subId, title: title, recordedAt: recordedAt));
    }
    subs.sort((a, b) {
      final at = a.recordedAt, bt = b.recordedAt;
      if (at != null && bt != null) return at.compareTo(bt);
      if (at != null) return 1;
      if (bt != null) return -1;
      return 0;
    });
    return subs;
  }

  /// 多态容器兼容：List 直接用，Map 取 values。
  static Iterable<Object?> _iterableOf(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map) return raw.values;
    return const [];
  }

  static int? _asId(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static Set<String> _teachersOf(String? teacher) {
    if (teacher == null || teacher.trim().isEmpty) return const {};
    return teacher
        .split(RegExp(r'[,，/、;；\s+]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  // ===== 对卡片暴露的解析管线 =====

  /// 解析课程 → 智云课节（直达参数）。
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
        try {
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
        } on ZhiyunException catch (error) {
          return ZhiyunResolve.error(error.message);
        }
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

    try {
      return await _resolveWithToken(token, courseName, teacher);
    } on _ZhiyunUnauthorized {
      // token 失效：清缓存重登一次后重放。
      _reloginZhiyun();
      try {
        final fresh = await _getToken(username: username, password: password);
        return await _resolveWithToken(fresh, courseName, teacher);
      } on ZhiyunException catch (error) {
        return ZhiyunResolve.error(error.message);
      }
    } on ZhiyunException catch (error) {
      return ZhiyunResolve.error(error.message);
    }
  }

  static Future<ZhiyunResolve> _resolveWithToken(
      String token, String courseName, String? teacher) async {
    final matched = await _searchCourse(token, courseName, teacher);
    if (matched == null) {
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'match',
        message: '在线检索未命中「$courseName」',
      );
      return const ZhiyunResolve.notMatched();
    }

    final subs = await _fetchCatalogue(token, matched.courseId);
    if (subs.isEmpty) {
      return const ZhiyunResolve.notMatched(); // 没上/没生成回放 → 隐藏
    }

    final bindingKey = _bindingKey(courseName, teacher);
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

  /// 直达 URL（播放间拼接规范）。
  static String livingroomUrl(int courseId, int subId) =>
      'https://classroom.zju.edu.cn/livingroom?course_id=$courseId'
      '&sub_id=$subId&tenant_code=$_tenantCode';
}

class _ZhiyunUnauthorized implements Exception {
  const _ZhiyunUnauthorized();
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

/// 在线检索里的一条候选课程。
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

// ===== 课程名称清洗与梯队匹配（Helechron 同款） =====

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

/// 荣誉课程（H）标记识别（防串课预留）。
bool isHonorsCourse(String name) =>
    RegExp(r'[([]\s*(?:H|荣誉)\s*[)\]]', caseSensitive: false).hasMatch(name);
