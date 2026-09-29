import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/model/option.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/services/notification_service.dart';

/// DDL 精确提醒：把即将到期的作业换算成**系统级定时通知**（zonedSchedule）。
///
/// Windows / macOS 由操作系统在指定时刻触发，应用没有运行也会弹——补上
/// 「后台刷新轮询」只覆盖应用存活期间的缺口。提前量：截止前 1 小时和
/// 截止前 10 分钟各一条；只排未来 7 天内到期的 DDL。
///
/// 每次重排都先按登记表取消旧定时再排新的（登记表存 Hive，跨启动有效）；
/// 通知 id 由 uid+提前量经 md5 确定性生成，避免同一作业重复排程。
class DdlScheduleService {
  DdlScheduleService._();

  static const _registryKey = 'ddlScheduledNotificationIds';
  static const _lookahead = Duration(days: 7);
  static const _offsets = <Duration>[Duration(hours: 1), Duration(minutes: 10)];
  static bool _tzInitialized = false;

  /// 确定性通知 id（31 位非负数，跨重启稳定）。
  static int _idFor(String uid, Duration offset) {
    final digest =
        md5.convert(utf8.encode('ddl-$uid-${offset.inMinutes}')).bytes;
    final raw =
        (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
    return raw & 0x7FFFFFFF;
  }

  /// 按最新作业列表重排全部精确提醒。
  ///
  /// 「推送作业截止提醒」开关关闭时等价于清空全部定时；作业列表为空
  /// （如退出登录）时也只做清理。
  static Future<void> reschedule(List<Todo> todos) async {
    var enabled = true;
    try {
      enabled = Get.find<Option>(tag: 'option').pushOnDdlReminder.value;
    } on Object {/* 选项未注册时按开启处理 */}

    try {
      await NotificationService.ensureInitialized();
      final db = Get.find<DatabaseHelper>(tag: 'db');

      // 取消上一轮排程的全部定时。
      final registry = db.getCachedWebPage(_registryKey);
      final oldIds = (registry == null
              ? const []
              : (jsonDecode(registry) as List? ?? const []))
          .map((e) => e is int ? e : int.tryParse('$e'))
          .whereType<int>();
      for (final id in oldIds) {
        try {
          await NotificationService.plugin.cancel(id: id);
        } on Object {/* 单条取消失败不影响其余 */}
      }

      final newIds = <int>[];
      if (enabled && (Platform.isWindows || Platform.isMacOS)) {
        final now = DateTime.now();
        final upcoming = todos.where((t) =>
            t.endTime != null &&
            t.endTime!.isAfter(now) &&
            t.endTime!.isBefore(now.add(_lookahead)));
        for (final todo in upcoming) {
          for (final offset in _offsets) {
            final fireAt = todo.endTime!.subtract(offset);
            if (!fireAt.isAfter(now)) continue;
            final id = _idFor(todo.id, offset);
            try {
              await NotificationService.plugin.zonedSchedule(
                id: id,
                title: '作业即将截止',
                body: '「${todo.course}」的「${todo.name}」将于'
                    '${offset.inMinutes >= 60 ? '1 小时' : '${offset.inMinutes} 分钟'}后截止',
                scheduledDate: _tz(fireAt),
                notificationDetails: NotificationService.ddlReminderDetails,
                androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              );
              newIds.add(id);
            } on Object catch (error, stackTrace) {
              DiagnosticLogService.instance.record(
                level: CelechronLogLevel.warning,
                module: 'ddlSchedule',
                operation: 'scheduleOne',
                message: '排程「${todo.name}」的提醒失败',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }
      }
      await db.setCachedWebPage(_registryKey, jsonEncode(newIds));
      DiagnosticLogService.instance.record(
        module: 'ddlSchedule',
        operation: 'reschedule',
        message: enabled
            ? '已排程 ${newIds.length} 条精确 DDL 提醒（共 ${todos.length} 条作业）'
            : '提醒开关已关闭，清空全部定时 DDL 提醒',
      );
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'ddlSchedule',
        operation: 'reschedule',
        message: '精确 DDL 提醒重排失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// zonedSchedule 只接受 TZDateTime；统一用 UTC 表示时刻（内部按时间戳触发，
  /// 与时区表达无关）。
  static tz.TZDateTime _tz(DateTime dateTime) {
    if (!_tzInitialized) {
      tzdata.initializeTimeZones();
      _tzInitialized = true;
    }
    return tz.TZDateTime.from(dateTime, tz.UTC);
  }
}
