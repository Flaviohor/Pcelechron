import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';

import 'package:celechron/services/diagnostic_log_service.dart';

/// 通知服务的统一入口。
///
/// 原先 Android / iOS 的初始化与通知通道分散在 `main.dart`、
/// `option_controller.dart` 和 `background_app_refresh.dart` 三处，各自只配了
/// 移动端平台。移植到桌面后必须补上 Windows（Toast）配置，因此收敛到这里，
/// 三个调用点共用同一份初始化逻辑。
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();

  /// Windows Toast 通知所需的固定标识。
  ///
  /// - [appUserModelId] 必须与打包时（MSIX / 安装器）写入注册表的值一致，
  ///   否则通知不会显示。
  /// - [guid] 任意固定 GUID 即可，用于 Windows 通知的内部标识。
  static const String windowsAppName = 'PCelechron';
  static const String windowsAppUserModelId = 'top.celechron.celechron';
  static const String windowsGuid = '7c85e25b-fa7d-489e-9b10-b4c22a3458f0';

  static bool _initialized = false;

  static Future<void> init() async {
    const darwinSettings = DarwinInitializationSettings(
      requestSoundPermission: true,
      requestBadgePermission: true,
      requestAlertPermission: true,
    );
    const windowsSettings = WindowsInitializationSettings(
      appName: windowsAppName,
      appUserModelId: windowsAppUserModelId,
      guid: windowsGuid,
    );
    final linuxSettings = LinuxInitializationSettings(
      defaultActionName: '打开 PCelechron',
      // AssetsLinuxIcon 按相对路径解析到 data/flutter_assets/ 下的资产文件，
      // 与 pubspec.yaml 声明的 assets/ 目录一致。
      defaultIcon: AssetsLinuxIcon('assets/logo.png'),
    );
    final settings = InitializationSettings(
      iOS: darwinSettings,
      macOS: darwinSettings,
      windows: windowsSettings,
      linux: linuxSettings,
    );
    await plugin.initialize(
      settings: settings,
      // 点击通知把主窗口带回前台：托盘驻留时窗口多半是隐藏的，
      // 用户从系统通知进入应用必须先还原窗口。
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
    _initialized = true;
  }

  static void _onNotificationTap(NotificationResponse response) {
    unawaited(_restoreMainWindow());
  }

  static Future<void> _restoreMainWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'notification',
        operation: 'tap',
        message: '点击通知后还原主窗口失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 发一条通知。
  ///
  /// `flutter_local_notifications` 22.x 把 `show()` 由位置参数改成了命名参数
  /// （`id` / `title` / `body` / `notificationDetails` / `payload`），
  /// 把调用收敛到这里，插件后续再改 API 也只需要动这一个地方。
  static Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
    String? payload,
  }) async {
    await ensureInitialized();
    await plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  /// 幂等初始化：多处调用只有第一次真正执行。
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    await init();
  }

  /// 请求通知权限。Android 13+ 需要显式授权，Windows / iOS 已在 init 中处理。
  static Future<void> requestPermission() async {
    await ensureInitialized();
  }

  /// 设置页「发送测试通知」：让用户当场验证系统通知链路是否畅通。
  static Future<void> showTestNotification() {
    return show(
      id: 1,
      title: 'PCelechron 通知测试',
      body: '能看到这条通知，说明系统通知已正常工作。成绩变动与作业截止提醒都会走同一条链路。',
      details: gradeChangeDetails,
    );
  }

  // ===== 应用内更新的下载进度通知 =====

  /// 下载进度通知的固定 id 与 Windows 进度条 id（更新同一 id 的通知不会
  /// 反复弹横幅；Windows 上 updateProgressBar 是原地刷新）。
  static const int downloadNotificationId = 9000;
  static const String downloadProgressBarId = 'app-update-download';

  /// 下载进度通知：Windows 带原生进度条（label 必须初始非空，后续才能更新）；
  /// macOS 只发开始/完成两条横幅，进度看应用内对话框。
  static NotificationDetails downloadProgressDetails({double? value}) {
    return NotificationDetails(
      macOS: const DarwinNotificationDetails(
        presentBanner: true,
        presentSound: false,
        presentBadge: false,
        presentList: true,
      ),
      windows: WindowsNotificationDetails(
        progressBars: <WindowsProgressBar>[
          WindowsProgressBar(
            id: downloadProgressBarId,
            status: '正在下载更新',
            value: value,
            // label 初始必须非空，后续 updateProgressBar 才能继续更新它。
            label: value == null ? '准备中…' : '${(value * 100).round()}%',
          ),
        ],
      ),
    );
  }

  /// 原地刷新 Windows 下载通知的进度条；其他平台无此能力，静默跳过。
  static Future<void> updateDownloadProgress(
    double value, {
    String? label,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await plugin
          .resolvePlatformSpecificImplementation<
              FlutterLocalNotificationsWindows>()
          ?.updateProgressBar(
            notificationId: downloadNotificationId,
            progressBar: WindowsProgressBar(
              id: downloadProgressBarId,
              status: '正在下载更新',
              value: value.clamp(0.0, 1.0),
              label: label,
            ),
          );
    } on Object catch (error) {
      // 进度条刷新失败不影响下载本身（如通知服务尚未就绪）。
      DiagnosticLogService.instance.record(
        module: 'notification',
        operation: 'updateProgress',
        message: '刷新下载进度通知失败',
        error: error,
      );
    }
  }

  /// 成绩变动提醒通道
  static const NotificationDetails gradeChangeDetails = NotificationDetails(
    iOS: DarwinNotificationDetails(
      presentSound: true,
      presentBadge: true,
      presentBanner: true,
      presentList: true,
      sound: 'default',
      badgeNumber: 0,
    ),
    macOS: DarwinNotificationDetails(
      presentSound: true,
      presentBadge: true,
      presentBanner: true,
      presentList: true,
      sound: 'default',
      badgeNumber: 0,
    ),
    windows: WindowsNotificationDetails(),
  );

  /// DDL 截止提醒通道
  static const NotificationDetails ddlReminderDetails = NotificationDetails(
    iOS: DarwinNotificationDetails(
      presentSound: true,
      presentBadge: true,
      presentBanner: true,
      presentList: true,
      sound: 'default',
      badgeNumber: 0,
    ),
    macOS: DarwinNotificationDetails(
      presentSound: true,
      presentBadge: true,
      presentBanner: true,
      presentList: true,
      sound: 'default',
      badgeNumber: 0,
    ),
    windows: WindowsNotificationDetails(),
  );
}
