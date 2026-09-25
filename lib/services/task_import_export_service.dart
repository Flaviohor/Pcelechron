import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:get/get.dart';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/model/ical_parser.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/task_json.dart';

/// 待办数据的导入导出：iCal (`.ics`) 导入为日程、待办 JSON 备份的导出与导入。
///
/// 桌面端没有系统日历 API，iCal 走「文件导入」而不是移动端的日历同步；
/// JSON 备份覆盖用户自建的全部任务（DDL + 日程），按 uid 合并去重。
class TaskImportExportService {
  TaskImportExportService._();

  static const _icsTypeGroup = XTypeGroup(
    label: 'iCal 日历文件',
    extensions: ['ics'],
  );
  static const _jsonTypeGroup = XTypeGroup(
    label: 'JSON 文件',
    extensions: ['json'],
  );

  /// 导出当前全部任务为 JSON。返回导出条数；用户取消返回 null。
  static Future<int?> exportTasksJson(List<Task> tasks) async {
    final suggestedName =
        'celechron-tasks-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    final location = await getSaveLocation(
      acceptedTypeGroups: [_jsonTypeGroup],
      suggestedName: suggestedName,
    );
    if (location == null) return null;
    final envelope = TaskJsonCodec.encodeEnvelope(tasks);
    await File(location.path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(envelope),
      flush: true,
    );
    return tasks.length;
  }

  /// 从 JSON 文件导入任务，与现有 [existing] 按 uid 合并。
  /// 返回合并结果；用户取消或文件无法解析返回 null。
  static Future<TaskImportResult?> importTasksJson(List<Task> existing) async {
    final file = await openFile(acceptedTypeGroups: [_jsonTypeGroup]);
    if (file == null) return null;
    final Object? decoded;
    try {
      decoded = await file.readAsString().then(jsonDecode);
    } on Object {
      return null;
    }
    final incoming = TaskJsonCodec.decodeDocument(decoded);
    if (incoming == null) return null;
    return TaskJsonCodec.mergeImport(incoming, existing);
  }

  /// 从 iCal 文件导入 VEVENT 为「日程」。与现有 [existing] 按 uid 去重。
  /// 返回 (新增列表, 重复跳过数)；用户取消或没有可导入事件返回 null。
  static Future<(List<Task>, int)?> importIcal(List<Task> existing) async {
    final file = await openFile(acceptedTypeGroups: [_icsTypeGroup]);
    if (file == null) return null;
    final String raw;
    try {
      raw = await file.readAsString();
    } on Object {
      return null;
    }

    final existingUids = existing.map((t) => t.uid).toSet();
    final added = <Task>[];
    var skipped = 0;
    for (final event in IcalParser.parseEvents(raw)) {
      for (final task in IcalParser.eventToTasks(event)) {
        if (existingUids.contains(task.uid)) {
          skipped++;
          continue;
        }
        existingUids.add(task.uid);
        added.add(task);
      }
    }
    if (added.isEmpty && skipped == 0) return null;
    return (added, skipped);
  }
}

/// 落盘辅助：导入产生的任务列表变化统一从 [persistTaskList] 写库，
/// 调用方（设置页）不直接接触 DatabaseHelper。
Future<void> persistTaskList(List<Task> tasks) async {
  final db = Get.find<DatabaseHelper>(tag: 'db');
  await db.setTaskList(tasks);
  await db.setTaskListUpdateTime(DateTime.now());
}
