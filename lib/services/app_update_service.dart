import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import 'package:celechron/http/zjuServices/exceptions.dart';
import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:celechron/services/notification_service.dart';
import 'package:celechron/utils/global.dart';

/// 应用内更新的状态机。
enum AppUpdatePhase {
  /// 尚未检查
  idle,

  /// 正在检查 GitHub Releases
  checking,

  /// 已是最新版本
  upToDate,

  /// 发现新版本，等待用户决定
  available,

  /// 后台下载中（可关闭窗口，进度走系统通知）
  downloading,

  /// 下载完成，等待安装
  downloaded,

  /// 检查或下载失败（errorMessage 有详情）
  failed,
}

/// 应用内更新：检测 GitHub Releases → 后台下载（系统通知展示进度）→ 启动安装包。
///
/// 更新源是本仓库的 GitHub Releases（`browser_download_url` 无需登录即可下载；
/// CI 的 Actions 产物下载需要鉴权，不能作为更新源）。发布一个新版本时，
/// Windows 安装包命名需含 `windows-<arch>-setup.exe`、macOS 需含 `-macos.dmg`，
/// 现有 CI 产物命名即满足。
class AppUpdateController extends GetxController {
  static const _releasesApi =
      'https://api.github.com/repos/Flaviohor/Pcelechron/releases?per_page=15';

  final phase = AppUpdatePhase.idle.obs;
  final latestVersion = ''.obs;
  final releaseNotes = ''.obs;
  final releaseUrl = ''.obs;
  final downloadedBytes = 0.obs;
  final totalBytes = 0.obs;
  final errorMessage = ''.obs;

  String? _assetUrl;
  String? _assetName;
  File? _downloadedFile;
  bool _cancelRequested = false;
  final HttpClient _httpClient = HttpClient();

  bool get isBusy =>
      phase.value == AppUpdatePhase.checking ||
      phase.value == AppUpdatePhase.downloading;

  /// 设置页「检查更新」入口的副标题文案。
  String get subtitleText {
    switch (phase.value) {
      case AppUpdatePhase.idle:
        return '检查 GitHub Releases 上的新版本';
      case AppUpdatePhase.checking:
        return '正在检查…';
      case AppUpdatePhase.upToDate:
        return '已是最新版本';
      case AppUpdatePhase.available:
        return '发现新版本 v${latestVersion.value}，点按查看';
      case AppUpdatePhase.downloading:
        final total = totalBytes.value;
        final pct = total > 0
            ? '${(downloadedBytes.value * 100 / total).round()}%'
            : '…';
        return '正在后台下载 $pct';
      case AppUpdatePhase.downloaded:
        return '下载完成，点按安装';
      case AppUpdatePhase.failed:
        return '检查失败：${errorMessage.value.isEmpty ? '网络不可用' : errorMessage.value}';
    }
  }

  /// 当前版本号三元组（appDisplayVersion 形如 "PC-1.3.4"）。
  List<int> get _currentVersion =>
      _parseVersion(appDisplayVersion.replaceFirst('PC-', ''));

  /// 检查更新（启动静默检查与手动检查共用）。
  ///
  /// 本项目除 Windows x64 外的各架构是**单独发布 release** 的，一个 release
  /// 往往只含一种架构的安装包。因此这里从新到旧遍历 releases，**取第一个
  /// 包含当前平台架构安装包的 release** 作为候选；不含匹配资产的 release
  /// （如 x64 专用版对 arm64 用户）整体忽略——既不提示更新，也不提示去
  /// 手动下载。全部忽略时按「已是最新」处理。
  Future<void> checkForUpdate() async {
    if (isBusy) return;
    phase.value = AppUpdatePhase.checking;
    errorMessage.value = '';
    try {
      final request = await _httpClient.getUrl(Uri.parse(_releasesApi)).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw requestTimeout());
      request.headers.add('Accept', 'application/vnd.github+json');
      request.headers.add('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw requestTimeout(),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw ExceptionWithMessage(
            'GitHub Releases 接口返回 HTTP ${response.statusCode}');
      }
      final releases = decodeJsonList(body,
          context: 'GitHub Releases 接口；HTTP ${response.statusCode}');

      for (final raw in releases) {
        final release = asStringMap(raw);
        if (release == null) continue;
        final tag = asString(release['tag_name']) ?? '';
        final version =
            RegExp(r'\d+(?:\.\d+)+').firstMatch(tag)?.group(0) ?? '';
        if (version.isEmpty) continue;
        // 本平台架构的安装包：没有就跳过这个 release（它是别的架构单独发的）。
        if (!_pickAsset(asDynamicList(release['assets']) ?? const [])) {
          continue;
        }
        latestVersion.value = version;
        releaseUrl.value = asString(release['html_url']) ?? '';
        releaseNotes.value = (asString(release['body']) ?? '').trim();
        break;
      }

      if (latestVersion.value.isEmpty) {
        // 没有任何 release 带当前平台的安装包：按用户约定直接忽略。
        phase.value = AppUpdatePhase.upToDate;
        return;
      }
      if (_compareVersion(_parseVersion(latestVersion.value), _currentVersion) >
          0) {
        phase.value = AppUpdatePhase.available;
      } else {
        phase.value = AppUpdatePhase.upToDate;
      }
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'update',
        operation: 'check',
        message: '检查更新失败',
        error: error,
        stackTrace: stackTrace,
      );
      errorMessage.value = shortErrorText(error);
      phase.value = AppUpdatePhase.failed;
    }
  }

  /// 按当前平台与架构挑选安装包资产，命中时写入 [_assetName]/[_assetUrl]。
  ///
  /// - Windows：`*windows-<arch>-setup.exe`（arch 取自 Dart VM 的平台串，
  ///   windows_x64 / windows_arm64 / windows_ia32 各归各位）
  /// - macOS：`*-macos.dmg`
  /// - 其它平台不做自动匹配（返回 false，对应的 release 全部忽略）。
  bool _pickAsset(List<Object?> assets) {
    _assetUrl = null;
    _assetName = null;
    String suffix;
    if (Platform.isWindows) {
      final vm = Platform.version;
      final arch = vm.contains('arm64')
          ? 'arm64'
          : vm.contains('ia32')
              ? 'x86'
              : 'x64';
      suffix = '-windows-$arch-setup.exe';
    } else if (Platform.isMacOS) {
      suffix = '-macos.dmg';
    } else {
      return false;
    }
    for (final raw in assets) {
      final asset = asStringMap(raw);
      if (asset == null) continue;
      final name = asString(asset['name']) ?? '';
      final url = asString(asset['browser_download_url']) ?? '';
      if (name.toLowerCase().endsWith(suffix) && url.isNotEmpty) {
        _assetName = name;
        _assetUrl = url;
        return true;
      }
    }
    return false;
  }

  /// 开始后台下载。窗口可以关闭（托盘驻留），进度经系统通知展示。
  void startDownload() {
    if (_assetUrl == null || phase.value == AppUpdatePhase.downloading) return;
    _cancelRequested = false;
    downloadedBytes.value = 0;
    totalBytes.value = 0;
    errorMessage.value = '';
    phase.value = AppUpdatePhase.downloading;
    unawaited(_download());
  }

  /// 取消下载：中断流并删除半成品文件，回到「发现新版本」状态。
  void cancelDownload() {
    _cancelRequested = true;
  }

  Future<void> _download() async {
    try {
      await NotificationService.ensureInitialized();
      await NotificationService.show(
        id: NotificationService.downloadNotificationId,
        title: 'PCelechron 更新',
        body: '开始下载 v${latestVersion.value}（${_assetName ?? '安装包'}）',
        details: NotificationService.downloadProgressDetails(),
      );

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_assetName');
      if (await file.exists()) {
        await file.delete();
      }

      final request = await _httpClient
          .openUrl('GET', Uri.parse(_assetUrl!))
          .timeout(const Duration(seconds: 30),
              onTimeout: () => throw requestTimeout());
      final response = await request.close().timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw requestTimeout(),
          );
      if (response.statusCode != HttpStatus.ok) {
        throw ExceptionWithMessage('下载返回 HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0 ? response.contentLength : 0;
      totalBytes.value = total;

      final sink = file.openWrite();
      var received = 0;
      var lastNotified = 0;
      try {
        await for (final chunk in response) {
          if (_cancelRequested) {
            await sink.close();
            await _deleteQuietly(file);
            phase.value = AppUpdatePhase.available;
            await NotificationService.show(
              id: NotificationService.downloadNotificationId,
              title: 'PCelechron 更新',
              body: '已取消下载 v${latestVersion.value}。',
              details: NotificationService.downloadProgressDetails(value: 0),
            );
            return;
          }
          received += chunk.length;
          sink.add(chunk);
          downloadedBytes.value = received;
          // Windows 上每 ~2% 原地刷新一次进度条（不重复弹横幅）；
          // macOS 的进度通知能力有限，只在开始与结束时提醒。
          if (total > 0 && received - lastNotified >= total ~/ 50) {
            lastNotified = received;
            await NotificationService.updateDownloadProgress(
              received / total,
              label:
                  '${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
            );
          }
        }
        await sink.flush();
        await sink.close();
      } on Object {
        await sink.close();
        rethrow;
      }

      _downloadedFile = file;
      await NotificationService.updateDownloadProgress(1, label: '下载完成');
      await NotificationService.show(
        id: NotificationService.downloadNotificationId,
        title: 'PCelechron 更新',
        body: 'v${latestVersion.value} 下载完成，可在设置的「检查更新」中安装。',
        details: NotificationService.downloadProgressDetails(value: 1),
      );
      phase.value = AppUpdatePhase.downloaded;
    } on Object catch (error, stackTrace) {
      if (_cancelRequested) return;
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'update',
        operation: 'download',
        message: '下载更新包失败',
        error: error,
        stackTrace: stackTrace,
      );
      errorMessage.value = shortErrorText(error);
      phase.value = AppUpdatePhase.failed;
      await NotificationService.show(
        id: NotificationService.downloadNotificationId,
        title: 'PCelechron 更新',
        body: '下载失败：${shortErrorText(error)}',
        details: NotificationService.downloadProgressDetails(value: 0),
      );
    }
  }

  /// 启动下载好的安装包。Windows 直接执行 Inno Setup 安装器；
  /// macOS 用 open 挂载 dmg。应用保持运行，由用户按安装器指引操作。
  Future<void> installDownloaded() async {
    final file = _downloadedFile;
    if (file == null || !await file.exists()) {
      errorMessage.value = '安装包不存在，请重新下载';
      phase.value = AppUpdatePhase.failed;
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.start(file.path, const [],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[file.path]);
      }
    } on Object catch (error, stackTrace) {
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'update',
        operation: 'install',
        message: '启动安装包失败',
        error: error,
        stackTrace: stackTrace,
      );
      errorMessage.value = shortErrorText(error);
      phase.value = AppUpdatePhase.failed;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {/* 半成品删不掉也无妨 */}
  }

  static List<int> _parseVersion(String text) {
    final match = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(text);
    if (match == null) return const [0, 0, 0];
    int part(int i) => int.tryParse(match.group(i) ?? '') ?? 0;
    return [part(1), part(2), part(3)];
  }

  static int _compareVersion(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }
}
