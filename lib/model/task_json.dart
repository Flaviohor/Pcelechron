import 'package:celechron/model/task.dart';

/// Task 的 JSON 序列化与导入合并。
///
/// 用于「导出待办 JSON / 导入待办 JSON」的备份与迁移场景：
/// - 导出为带版本号与导出时间的信封结构，同时兼容裸数组（手写或旧版文件）；
/// - 导入按 uid 去重合并：已删除（墓碑）优先，防止被旧备份复活；
///   两边都存在且都未删除时，以导入方为准（导入通常是恢复/迁移意图）。
class TaskJsonCodec {
  static const int version = 1;

  static Map<String, dynamic> encodeEnvelope(List<Task> tasks,
      {DateTime? exportedAt}) {
    return {
      'version': version,
      'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
      'tasks': tasks.map(encodeTask).toList(),
    };
  }

  static Map<String, dynamic> encodeTask(Task t) {
    return {
      'uid': t.uid,
      'status': t.status.name,
      'description': t.description,
      'timeSpentMs': t.timeSpent.inMilliseconds,
      'timeNeededMs': t.timeNeeded.inMilliseconds,
      'startTime': t.startTime.toIso8601String(),
      'endTime': t.endTime.toIso8601String(),
      'location': t.location,
      'summary': t.summary,
      'isBreakable': t.isBreakable,
      'type': t.type.name,
      'repeatType': t.repeatType.name,
      'repeatPeriod': t.repeatPeriod,
      'repeatEndsTime': t.repeatEndsTime.toIso8601String(),
      'blockArrangements': t.blockArrangements,
      'fromUid': t.fromUid,
    };
  }

  static Task? decodeTask(Object? raw) {
    final map = raw is Map ? raw.cast<String, dynamic>() : null;
    if (map == null) return null;
    try {
      final status = TaskStatus.values.asNameMap()[map['status']];
      final type = TaskType.values.asNameMap()[map['type']];
      final repeatType = TaskRepeatType.values.asNameMap()[map['repeatType']];
      final startTime = DateTime.tryParse(map['startTime']?.toString() ?? '');
      final endTime = DateTime.tryParse(map['endTime']?.toString() ?? '');
      if (startTime == null || endTime == null) return null;
      final repeatEndsTime =
          DateTime.tryParse(map['repeatEndsTime']?.toString() ?? '');
      return Task(
        uid: map['uid']?.toString() ?? '',
        status: status ?? TaskStatus.running,
        description: map['description']?.toString() ?? '',
        timeSpent: Duration(milliseconds: _toInt(map['timeSpentMs'])),
        timeNeeded: Duration(milliseconds: _toInt(map['timeNeededMs'])),
        startTime: startTime,
        endTime: endTime,
        location: map['location']?.toString() ?? '',
        summary: map['summary']?.toString() ?? '',
        isBreakable: map['isBreakable'] == true,
        type: type ?? TaskType.deadline,
        repeatType: repeatType ?? TaskRepeatType.norepeat,
        repeatPeriod: _toInt(map['repeatPeriod'], fallback: 1),
        repeatEndsTime: repeatEndsTime ?? endTime,
        blockArrangements: map['blockArrangements'] != false,
        fromUid: map['fromUid']?.toString(),
      );
    } on Object {
      return null;
    }
  }

  /// 解析导入内容（信封或裸数组），无法识别返回 null。
  static List<Task>? decodeDocument(Object? decoded) {
    if (decoded is List) {
      return decoded.map(decodeTask).whereType<Task>().toList();
    }
    if (decoded is Map) {
      final raw = decoded['tasks'];
      if (raw is List) {
        return raw.map(decodeTask).whereType<Task>().toList();
      }
    }
    return null;
  }

  /// 导入合并：返回应加入本地的新任务，并就地更新 [existing] 中被改动的条目
  /// （含把本地条目标记为 deleted 以同步备份侧的删除）。
  static TaskImportResult mergeImport(
    List<Task> incoming,
    List<Task> existing,
  ) {
    final byUid = {for (final t in existing) t.uid: t};
    final added = <Task>[];
    var skippedDuplicate = 0;
    var tombstoned = 0;
    var unparsable = 0;

    for (final task in incoming) {
      if (task.uid.isEmpty) {
        unparsable++;
        continue;
      }
      final current = byUid[task.uid];
      if (current == null) {
        // 导入文件里的「已删除」对本地是新条目：等价于墓碑，不落地。
        if (task.status == TaskStatus.deleted) {
          tombstoned++;
        } else {
          added.add(task);
          byUid[task.uid] = task;
        }
        continue;
      }
      if (current.status == TaskStatus.deleted) {
        // 本地已删除 = 墓碑，阻止任何导入复活。
        tombstoned++;
      } else if (task.status == TaskStatus.deleted) {
        // 备份侧删除了这条任务：把本地条目标记删除，由任务页的正常清理移除。
        current.status = TaskStatus.deleted;
        tombstoned++;
      } else {
        // 两边都在：以导入方为准。
        current.copy(task);
        skippedDuplicate++;
      }
    }
    return TaskImportResult(
      added: added,
      updatedDuplicates: skippedDuplicate,
      tombstoned: tombstoned,
      unparsable: unparsable,
    );
  }

  static int _toInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }
}

/// 一次导入合并的统计。
class TaskImportResult {
  final List<Task> added;
  final int updatedDuplicates;
  final int tombstoned;
  final int unparsable;

  const TaskImportResult({
    required this.added,
    required this.updatedDuplicates,
    required this.tombstoned,
    required this.unparsable,
  });

  String get summary {
    final parts = ['新增 ${added.length} 条'];
    if (updatedDuplicates > 0) parts.add('以文件为准更新 $updatedDuplicates 条');
    if (tombstoned > 0) parts.add('按删除标记处理 $tombstoned 条');
    if (unparsable > 0) parts.add('无法解析 $unparsable 条');
    return parts.join('，');
  }
}
