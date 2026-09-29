import 'package:celechron/page/scholar/course_list/course_brief_card.dart';
import 'package:celechron/design/sub_title.dart';
import 'package:celechron/design/custom_colors.dart';
import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/design/round_rectangle_card.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:celechron/model/course.dart';

import 'package:celechron/model/exam.dart';
import 'package:celechron/model/session.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/http/zjuServices/classroom.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/utils/utils.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher_string.dart';

class CourseDetailPage extends StatelessWidget {
  final _scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  late final Course course;
  late final String _courseId;

  CourseDetailPage({required courseId, super.key}) {
    course = _scholar.value.semesters
        .firstWhere((e) => e.courses.containsKey(courseId))
        .courses[courseId]!;
    _courseId = courseId.toString();
  }

  Widget createSessionCard(context, List<Session> sessions) {
    sessions.sort((a, b) => a.time.first.compareTo(b.time.first));
    return Column(
      children: [
        SubSubtitleRow(subtitle: '课时'),
        RoundRectangleCard(
            child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Column(children: [
            Row(
              children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 12.0,
                              height: 12.0,
                              decoration: BoxDecoration(
                                color: TimeColors.colorFromClass(
                                    sessions[0].time.first),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8.0),
                            Expanded(
                                child: Text(sessions[0].chineseTime,
                                    style: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .copyWith(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          overflow: TextOverflow.ellipsis,
                                        ))),
                          ],
                        ),
                        const SizedBox(height: 4.0),
                        Row(children: [
                          Icon(
                            CupertinoIcons.location_solid,
                            size: 14,
                            color: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color!
                                .withValues(alpha: 0.5),
                          ),
                          Expanded(
                              child: Text(' 地点：${sessions[0].location ?? '未知'}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .color!
                                        .withValues(alpha: 0.75),
                                    overflow: TextOverflow.ellipsis,
                                  )))
                        ]),
                      ],
                    ),
                    for (var i = 1; i < sessions.length; i++)
                      Column(
                        children: [
                          Divider(
                            height: 24,
                            thickness: 1,
                            indent: 0,
                            endIndent: 0,
                            color: CupertinoDynamicColor.resolve(
                                CupertinoColors.systemFill, context),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 12.0,
                                height: 12.0,
                                decoration: BoxDecoration(
                                  color: TimeColors.colorFromClass(
                                      sessions[i].time.first),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8.0),
                              Expanded(
                                  child: Text(sessions[i].chineseTime,
                                      style: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .copyWith(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            overflow: TextOverflow.ellipsis,
                                          ))),
                            ],
                          ),
                          const SizedBox(height: 4.0),
                          Row(children: [
                            Icon(
                              CupertinoIcons.location_solid,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withValues(alpha: 0.5),
                            ),
                            Expanded(
                                child:
                                    Text(' 地点：${sessions[i].location ?? '未知'}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: CupertinoTheme.of(context)
                                              .textTheme
                                              .textStyle
                                              .color!
                                              .withValues(alpha: 0.75),
                                          overflow: TextOverflow.ellipsis,
                                        )))
                          ]),
                        ],
                      )
                  ],
                )),
              ],
            ),
          ]),
        ))
      ],
    );
  }

  Widget createExamCard(context, List<Exam> exams) {
    return Column(
      children: [
        SubSubtitleRow(subtitle: '考试'),
        RoundRectangleCard(
            child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Column(children: [
            Row(
              children: [
                Expanded(
                    child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 12.0,
                              height: 12.0,
                              decoration: BoxDecoration(
                                color: CupertinoColors.systemPink,
                                shape: exams[0].type == ExamType.midterm
                                    ? BoxShape.circle
                                    : BoxShape.rectangle,
                              ),
                            ),
                            const SizedBox(width: 8.0),
                            Expanded(
                                child: Text(exams[0].chineseTime,
                                    style: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .copyWith(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          overflow: TextOverflow.ellipsis,
                                        ))),
                          ],
                        ),
                        const SizedBox(height: 4.0),
                        Row(children: [
                          Icon(
                            CupertinoIcons.location_solid,
                            size: 14,
                            color: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color!
                                .withValues(alpha: 0.5),
                          ),
                          Expanded(
                              child: Text(' 地点：${exams[0].location ?? '未知'}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .color!
                                        .withValues(alpha: 0.75),
                                    overflow: TextOverflow.ellipsis,
                                  )))
                        ]),
                        Row(children: [
                          Icon(
                            CupertinoIcons.map_pin_ellipse,
                            size: 14,
                            color: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .color!
                                .withValues(alpha: 0.5),
                          ),
                          Expanded(
                              child: Text(' 座位：${exams[0].seat ?? '未知'}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: CupertinoTheme.of(context)
                                        .textTheme
                                        .textStyle
                                        .color!
                                        .withValues(alpha: 0.75),
                                    overflow: TextOverflow.ellipsis,
                                  )))
                        ]),
                        if (exams[0].type == ExamType.midterm)
                          Row(children: [
                            Icon(
                              CupertinoIcons.doc_text,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withValues(alpha: 0.5),
                            ),
                            Expanded(
                                child: Text(' 类型：期中',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withValues(alpha: 0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                      ],
                    ),
                    for (var i = 1; i < exams.length; i++)
                      Column(
                        children: [
                          Divider(
                            height: 16,
                            thickness: 1,
                            indent: 0,
                            endIndent: 0,
                            color: CupertinoDynamicColor.resolve(
                                CupertinoColors.systemFill, context),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 12.0,
                                height: 12.0,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.systemPink,
                                  shape: exams[i].type == ExamType.midterm
                                      ? BoxShape.circle
                                      : BoxShape.rectangle,
                                ),
                              ),
                              const SizedBox(width: 8.0),
                              Expanded(
                                  child: Text(exams[i].chineseTime,
                                      style: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .copyWith(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            overflow: TextOverflow.ellipsis,
                                          ))),
                            ],
                          ),
                          const SizedBox(height: 4.0),
                          Row(children: [
                            Icon(
                              CupertinoIcons.location_solid,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withValues(alpha: 0.5),
                            ),
                            Expanded(
                                child: Text(' 地点：${exams[i].location ?? '未知'}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withValues(alpha: 0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                          Row(children: [
                            Icon(
                              CupertinoIcons.map_pin_ellipse,
                              size: 14,
                              color: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .color!
                                  .withValues(alpha: 0.5),
                            ),
                            Expanded(
                                child: Text(' 座位：${exams[i].seat ?? '未知'}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .color!
                                          .withValues(alpha: 0.75),
                                      overflow: TextOverflow.ellipsis,
                                    )))
                          ]),
                          if (exams[i].type == ExamType.midterm)
                            Row(children: [
                              Icon(
                                CupertinoIcons.doc_text,
                                size: 14,
                                color: CupertinoTheme.of(context)
                                    .textTheme
                                    .textStyle
                                    .color!
                                    .withValues(alpha: 0.5),
                              ),
                              Expanded(
                                  child: Text(' 类型：期中',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: CupertinoTheme.of(context)
                                            .textTheme
                                            .textStyle
                                            .color!
                                            .withValues(alpha: 0.75),
                                        overflow: TextOverflow.ellipsis,
                                      )))
                            ]),
                        ],
                      ),
                  ],
                )),
              ],
            ),
          ]),
        ))
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0x00000000),
      child: CustomScrollView(
        slivers: [
          const CelechronSliverTextHeader(subtitle: '课程详情'),
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.only(bottom: 5, left: 16, right: 16),
              child: Column(
                children: [
                  SubSubtitleRow(subtitle: '基本信息'),
                  CourseBriefCard(course: course),
                ],
              ),
            ),
          ),
          if (course.sessions.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: createSessionCard(context, course.sessions),
              ),
            ),
          if (course.exams.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: createExamCard(context, course.exams),
              ),
            ),
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              child: _buildCourseTasksSection(context),
            ),
          ),
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              child: _buildClassroomSection(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 本课任务：编辑页里关联到本课程的用户任务 + 按课程名匹配的学在浙大作业。
  Widget _buildCourseTasksSection(BuildContext context) {
    final taskList = Get.find<RxList<Task>>(tag: 'taskList');
    final mountedTasks = taskList
        .where((t) => t.courseId != null && t.courseId == _courseId)
        .toList()
      ..sort((a, b) => a.endTime.compareTo(b.endTime));
    final todos = _scholar.value.todos
        .where((t) => _matchesCourseName(t.course))
        .toList()
      ..sort((a, b) =>
          (a.endTime ?? DateTime(2001)).compareTo(b.endTime ?? DateTime(2001)));
    if (mountedTasks.isEmpty && todos.isEmpty) {
      return const SizedBox.shrink();
    }

    final secondaryStyle = TextStyle(
      fontSize: 13,
      color: CupertinoDynamicColor.resolve(
          CupertinoColors.secondaryLabel, context),
    );

    return Column(
      children: [
        SubSubtitleRow(subtitle: '本课任务'),
        RoundRectangleCard(
          child: Padding(
            padding:
                const EdgeInsets.only(left: 8, right: 8, top: 6, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final task in mountedTasks)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: task.status == TaskStatus.completed
                                ? CupertinoColors.systemGreen
                                : TimeColors.colorFromHour(task.startTime.hour),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(task.summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle),
                        ),
                        Text(toStringHumanReadable(task.endTime),
                            style: secondaryStyle),
                      ],
                    ),
                  ),
                for (final todo in todos)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: CupertinoColors.systemOrange,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('作业：${todo.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle),
                        ),
                        Text(
                            todo.endTime == null
                                ? '无截止'
                                : toStringHumanReadable(todo.endTime!),
                            style: secondaryStyle),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _matchesCourseName(String? todoCourse) {
    if (todoCourse == null || todoCourse.trim().isEmpty) return false;
    final a = todoCourse.replaceAll(RegExp(r"[ \t]+"), '');
    final b = course.name.replaceAll(RegExp(r"[ \t]+"), '');
    if (a.isEmpty || b.isEmpty) return false;
    return a.contains(b) || b.contains(a);
  }

  /// 智云课堂入口卡片（直连版）。
  ///
  /// 登录链路与搜索接口经 celechron-tauri / zju-learning-assistant 两个开源
  /// 实现交叉验证；SPA 课程页路由无公开先例，采用 `#/course/<id>` 直达——
  /// hash 路由拼错只会落到官网默认页，且课程名始终先写入剪贴板兜底。
  Widget _buildClassroomSection(BuildContext context) {
    return Column(
      children: [
        SubSubtitleRow(subtitle: '课堂回放'),
        _ClassroomDirectCard(course: course),
      ],
    );
  }
}

class _ClassroomDirectCard extends StatefulWidget {
  const _ClassroomDirectCard({required this.course});

  final Course course;

  @override
  State<_ClassroomDirectCard> createState() => _ClassroomDirectCardState();
}

class _ClassroomDirectCardState extends State<_ClassroomDirectCard> {
  bool _loading = false;
  String _status = '登录智云课堂并直达本课的直播与回放（需校园网）';

  Future<void> _open() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _status = '正在登录智云课堂并匹配课程…';
    });

    // 课程名始终先进剪贴板：即使直达路由未命中，官网搜索一贴即中。
    await Clipboard.setData(ClipboardData(text: widget.course.name));

    Uri target = Uri.parse('https://classroom.zju.edu.cn/');
    try {
      final scholar = Get.find<Rx<Scholar>>(tag: 'scholar').value;
      final matched = await ClassroomService.findCourse(
        courseName: widget.course.name,
        teacher: widget.course.teacher,
        username: scholar.username,
        password: scholar.password,
      );
      if (matched == null) {
        _status = '未在智云课堂找到对应课程，已打开官网（课程名在剪贴板）';
      } else {
        target = Uri.parse(
            'https://classroom.zju.edu.cn/#/course/${matched.courseId}');
        _status = matched.realname.isEmpty
            ? '已匹配「${matched.title}」，正在打开'
            : '已匹配「${matched.title}」· ${matched.realname}，正在打开';
      }
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'classroom',
        operation: 'direct',
        message: '智云课堂直连失败，已回退到官网首页',
        error: error,
        stackTrace: stackTrace,
      );
      _status = '连接智云课堂失败，已打开官网（课程名在剪贴板）';
    }

    await launchUrlString(target.toString(),
        mode: LaunchMode.externalApplication);
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RoundRectangleCard(
      onTap: _loading ? null : _open,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 8),
        child: Row(
          children: [
            const Icon(CupertinoIcons.play_circle,
                size: 26, color: CupertinoColors.activeBlue),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('智云课堂 · ${widget.course.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(
                    _status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel, context),
                    ),
                  ),
                ],
              ),
            ),
            if (_loading)
              const CupertinoActivityIndicator(radius: 9)
            else
              Icon(CupertinoIcons.chevron_right,
                  size: 14,
                  color: CupertinoDynamicColor.resolve(
                      CupertinoColors.tertiaryLabel, context)),
          ],
        ),
      ),
    );
  }
}
