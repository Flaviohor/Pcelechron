import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:celechron/services/notification_service.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:app_links/app_links.dart';

import 'package:celechron/model/scholar.dart';
import 'package:celechron/model/option.dart';
import 'package:celechron/page/home_page.dart';
import 'package:celechron/page/option/ecard_pay_page.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/services/refresh_coordinator.dart';
import 'package:celechron/worker/ecard_widget_messenger.dart';
import 'package:celechron/database/database_helper.dart';
import 'package:celechron/database/hive_paths.dart';
import 'package:celechron/services/desktop_tray_service.dart';
import 'package:celechron/utils/global.dart';
import 'package:celechron/utils/platform_features.dart';
import 'package:window_manager/window_manager.dart';

/// 应用级内嵌字体族名，与 pubspec.yaml 的 fonts 段保持一致。
const String kAppFontFamily = 'NotoSansSC';

/// 构建全局 Cupertino 主题，并让所有文本样式都使用内嵌字体。
///
/// 只设置 [CupertinoTextThemeData.textStyle] 并不够：按钮、导航栏、标签栏、
/// 选择器分别读取 `actionTextStyle` / `navTitleTextStyle` / `tabLabelTextStyle`
/// 等样式，若不逐一设置，它们仍会回退到系统字体。这里统一套用同一字体族。
CupertinoThemeData buildAppCupertinoTheme(BrightnessMode mode) {
  final CupertinoTextThemeData base = const CupertinoThemeData().textTheme;
  TextStyle withFont(TextStyle style) =>
      style.copyWith(fontFamily: kAppFontFamily);
  return CupertinoThemeData(
    brightness: mode == BrightnessMode.system
        ? null
        : mode == BrightnessMode.dark
            ? Brightness.dark
            : Brightness.light,
    scaffoldBackgroundColor: CupertinoColors.systemBackground,
    barBackgroundColor: CupertinoColors.systemBackground,
    textTheme: CupertinoTextThemeData(
      textStyle: withFont(base.textStyle),
      actionTextStyle: withFont(base.actionTextStyle),
      actionSmallTextStyle: withFont(base.actionSmallTextStyle),
      tabLabelTextStyle: withFont(base.tabLabelTextStyle),
      navTitleTextStyle: withFont(base.navTitleTextStyle),
      navLargeTitleTextStyle: withFont(base.navLargeTitleTextStyle),
      navActionTextStyle: withFont(base.navActionTextStyle),
      pickerTextStyle: withFont(base.pickerTextStyle),
      dateTimePickerTextStyle: withFont(base.dateTimePickerTextStyle),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ECardWidgetMessenger.installNativeHandler();

  // 桌面端窗口管理提前初始化：托盘常驻（关窗隐藏而非退出）依赖它拦截关闭事件。
  if (PlatformFeatures.isDesktop) {
    await windowManager.ensureInitialized();
  }

  // 尽可能早地声明前台活跃，Workmanager isolate 会据此安全让行。
  await RefreshCoordinator.setForegroundActive(true);

  // 初始化数据库
  // - 桌面端把 Hive 数据落到 APPDATA（`%APPDATA%\Celechron\Celechron`），
  //   移动端保持 Documents（避免破坏现有数据）。
  // - 第一次启动时若 Documents 下有 .hive 旧文件，一次性拷过来，
  //   旧文件保留由用户自行决定是否删除。
  // 见 lib/database/hive_paths.dart。
  final hiveRoot = await HivePaths.resolveHiveRoot();
  await HivePaths.migrateFromLegacyDocumentsIfNeeded(hiveRoot);
  Hive.init(hiveRoot.path);
  // Windows 上若上次进程被强杀，Hive 留下的 .lock 0 字节文件会卡住下一次的
  // openBox（mmap 锁未释放，errno=33）。这里清掉陈旧锁文件。
  await _purgeStaleHiveLocks(hiveRoot);
  var db = Get.put(DatabaseHelper(), tag: 'db');
  await db.init();

  // 注入数据观察项（相当于事件总线，更新这些变量将导致Widget重绘
  Get.put((await db.getScholar()).obs, tag: 'scholar');
  Get.put(db.getTaskList().obs, tag: 'taskList');
  Get.put(db.getTaskListUpdateTime().obs, tag: 'taskListLastUpdate');
  Get.put(db.getFlowList().obs, tag: 'flowList');
  Get.put(db.getFlowListUpdateTime().obs, tag: 'flowListLastUpdate');
  Get.put(db.getOption(), tag: 'option');
  Get.put(db.getFuse().obs, tag: 'fuse');

  // 托盘常驻依赖「关窗驻留」选项，因此放在 Option 注册之后启动。
  await DesktopTrayService.instance.start();

  runApp(const CelechronApp());

  var scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
  if (scholar.value.isLogan) {
    // 启动恢复只有一个自动刷新入口；会话重建由 Scholar.refresh 内部完成。
    // 用户此时手动刷新会复用并等待这一个 refresh Future。
    // 校园卡使用不同 HttpClient/User-Agent，等 Scholar 认证和抓取
    // 完成后再启动，避免两套 CAS 链路在启动瞬间互相干扰。
    unawaited(
      _refreshRestoredScholar(scholar)
          .whenComplete(ECardWidgetMessenger.update),
    );
  } else {
    unawaited(ECardWidgetMessenger.update());
  }
}

Future<void> _purgeStaleHiveLocks(Directory dir) async {
  try {
    if (!dir.existsSync()) return;
    for (final ent in dir.listSync(followLinks: false)) {
      if (ent is! File) continue;
      if (!ent.path.endsWith('.lock')) continue;
      try {
        ent.deleteSync();
      } on Object catch (_) {/* 仍被占用就不动，让 Hive 自行报错 */}
    }
  } on Object catch (_) {/* 失败也无所谓，开不了就让它正常报错 */}
}

Future<void> _refreshRestoredScholar(Rx<Scholar> scholar) async {
  GlobalStatus.isFirstScreenReq = true;
  try {
    await scholar.value.refresh(onPartialUpdate: scholar.refresh);
  } on Object catch (error, stackTrace) {
    // 启动刷新不阻断缓存数据展示，但异常仍进入诊断日志。
    DiagnosticLogService.instance.record(
      level: CelechronLogLevel.error,
      module: 'refresh',
      operation: 'startupRefresh',
      message: '启动自动刷新异常结束',
      error: error,
      stackTrace: stackTrace,
    );
  } finally {
    GlobalStatus.isFirstScreenReq = false;
    scholar.refresh();
  }
}

class CelechronApp extends StatefulWidget {
  const CelechronApp({super.key});

  @override
  State<CelechronApp> createState() => _CelechronAppState();
}

class _CelechronAppState extends State<CelechronApp>
    with WidgetsBindingObserver {
  Timer? _foregroundLeaseHeartbeat;
  StreamSubscription<Uri>? _appLinksSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startForegroundLease();

    // 监听AppLinks，用于跳转至付款码页面
    _initAppLinks();
    // 初始化通知
    _initNotification();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopForegroundLease();
    unawaited(_appLinksSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startForegroundLease();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stopForegroundLease();
    }
    if (state == AppLifecycleState.paused) {
      ECardWidgetMessenger.update();
    }
  }

  void _startForegroundLease() {
    unawaited(RefreshCoordinator.setForegroundActive(true));
    _foregroundLeaseHeartbeat ??= Timer.periodic(
      RefreshCoordinator.foregroundHeartbeatInterval,
      (_) => unawaited(RefreshCoordinator.setForegroundActive(true)),
    );
  }

  void _stopForegroundLease() {
    _foregroundLeaseHeartbeat?.cancel();
    _foregroundLeaseHeartbeat = null;
    unawaited(RefreshCoordinator.setForegroundActive(false));
  }

  @override
  Widget build(BuildContext context) {
    var brightnessMode = Get.find<Option>(tag: 'option').brightnessMode;
    return Obx(() => GetCupertinoApp(
          theme: buildAppCupertinoTheme(brightnessMode.value),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('zh'),
            Locale('en'),
          ],
          locale: const Locale('zh'),
          builder: (context, child) {
            final base = DefaultTextStyle.of(context).style;
            return DefaultTextStyle.merge(
              style: base.copyWith(fontFamily: kAppFontFamily),
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
            );
          },
          title: 'PCelechron',
          home: const HomePage(title: 'PCelechron'),
          initialRoute: '/',
          routes: {
            '/ecardpaypage': (context) => ECardPayPage(),
          },
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
        ));
  }

  /// 监听 `celechron://` 深度链接，用于跳转付款码页面。
  ///
  /// Windows 上这套机制依赖安装器把自定义协议写进注册表
  /// （`HKCU\Software\Classes\celechron`）；未注册时不会有任何事件进来，
  /// 属于功能不可用而非错误。但插件在初始化阶段可能抛异常，而这里跑在
  /// `initState` 里，异常会直接让首帧渲染失败，所以整体兜住并记入诊断日志。
  void _initAppLinks() {
    try {
      final appLinks = AppLinks();
      _appLinksSubscription = appLinks.uriLinkStream.listen(
        (uri) {
          if (uri.toString() == 'celechron://ecardpaypage') {
            navigator?.popUntil((route) =>
                !(route.settings.name?.endsWith('ecardpaypage') ?? false));
            navigator?.pushNamed('/ecardpaypage');
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          DiagnosticLogService.instance.record(
            level: CelechronLogLevel.warning,
            module: 'appLinks',
            operation: 'listen',
            message: '深度链接监听中断，付款码快捷方式不可用',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'appLinks',
        operation: 'init',
        message: '当前平台未能初始化深度链接（自定义协议未注册）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 通知初始化。各平台的初始化设置集中在 NotificationService 里，
  /// Windows 需要 Toast 的 appUserModelId / guid，之前这里只配了移动端。
  void _initNotification() {
    unawaited(NotificationService.requestPermission());
  }
}
