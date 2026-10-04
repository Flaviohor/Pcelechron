import 'package:celechron/utils/json_utils.dart';

class Todo {
  String id;
  String name;
  String course;

  /// 学在浙大（TronClass）系统内课程编号，用于构造作业提交深链。
  String courseId;
  DateTime? endTime;

  Todo.fromJson(Map<String, dynamic> json)
      : id = asString(json["id"]) ?? '',
        name = asString(json["title"]) ?? '未命名作业',
        course = asString(json["course_name"]) ?? '未知课程',
        courseId = asString(json["course_id"]) ?? '',
        endTime = DateTime.tryParse(asString(json["end_time"]) ?? '');

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': name,
        'course_name': course,
        'course_id': courseId,
        'end_time': endTime?.toIso8601String(),
      };

  static List<Todo> getAllFromCourses(Map<String, dynamic> json) {
    final rawTodos = asDynamicList(json["todo_list"]) ?? const [];
    final todos = <Todo>[];
    for (final rawTodo in rawTodos) {
      final todoMap = asStringMap(rawTodo);
      if (todoMap == null || asBool(todoMap["is_student"]) != true) continue;
      try {
        final todo = Todo.fromJson(todoMap);
        if (todo.id.isNotEmpty) todos.add(todo);
      } catch (_) {
        // 单条作业字段异常不影响其它作业。
      }
    }
    return todos;
  }

  // TODO: 对于助教/老师，是否需要将批改作业当作 todo 来显示？

  /// 作业提交区深度直达链接（TronClass SPA 路由逆向成果）。
  ///
  /// `?view=scores` 直接激活学生侧的提交历史 / 重新提交附件 / 评分要求
  /// 视图；courseId 缺失（旧缓存）时降级到全局待办列表页。
  String get submitUrl => courseId.isNotEmpty && id.isNotEmpty
      ? 'https://courses.zju.edu.cn/course/$courseId/learning-activity#/$id?view=scores'
      : 'https://courses.zju.edu.cn/user/index#/todo';

  bool isInOneDay() => endTime != null
      ? endTime!.subtract(const Duration(days: 1)).isBefore(DateTime.now())
      : false;

  bool isInOneWeek() => endTime != null
      ? endTime!.subtract(const Duration(days: 7)).isBefore(DateTime.now())
      : false;
}
