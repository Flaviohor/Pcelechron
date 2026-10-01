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
import 'package:celechron/services/zhiyun_service.dart';
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

  /// 智云课堂回放卡片（ZhiyunService 驱动）。
  ///
  /// 状态完全由 [ZhiyunService.resolveCourse] 决定：ready 显示直达卡片；
  /// notMatched（我的课程与搜索都找不到 / 无回放小节）整段隐藏；
  /// error（登录失败、网络不可达等）保留卡片并显示原因，点击回退到
  /// 智云官网首页——失败可见，不静默消失。
  Widget _buildClassroomSection(BuildContext context) {
    return _ClassroomSection(course: course);
  }
}

class _ClassroomSection extends StatefulWidget {
  const _ClassroomSection({required this.course});

  final Course course;

  @override
  State<_ClassroomSection> createState() => _ClassroomSectionState();
}

class _ClassroomSectionState extends State<_ClassroomSection> {
  _ZhiyunPhase _phase = _ZhiyunPhase.checking;
  ZhiyunResolve? _result;
  bool _opening = false;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    if (!mounted) return;
    setState(() {
      _phase = _ZhiyunPhase.checking;
      _detail = '';
    });
    final scholar = Get.find<Rx<Scholar>>(tag: 'scholar').value;
    if (!scholar.isLogan) {
      _finish(_ZhiyunPhase.error, '未登录，登录后即可关联智云课堂回放');
      return;
    }
    final result = await ZhiyunService.resolveCourse(
      courseName: widget.course.name,
      teacher: widget.course.teacher,
      username: scholar.username,
      password: scholar.password,
    );
    if (!mounted) return;
    switch (result.kind) {
      case ZhiyunResolveKind.ready:
        setState(() {
          _phase = _ZhiyunPhase.ready;
          _result = result;
        });
      case ZhiyunResolveKind.notMatched:
        setState(() {
          _phase = _ZhiyunPhase.hidden;
        });
      case ZhiyunResolveKind.error:
        _finish(_ZhiyunPhase.error, result.errorMessage);
    }
  }

  void _finish(_ZhiyunPhase phase, String detail) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _detail = detail;
    });
    if (phase == _ZhiyunPhase.error) {
      DiagnosticLogService.instance.record(
        module: 'zhiyun',
        operation: 'resolve',
        message: '智云课堂卡片进入失败态：$detail',
      );
    }
  }

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final result = _result;
    // 课程名始终先入剪贴板：即便直达路由有出入，官网搜索一贴即中。
    await Clipboard.setData(ClipboardData(text: widget.course.name));
    var target = 'https://classroom.zju.edu.cn/';
    if (result != null &&
        result.kind == ZhiyunResolveKind.ready &&
        result.courseId != null &&
        result.latestSubId != null) {
      target =
          ZhiyunService.livingroomUrl(result.courseId!, result.latestSubId!);
    }
    await launchUrlString(target, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: switch (_phase) {
        _ZhiyunPhase.hidden => const SizedBox(width: double.infinity),
        _ZhiyunPhase.checking => _wrapCard(
            context,
            title: '正在检查智云课堂的回放…',
            detail: '登录智云课堂并匹配本课（需校园网）',
            trailing: const CupertinoActivityIndicator(radius: 9),
          ),
        _ZhiyunPhase.ready => RoundRectangleCard(
            onTap: _opening ? null : _open,
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
                                .copyWith(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                        Text(
                          _readySubtitle,
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
                  if (_opening)
                    const CupertinoActivityIndicator(radius: 9)
                  else
                    Icon(CupertinoIcons.chevron_right,
                        size: 14,
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.tertiaryLabel, context)),
                ],
              ),
            ),
          ),
        _ZhiyunPhase.error => RoundRectangleCard(
            onTap: () => _openOfficial(),
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: Row(
                children: [
                  Icon(CupertinoIcons.exclamationmark_circle,
                      size: 26,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.systemOrange, context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('智云课堂暂不可用',
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                        Text(_detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: CupertinoDynamicColor.resolve(
                                  CupertinoColors.secondaryLabel, context),
                            )),
                      ],
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _resolve,
                    child: Text('重试',
                        style: TextStyle(
                            fontSize: 14,
                            color: CupertinoDynamicColor.resolve(
                                CupertinoColors.activeBlue, context))),
                  ),
                ],
              ),
            ),
          ),
      },
    );
  }

  String get _readySubtitle {
    final result = _result;
    if (result == null) return '';
    final teacher = result.realname.isEmpty ? '' : ' · ${result.realname}';
    return '已匹配到 ${result.subCount} 节回放$teacher，点击直达最近一节（需校园网）';
  }

  Widget _wrapCard(
    BuildContext context, {
    required String title,
    required String detail,
    required Widget trailing,
  }) {
    return RoundRectangleCard(
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
                  Text(title,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                  Text(detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.secondaryLabel, context),
                      )),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }

  Future<void> _openOfficial() async {
    await launchUrlString('https://classroom.zju.edu.cn/',
        mode: LaunchMode.externalApplication);
  }
}

enum _ZhiyunPhase { checking, hidden, ready, error }
