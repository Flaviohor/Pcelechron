import 'dart:convert';

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/utils/json_utils.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

/// 学在浙大作业 → 任务系统同步（文档·3.5）。
///
/// - 幂等：任务唯一标识 `fromUid: 'courses-todo:<todo.id>'`，重复同步只
///   更新不新增；
/// - 时间增量：教师后台延长截止时间时，自动改写任务 endTime 并重排；
/// - 数据自愈（文档·3.4）：旧缓存的作业缺 course_id 时，从 `courses_todo`
///   原始网页缓存里按 id 就地检索补全，生成正确的提交深链；
/// - 专属样式：老任务若为通用 DDL 样式，无感升级为 `TaskType.homework`；
/// - 严格按截止时间升序排序。
class TodoTaskSync {
  TodoTaskSync._();

  static const _todoPrefix = 'courses-todo:';
  static const _submitUrlPrefix = 'https://courses.zju.edu.cn/course/';

  static void sync(List<Todo> todos) {
    if (todos.isEmpty) return;
    try {
      if (!Get.isRegistered<RxList<Task>>(tag: 'taskList')) return;
      final taskList = Get.find<RxList<Task>>(tag: 'taskList');
      final DatabaseHelper? db = Get.isRegistered<DatabaseHelper>(tag: 'db')
          ? Get.find<DatabaseHelper>(tag: 'db')
          : null;

      final existingTodoTasks = <String, Task>{};
      for (final task in taskList) {
        if (task.fromUid != null && task.fromUid!.startsWith(_todoPrefix)) {
          existingTodoTasks[task.fromUid!] = task;
        }
      }

      var changed = false;
      for (final todo in todos) {
        if (todo.id.isEmpty || todo.endTime == null) continue;
        final key = '$_todoPrefix${todo.id}';
        final existingTask = existingTodoTasks[key];

        // 数据自愈：course_id 缺失时从原始响应缓存补全（文档·3.4）。
        var courseId = todo.courseId;
        if (courseId.isEmpty) {
          courseId = _courseIdFromRawCache(todo.id, db) ?? '';
        }
        final submitUrl = courseId.isEmpty || todo.id.isEmpty
            ? null
            : '$_submitUrlPrefix$courseId/learning-activity#/${todo.id}?view=scores';
        final description = submitUrl == null
            ? '课程：${todo.course}\n来源：学在浙大'
            : '课程：${todo.course}\n来源：学在浙大\n提交：$submitUrl';

        if (existingTask != null) {
          // 更新 deadline / 类型 / 深链（自愈补全后描述会变化）。
          if (existingTask.type != TaskType.homework) {
            existingTask.type = TaskType.homework;
            changed = true;
          }
          if (existingTask.endTime != todo.endTime) {
            existingTask.endTime = todo.endTime!;
            changed = true;
          }
          if (existingTask.description != description) {
            existingTask.description = description;
            changed = true;
          }
          if (courseId.isNotEmpty && existingTask.courseId != courseId) {
            existingTask.courseId = courseId;
            changed = true;
          }
        } else {
          taskList.add(Task(
            uid: const Uuid().v4(),
            summary: '作业：${todo.name}',
            description: description,
            endTime: todo.endTime!,
            startTime: todo.endTime!,
            repeatEndsTime: todo.endTime!,
            type: TaskType.homework,
            fromUid: key,
            courseId: courseId.isNotEmpty ? courseId : null,
          ));
          changed = true;
        }
      }

      if (changed) {
        taskList.sort((a, b) => a.endTime.compareTo(b.endTime));
        DiagnosticLogService.instance.record(
          module: '作业任务同步',
          operation: 'sync',
          message: '已同步 ${todos.length} 条作业到任务列表',
        );
      }
    } on Object catch (error, stackTrace) {
      // 同步失败不影响作业数据本身。
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: '作业任务同步',
        operation: 'sync',
        message: '作业任务同步失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 从 `courses_todo` 原始响应缓存里按作业 id 回捞 course_id（自愈）。
  static String? _courseIdFromRawCache(String todoId, DatabaseHelper? db) {
    final cached = db?.getCachedWebPage('courses_todo');
    if (cached == null || cached.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(cached);
      final list = decoded is Map
          ? asDynamicList(decoded['todo_list'])
          : asDynamicList(decoded);
      for (final item in list ?? const []) {
        final map = asStringMap(item);
        if (map == null) continue;
        if (map['id']?.toString() != todoId) continue;
        final courseId = asString(map['course_id'])?.trim() ?? '';
        if (courseId.isNotEmpty) return courseId;
      }
    } on Object {
      // 缓存损坏不阻塞同步。
    }
    return null;
  }
}
