import 'dart:async';

import 'package:get/get.dart';
import 'package:flutter/cupertino.dart';

import 'package:celechron/model/scholar.dart';
import 'package:celechron/model/option.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/database/database_helper.dart';
import 'package:celechron/services/notification_service.dart';
import 'package:celechron/services/task_import_export_service.dart';
import 'package:celechron/worker/ecard_widget_messenger.dart';
import 'package:celechron/worker/fuse.dart';
import 'package:celechron/worker/background_refresh.dart';
import 'package:celechron/model/calendar_to_ical.dart';
import 'package:celechron/page/flow/flow_controller.dart';

import 'package:celechron/utils/utils.dart';

class OptionController extends GetxController {
  final _option = Get.find<Option>(tag: 'option');
  final scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  final _fuse = Get.find<Rx<Fuse>>(tag: 'fuse');
  final _db = Get.find<DatabaseHelper>(tag: 'db');
  late final RxInt allowTimeLength = _option.allowTime.length.obs;

  @override
  void onInit() {
    super.onInit();

    _updateBackgroundWorker(
        _option.pushOnGradeChange.value || _option.pushOnDdlReminder.value);

    ever(courseIdMappingList, (value) {
      _db.setCourseIdMappingList(value);
    });
  }

  Duration get workTime => _option.workTime.value;

  set workTime(Duration value) {
    _option.workTime.value = value;
    _db.setWorkTime(value);
  }

  Duration get restTime => _option.restTime.value;

  set restTime(Duration value) {
    _option.restTime.value = value;
    _db.setRestTime(value);
  }

  Map<DateTime, DateTime> get allowTime => _option.allowTime;

  set allowTime(Map<DateTime, DateTime> value) {
    _option.allowTime.value = value;
    _db.setAllowTime(value);
    allowTimeLength.value = value.length;
  }

  GpaStrategy get gpaStrategy => _option.gpaStrategy.value;

  set gpaStrategy(GpaStrategy value) {
    _option.gpaStrategy.value = value;
    _db.setGpaStrategy(value);
  }

  bool get pushOnGradeChange => _option.pushOnGradeChange.value;

  set pushOnGradeChange(bool value) {
    _option.pushOnGradeChange.value = value;
    _db.setPushOnGradeChange(value);
    // 同步到 SecureStorage 供后台任务读取
    _db.secureStorage.write(
        key: 'pushOnGradeChange',
        value: value.toString(),
        iOptions: secureStorageIOSOptions,
        mOptions: secureStorageMacOsOptions);

    _updateBackgroundWorker(value || pushOnDdlReminder);
  }

  bool get pushOnDdlReminder => _option.pushOnDdlReminder.value;

  set pushOnDdlReminder(bool value) {
    _option.pushOnDdlReminder.value = value;
    _db.setPushOnDdlReminder(value);
    // 同步到 SecureStorage 供后台任务读取
    _db.secureStorage.write(
        key: 'pushOnDdlReminder',
        value: value.toString(),
        iOptions: secureStorageIOSOptions,
        mOptions: secureStorageMacOsOptions);

    _updateBackgroundWorker(value || pushOnGradeChange);
  }

  void _updateBackgroundWorker(bool enabled) {
    if (enabled) {
      unawaited(backgroundRefreshScheduler.enable());
    } else {
      unawaited(backgroundRefreshScheduler.disable());
    }
  }

  BrightnessMode get brightnessMode => _option.brightnessMode.value;

  set brightnessMode(BrightnessMode value) {
    _option.brightnessMode.value = value;
    _db.setBrightnessMode(value);
  }

  RxList<CourseIdMap> get courseIdMappingList => _option.courseIdMappingList;

  bool get hideHomeGpa => _option.hideHomeGpa.value;

  set hideHomeGpa(bool value) {
    _option.hideHomeGpa.value = value;
    _db.setHideHomeGpa(value);
  }

  bool get asyncRefresh => _option.asyncRefresh.value;

  set asyncRefresh(bool value) {
    _option.asyncRefresh.value = value;
    _db.setAsyncRefresh(value);
  }

  bool get closeToTray => _option.closeToTray.value;

  set closeToTray(bool value) {
    _option.closeToTray.value = value;
    _db.setCloseToTray(value);
  }

  /// 设置页「发送测试通知」：当场验证系统通知链路。
  Future<void> sendTestNotification() {
    return NotificationService.showTestNotification();
  }

  // ===== 待办数据导入导出 =====

  RxList<Task> get _taskList => Get.find<RxList<Task>>(tag: 'taskList');

  /// 导出全部任务为 JSON。返回导出条数；用户取消返回 null。
  Future<int?> exportTasksJson() {
    return TaskImportExportService.exportTasksJson(_taskList.toList());
  }

  /// 导入 JSON 备份并按 uid 合并。返回结果摘要；取消/解析失败返回 null。
  Future<String?> importTasksJson() async {
    final result =
        await TaskImportExportService.importTasksJson(_taskList.toList());
    if (result == null) return null;
    if (result.added.isNotEmpty) _taskList.addAll(result.added);
    // 备份侧删除的条目在合并时已被标记为 deleted，这里直接移除。
    _taskList.removeWhere((t) => t.status == TaskStatus.deleted);
    _taskList.sort((a, b) => a.endTime.compareTo(b.endTime));
    await persistTaskList(_taskList);
    _regenerateFlowList();
    return result.summary;
  }

  /// 导入 iCal 日历为「日程」。返回结果摘要；取消/无可导入事件返回 null。
  Future<String?> importIcal() async {
    final result = await TaskImportExportService.importIcal(_taskList.toList());
    if (result == null) return null;
    final (added, skipped) = result;
    if (added.isNotEmpty) _taskList.addAll(added);
    _taskList.sort((a, b) => a.endTime.compareTo(b.endTime));
    await persistTaskList(_taskList);
    _regenerateFlowList();
    return '新增 ${added.length} 条日程'
        '${skipped > 0 ? '，按 UID 去重跳过 $skipped 条' : ''}';
  }

  /// 新增/删除日程会影响自动规划，导入完成后重排一次。
  void _regenerateFlowList() {
    try {
      final flow = Get.find<FlowController>();
      flow.removeFlowInFlowList();
      final now = DateTime.now();
      flow.generateNewFlowList(
          DateTime(now.year, now.month, now.day, now.hour, now.minute));
    } on Object {
      // 规划器尚未就绪时跳过，下次刷新任务页时会自动重排。
    }
  }

  String get celechronVersion => _fuse.value.displayVersion;

  bool get hasNewVersion => _fuse.value.hasNewVersion;

  Future<void> logout() async {
    await scholar.value.logout();
    scholar.refresh();
    pushOnGradeChange = false;
    ECardWidgetMessenger.logout();
  }

  /// calendar_to_ical.dart: 显示导出课程表对话框
  void showExportDialog(BuildContext context) {
    CalendarToIcal.showExportDialog(context, scholar.value);
  }

  /// 系统日历同步 —— PC 端不支持，始终返回不可用
  bool get systemCalendarAvailable => false;

  bool get calendarSyncEnabled => false;

  bool get hasCalendarPermission => false;

  Future<void> toggleCalendarSync(BuildContext context, bool enabled) {
    return Future<void>.value();
  }

  void showCalendarSyncDialog(BuildContext context) {}

  Map<String, dynamic> getCalendarSyncStatus() {
    return {
      'available': false,
      'enabled': false,
      'hasPermission': false,
      'isLoggedIn': scholar.value.isLogan,
    };
  }
}
