import 'dart:io';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/http/calendar_bundled_config.dart';
import 'package:celechron/http/calendar_config_parser.dart';
import 'package:celechron/http/data_source_status.dart';
import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/utils/tuple.dart';
import 'package:flutter/foundation.dart';

/// 获取并校验学期校历（多级回退，做法取自 Elychron）。
///
/// 远程源是上游的第三方静态站（明文 HTTP、不稳定），因此：
/// 1. 远程每 7 天才尝试一次（按「尝试」计，不是「成功」）；从未同步过的学期
///    立即尝试。窗口内直接用本地版本（已同步缓存 / 随包内置），不算降级；
/// 2. 远程抓取按候选顺序尝试（HTTPS 优先、HTTP 兜底）；
/// 3. 远程不可用或未发布时，按「同学期缓存 → 随包内置 → 本地推算」降级。
class TimeConfigService {
  static const _lastValidCacheKey = 'timeConfig_lastValid';
  static const _lastRemoteAttemptKey = 'timeConfig_lastRemoteAttempt';
  static const _remoteAttemptInterval = Duration(days: 7);

  DatabaseHelper? _db;

  set db(DatabaseHelper? db) {
    _db = db;
  }

  /// 是否该向远程检查这个学期的校历。
  bool _shouldAttemptRemote(String semesterId) {
    // 从没同步过这个学期：先抓一次（有缓存之后就不会再频繁打扰远程）。
    if (_db?.getCachedWebPage('timeConfig_$semesterId') == null) {
      return true;
    }
    // 距上次尝试不足一个窗口：本地（缓存 / 随包）完全够用。
    final lastAttempt = _db?.getCachedWebPage(_lastRemoteAttemptKey);
    final attemptedAt =
        lastAttempt == null ? null : DateTime.tryParse(lastAttempt);
    if (attemptedAt == null) return true;
    return DateTime.now().difference(attemptedAt) >= _remoteAttemptInterval;
  }

  Future<void> _markRemoteAttempted() {
    return _db?.setCachedWebPage(
            _lastRemoteAttemptKey, DateTime.now().toUtc().toIso8601String()) ??
        Future<void>.value();
  }

  Future<Tuple3<Exception?, String?, DataSourceStatus>> getConfig(
      HttpClient httpClient, String semesterId) async {
    final context = '校历接口（学年学期 $semesterId，请求类型 配置）';

    // 未到远程检查窗口：本地版本即权威，不算降级。
    if (!_shouldAttemptRemote(semesterId)) {
      final fallback = await _fallbackConfig(semesterId, context);
      DiagnosticLogService.instance.record(
        module: '校历',
        operation: semesterId,
        cacheUsed: fallback.status == DataSourceStatus.bundled ||
            fallback.status == DataSourceStatus.cache,
        message: '未到远程检查窗口（${_remoteAttemptInterval.inDays} 天），'
            '${fallback.status.label}',
      );
      return Tuple3(null, fallback.config, fallback.status);
    }

    // 远程抓取：候选顺序 HTTPS 优先、HTTP 兜底。
    Object? lastError;
    StackTrace? lastStackTrace;
    Uri? lastUri;
    await _markRemoteAttempted();
    for (final uri in calendarConfigUrisForSemester(semesterId)) {
      final outcome = await _fetchRemote(httpClient, uri, semesterId, context);
      if (outcome.body != null) {
        return Tuple3(null, outcome.body, DataSourceStatus.live);
      }
      if (outcome.unpublished) {
        // 未发布是内容态而非网络态，不再尝试其它候选，直接降级。
        final fallback = await _fallbackConfig(semesterId, context);
        return Tuple3(
          CalendarConfigUnavailableException(
            details: outcome.details ?? 'HTTP ${outcome.statusCode}',
          ),
          fallback.config,
          fallback.status,
        );
      }
      lastError = outcome.error;
      lastStackTrace = outcome.stackTrace;
      lastUri = uri;
    }

    // 所有候选都失败：三级回退，并按降级标记给上层。
    final fallback = await _fallbackConfig(semesterId, context);
    final exception = lastError == null
        ? ExceptionWithMessage('$context：远程请求失败')
        : exceptionFrom(
            lastError,
            context: context,
            requestUri: lastUri,
            stackTrace: lastStackTrace,
          );
    DiagnosticLogService.instance.record(
      level: CelechronLogLevel.warning,
      module: '校历',
      operation: semesterId,
      requestUri: lastUri,
      cacheUsed: fallback.status == DataSourceStatus.bundled ||
          fallback.status == DataSourceStatus.cache,
      message: '远程请求失败（全部候选），${fallback.status.label}；'
          '缓存时间=${fallback.cachedAt ?? '<无>'}',
      error: lastError,
      stackTrace: lastStackTrace,
    );
    return Tuple3(exception, fallback.config, fallback.status);
  }

  /// 从单个候选 URL 抓取并（成功时）落缓存。
  Future<_RemoteFetchOutcome> _fetchRemote(
    HttpClient httpClient,
    Uri uri,
    String semesterId,
    String context,
  ) async {
    final key = calendarObjectKeyForSemester(semesterId);
    if (kDebugMode) {
      debugPrint('校历请求：URL=$uri，OSS Key=$key');
    }
    try {
      final request = await httpClient.getUrl(uri).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      request.followRedirects = false;
      final response = await request.close().timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw requestTimeout(),
          );
      final body = await readResponseBody(response, context: context);
      final contentType =
          response.headers.value(HttpHeaders.contentTypeHeader) ?? '<缺失>';
      final noSuchKey = response.statusCode == HttpStatus.notFound ||
          body.contains('<Code>NoSuchKey</Code>');
      if (noSuchKey) {
        // 未发布与网络故障分开记录；前者是未来学期的正常状态。
        DiagnosticLogService.instance.record(
          level: CelechronLogLevel.info,
          module: '校历',
          operation: semesterId,
          requestUri: uri,
          statusCode: response.statusCode,
          contentType: contentType,
          message: '远程配置未发布',
        );
        return _RemoteFetchOutcome(
          unpublished: true,
          statusCode: response.statusCode,
          details: [
            '接口：$context',
            '请求：${sanitizedRequestUri(uri)}',
            'OSS Key：$key',
            'HTTP 状态码：${response.statusCode}',
            'Content-Type：$contentType',
            '原始异常类型：NoSuchKey',
            '执行过重新登录：否',
            '执行过重试：否',
            '响应摘要：${responseSummary(body)}',
          ].join('\n'),
        );
      }

      validateResponse(
        response: response,
        body: body,
        context: context,
        expectJson: true,
        requestUri: uri,
      );
      decodeAndValidateCalendarConfig(
        body,
        context: '$context；HTTP ${response.statusCode}',
      );
      // 成功才写缓存；与上一份比对，把「更新了什么」留在诊断日志里。
      final previous = _db?.getCachedWebPage('timeConfig_$semesterId');
      final changed = previous == null || previous != body;
      await Future.wait([
        // 精确学期缓存用于恢复本学期；最后有效配置只提供节次时间模板。
        _db?.setCachedWebPage('timeConfig_$semesterId', body) ??
            Future<void>.value(),
        _db?.setCachedWebPage(_lastValidCacheKey, body) ?? Future<void>.value(),
        _db?.setCachedWebPage(
              'timeConfig_timestamp_$semesterId',
              DateTime.now().toUtc().toIso8601String(),
            ) ??
            Future<void>.value(),
      ]);
      DiagnosticLogService.instance.record(
        module: '校历',
        operation: semesterId,
        requestUri: uri,
        statusCode: response.statusCode,
        contentType: contentType,
        message: changed ? '远程配置已更新' : '远程配置无变化',
      );
      return _RemoteFetchOutcome(body: body);
    } on Object catch (error, stackTrace) {
      return _RemoteFetchOutcome(error: error, stackTrace: stackTrace);
    }
  }

  /// 三级回退：同学期缓存 → 随包内置 → 本地推算。
  Future<_CalendarFallback> _fallbackConfig(
      String semesterId, String context) async {
    // 1) 精确缓存优先，因为其中的日期和调休只适用于对应学期。
    final exactCache = _db?.getCachedWebPage('timeConfig_$semesterId');
    if (exactCache != null) {
      try {
        decodeAndValidateCalendarConfig(
          exactCache,
          context: '$context 本地缓存',
        );
        return _CalendarFallback(
          exactCache,
          DataSourceStatus.cache,
          cachedAt: _db?.getCachedWebPage('timeConfig_timestamp_$semesterId'),
        );
      } on Object catch (error, stackTrace) {
        DiagnosticLogService.instance.record(
          level: CelechronLogLevel.warning,
          module: '校历',
          operation: 'readExactCache',
          cacheUsed: false,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // 2) 随包内置的那一份：离线也有、首次安装就有。
    final bundled = await BundledCalendarConfig.load(semesterId);
    if (bundled != null) {
      try {
        decodeAndValidateCalendarConfig(
          bundled,
          context: '$context 随包内置',
        );
        return _CalendarFallback(
          bundled,
          DataSourceStatus.bundled,
        );
      } on Object catch (error, stackTrace) {
        DiagnosticLogService.instance.record(
          level: CelechronLogLevel.warning,
          module: '校历',
          operation: 'readBundled',
          cacheUsed: false,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // 3) 其它学期缓存不能复用日期，只提取经过校验的 sessionTime 当模板。
    Map<String, dynamic>? template;
    final lastValid = _db?.getCachedWebPage(_lastValidCacheKey);
    if (lastValid != null) {
      try {
        template = decodeAndValidateCalendarConfig(
          lastValid,
          context: '$context 上一份有效缓存',
        );
      } on Object catch (error, stackTrace) {
        DiagnosticLogService.instance.record(
          level: CelechronLogLevel.warning,
          module: '校历',
          operation: 'readTemplateCache',
          cacheUsed: false,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return _CalendarFallback(
      buildSafeDefaultCalendarConfig(
        semesterId,
        template: template,
      ),
      DataSourceStatus.fallback,
    );
  }
}

class _RemoteFetchOutcome {
  final String? body;
  final bool unpublished;
  final int? statusCode;
  final String? details;
  final Object? error;
  final StackTrace? stackTrace;

  const _RemoteFetchOutcome({
    this.body,
    this.unpublished = false,
    this.statusCode,
    this.details,
    this.error,
    this.stackTrace,
  });
}

class _CalendarFallback {
  final String config;
  final DataSourceStatus status;
  final String? cachedAt;

  const _CalendarFallback(this.config, this.status, {this.cachedAt});
}
