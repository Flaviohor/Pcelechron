import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import 'package:celechron/model/option.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/utils/platform_features.dart';

/// 桌面端托盘常驻：关窗不退出，后台刷新定时器继续跑，成绩 / DDL 通知照常发。
///
/// 「真后台」的关键在于后台刷新定时器跑在应用主进程内
/// （DesktopBackgroundRefreshScheduler），只有进程活着它才会跑。窗口默认
/// 隐藏到托盘而不是退出进程，移动端「关掉界面照样提醒」的语义在桌面端
/// 就变成了「关掉窗口照样提醒」。设置页可以关闭该行为，恢复关窗即退出。
///
/// 托盘菜单：显示主窗口 / 立即刷新 / 退出。
class DesktopTrayService with WindowListener {
  DesktopTrayService._();

  static final DesktopTrayService instance = DesktopTrayService._();

  final SystemTray _tray = SystemTray();
  final Menu _menu = Menu();
  bool _started = false;

  Future<void> start() async {
    if (!PlatformFeatures.isDesktop || _started) return;
    _started = true;

    // 关窗事件先经 WindowListener 拦截，由 [onWindowClose] 决定隐藏还是退出。
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    try {
      await _tray.initSystemTray(
        title: 'PCelechron',
        // Windows 托盘需要多尺寸 .ico（assets/tray_icon.ico），macOS / Linux 用 PNG。
        iconPath:
            Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/logo.png',
        toolTip: 'PCelechron — 浙大时间管理器',
      );
      await _menu.buildFrom([
        MenuItemLabel(label: '显示主窗口', onClicked: (_) => showMainWindow()),
        MenuItemLabel(label: '立即刷新', onClicked: (_) => _refreshFromTray()),
        MenuSeparator(),
        MenuItemLabel(label: '退出', onClicked: (_) => unawaited(exitApp())),
      ]);
      await _tray.setContextMenu(_menu);
      _tray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          unawaited(showMainWindow());
        } else if (eventName == kSystemTrayEventRightClick) {
          _tray.popUpContextMenu();
        }
      });
    } on Object catch (error, stackTrace) {
      // 托盘不可用（如 Linux 缺 appindicator 运行库）只影响常驻入口，
      // 应用本身仍按「关窗即退出」工作。
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'tray',
        operation: 'init',
        message: '系统托盘初始化失败，关窗驻留功能不可用',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// 托盘菜单触发的一次完整刷新；与启动自动刷新共用同一入口。
  void _refreshFromTray() {
    try {
      final scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
      unawaited(scholar.value
          .refresh(onPartialUpdate: scholar.refresh)
          .whenComplete(scholar.refresh));
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        module: 'tray',
        operation: 'refresh',
        message: '托盘「立即刷新」未能启动',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> exitApp() async {
    try {
      await _tray.destroy();
    } on Object {/* 托盘已不在也无妨 */}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    // 不直接读 Option 构造器持有者，运行期从 Get 取，用户在设置里切换后立即生效。
    var closeToTray = true;
    try {
      closeToTray = Get.find<Option>(tag: 'option').closeToTray.value;
    } on Object {/* 选项尚未注册时按默认行为驻留 */}
    if (closeToTray) {
      await windowManager.hide();
    } else {
      await exitApp();
    }
  }
}
