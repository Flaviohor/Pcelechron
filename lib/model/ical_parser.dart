import 'package:uuid/uuid.dart';

import 'task.dart';

/// iCal (RFC 5545) VEVENT 的轻量解析器，用于把外部日历文件导入为「日程」。
///
/// 支持：DTSTART / DTEND（本地时间、UTC、VALUE=DATE 全天）、SUMMARY、
/// LOCATION、DESCRIPTION、UID、RRULE（FREQ/INTERVAL/COUNT/UNTIL 的四种基础
/// 频率）。BYDAY 等复杂规则无法映射到 Task 的重复模型，按单次日程导入。
class IcalParser {
  /// 展开折行（续行以空格或制表符开头），拆出全部 VEVENT 属性。
  static List<Map<String, IcalProp>> parseEvents(String raw) {
    final unfolded = _unfold(raw);
    final events = <Map<String, IcalProp>>[];
    Map<String, IcalProp>? current;
    for (final line in unfolded) {
      if (line == 'BEGIN:VEVENT') {
        current = {};
        continue;
      }
      if (line == 'END:VEVENT') {
        if (current != null && current.isNotEmpty) events.add(current);
        current = null;
        continue;
      }
      if (current == null) continue;
      final prop = _parseProp(line);
      if (prop != null) current[prop.name.toUpperCase()] = prop;
    }
    return events;
  }

  /// 把 VEVENT 转成一个或多个固定日程；解析失败返回空列表。
  static List<Task> eventToTasks(Map<String, IcalProp> event) {
    final start = _parseDateTime(event['DTSTART']);
    final end = _parseDateTime(event['DTEND']);
    if (start == null) return const [];
    // 无 DTEND 时按全天/1 小时估算（RFC 允许省略）。
    final effectiveEnd = end ?? start.add(const Duration(hours: 1));
    if (!effectiveEnd.isAfter(start)) return const [];

    final summary = event['SUMMARY']?.value.trim() ?? '（无标题日程）';
    final description = event['DESCRIPTION']?.value ?? '';
    final location = event['LOCATION']?.value ?? '';
    var uid = event['UID']?.value.trim() ?? '';
    if (uid.isEmpty) uid = const Uuid().v4();

    final rule = _parseRrule(event['RRULE']?.value);
    final tasks = <Task>[];
    if (rule == null) {
      tasks.add(_buildTask(
        uid: uid,
        summary: summary,
        description: description,
        location: location,
        start: start,
        end: effectiveEnd,
      ));
      return tasks;
    }

    // 重复日程：Task 的重复模型只支持整段时间按天/月/年平移，与简单
    // RRULE 一致；repeatEndsTime 取展开出的最后一次发生日期。
    var cursor = start;
    var cursorEnd = effectiveEnd;
    var count = 0;
    final occurrences = <DateTime>[];
    while (count < rule.countLimit && occurrences.length < 366) {
      if (rule.until != null && cursor.isAfter(rule.until!)) break;
      if (cursor.isAfter(DateTime.now().add(const Duration(days: 180)))) break;
      occurrences.add(cursor);
      count++;
      switch (rule.frequency) {
        case 'DAILY':
          cursor = _addDurationDays(cursor, rule.interval);
          cursorEnd = _addDurationDays(cursorEnd, rule.interval);
          break;
        case 'WEEKLY':
          cursor = _addDurationDays(cursor, 7 * rule.interval);
          cursorEnd = _addDurationDays(cursorEnd, 7 * rule.interval);
          break;
        case 'MONTHLY':
          final shift = DateTime(cursor.year, cursor.month + rule.interval,
              cursor.day, cursor.hour, cursor.minute);
          final shiftEnd = DateTime(
              cursorEnd.year,
              cursorEnd.month + rule.interval,
              cursorEnd.day,
              cursorEnd.hour,
              cursorEnd.minute);
          cursor = shift;
          cursorEnd = shiftEnd;
          break;
        case 'YEARLY':
          cursor = DateTime(cursor.year + rule.interval, cursor.month,
              cursor.day, cursor.hour, cursor.minute);
          cursorEnd = DateTime(cursorEnd.year + rule.interval, cursorEnd.month,
              cursorEnd.day, cursorEnd.hour, cursorEnd.minute);
          break;
        default:
          return tasks;
      }
    }
    if (occurrences.isEmpty) return const [];

    final firstStart = occurrences.first;
    final lastStart = occurrences.last;
    final repeatType = switch (rule.frequency) {
      'MONTHLY' => TaskRepeatType.month,
      'YEARLY' => TaskRepeatType.year,
      _ => TaskRepeatType.days,
    };
    final repeatPeriod = rule.frequency == 'WEEKLY'
        ? 7 * rule.interval
        : rule.frequency == 'DAILY'
            ? rule.interval
            : 1;

    tasks.add(Task(
      uid: uid,
      status: TaskStatus.running,
      summary: summary,
      description: description,
      location: location,
      type: TaskType.fixed,
      isBreakable: false,
      startTime: firstStart,
      endTime: firstStart.add(effectiveEnd.difference(start)),
      repeatType: repeatType,
      repeatPeriod: repeatPeriod,
      repeatEndsTime: DateTime(lastStart.year, lastStart.month, lastStart.day),
    ));
    return tasks;
  }

  static Task _buildTask({
    required String uid,
    required String summary,
    required String description,
    required String location,
    required DateTime start,
    required DateTime end,
  }) {
    return Task(
      uid: uid,
      status: TaskStatus.running,
      summary: summary,
      description: description,
      location: location,
      type: TaskType.fixed,
      isBreakable: false,
      startTime: start,
      endTime: end,
      repeatType: TaskRepeatType.norepeat,
      repeatPeriod: 1,
      repeatEndsTime: DateTime(end.year, end.month, end.day),
    );
  }

  static List<String> _unfold(String raw) {
    final lines = <String>[];
    for (final rawLine in raw.replaceAll('\r\n', '\n').split('\n')) {
      if (rawLine.isEmpty) continue;
      if ((rawLine.startsWith(' ') || rawLine.startsWith('\t')) &&
          lines.isNotEmpty) {
        lines[lines.length - 1] = lines.last + rawLine.substring(1);
      } else {
        lines.add(rawLine);
      }
    }
    return lines;
  }

  static IcalProp? _parseProp(String line) {
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    final head = line.substring(0, colon);
    final value = line.substring(colon + 1);
    final parts = head.split(';');
    return IcalProp(
      name: parts.first,
      params: {
        for (final p in parts.skip(1))
          if (p.contains('='))
            p.substring(0, p.indexOf('=')).toUpperCase():
                p.substring(p.indexOf('=') + 1)
      },
      value: value,
    );
  }

  /// 解析 DTSTART/DTEND。TZID 视为本地墙钟时间（浙大场景即 Asia/Shanghai）；
  /// 带 Z 的按 UTC 解析后转本地；VALUE=DATE 是全天。
  static DateTime? _parseDateTime(IcalProp? prop) {
    if (prop == null) return null;
    var value = prop.value.trim();
    if (value.isEmpty) return null;
    final isUtc = value.endsWith('Z');
    if (isUtc) value = value.substring(0, value.length - 1);
    final isDateOnly = (prop.params['VALUE'] ?? '').toUpperCase() == 'DATE' ||
        !value.contains('T');
    final dateOnly = value.split('T').first;
    if (dateOnly.length < 8) return null;
    final year = int.tryParse(dateOnly.substring(0, 4));
    final month = int.tryParse(dateOnly.substring(4, 6));
    final day = int.tryParse(dateOnly.substring(6, 8));
    if (year == null || month == null || day == null) return null;

    var hour = 0, minute = 0, second = 0;
    if (!isDateOnly && value.contains('T')) {
      final time = value.split('T')[1];
      if (time.length >= 4) {
        hour = int.tryParse(time.substring(0, 2)) ?? 0;
        minute = int.tryParse(time.substring(2, 4)) ?? 0;
        second = time.length >= 6 ? int.tryParse(time.substring(4, 6)) ?? 0 : 0;
      }
    }
    final parsed = isUtc
        ? DateTime.utc(year, month, day, hour, minute, second).toLocal()
        : DateTime(year, month, day, hour, minute, second);
    return parsed;
  }

  static _IcalRrule? _parseRrule(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    String? frequency;
    var interval = 1;
    int? countLimit;
    DateTime? until;
    for (final part in value.trim().split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).toUpperCase();
      final val = part.substring(idx + 1);
      switch (key) {
        case 'FREQ':
          frequency = val.toUpperCase();
          break;
        case 'INTERVAL':
          interval = int.tryParse(val) ?? 1;
          if (interval < 1) interval = 1;
          break;
        case 'COUNT':
          countLimit = int.tryParse(val);
          break;
        case 'UNTIL':
          until = _parseDateTime(
              IcalProp(name: 'DTSTART', params: const {}, value: val));
          break;
        default:
          // BYDAY / BYSETPOS 等复杂规则：沿用单次导入的回退路径。
          break;
      }
    }
    if (frequency == null ||
        !const ['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].contains(frequency)) {
      return null;
    }
    return _IcalRrule(
      frequency: frequency,
      interval: interval,
      countLimit: countLimit ?? 366,
      until: until,
    );
  }

  /// 逐日平移并归一化溢出（DateTime 构造器自动进位）。
  static DateTime _addDurationDays(DateTime t, int days) {
    if (days == 0) return t;
    return days > 0
        ? t.add(Duration(days: days))
        : t.subtract(Duration(days: -days));
  }
}

class IcalProp {
  final String name;
  final Map<String, String> params;
  final String value;

  const IcalProp({
    required this.name,
    required this.params,
    required this.value,
  });
}

class _IcalRrule {
  final String frequency;
  final int interval;
  final int countLimit;
  final DateTime? until;

  const _IcalRrule({
    required this.frequency,
    required this.interval,
    required this.countLimit,
    required this.until,
  });
}
