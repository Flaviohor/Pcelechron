import 'package:celechron/model/task.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

/// 学在浙大作业 → 任务系统同步（文档·3.5）。
///
/// - 幂等：任务唯一标识 `fromUid: 'courses-todo:<todo.id>'`，重复同步只
///   更新不新增；
/// - 时间增量：教师后台延长截止时间时，自动改写任务 endTime 并重排；
/// - 专属样式：老任务若为通用 DDL 样式，无感升级为 `TaskType.homework`；
/// - 严格按截止时间升序排序。
class TodoTaskSync {
  TodoTaskSync._();

  static const _todoPrefix = 'courses-todo:';

  static void sync(List<Todo> todos) {
    if (todos.isEmpty) return;
    try {
      if (!Get.isRegistered<RxList<Task>>(tag: 'taskList')) return;
      final taskList = Get.find<RxList<Task>>(tag: 'taskList');

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

        if (existingTask != null) {
          // 更新 deadline，自动平滑升级为 homework 样式。
          if (existingTask.type != TaskType.homework) {
            existingTask.type = TaskType.homework;
            changed = true;
          }
          if (existingTask.endTime != todo.endTime) {
            existingTask.endTime = todo.endTime!;
            changed = true;
          }
        } else {
          // 插入全新专属作业任务。
          taskList.add(Task(
            uid: const Uuid().v4(),
            summary: '作业：${todo.name}',
            description:
                '课程：${todo.course}\n来源：学在浙大\n提交：${todo.submitUrl}',
            endTime: todo.endTime!,
            startTime: todo.endTime!,
            repeatEndsTime: todo.endTime!,
            type: TaskType.homework,
            fromUid: key,
            courseId: todo.courseId.isNotEmpty ? todo.courseId : null,
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
}
