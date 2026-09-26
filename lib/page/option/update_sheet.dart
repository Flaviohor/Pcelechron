import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:celechron/design/glass.dart';
import 'package:celechron/services/app_update_service.dart';
import 'package:celechron/utils/global.dart';

/// 应用内更新的液态玻璃弹窗（底部弹出面板）。
///
/// 状态完全由 [AppUpdateController] 驱动：检查中 / 已最新 / 发现新版本 /
/// 后台下载中（进度条）/ 下载完成 / 失败。下载在控制器后台继续，
/// 「隐藏」只是收起面板，进度可从系统通知与设置页入口副标题看到。
class UpdateSheet extends StatelessWidget {
  const UpdateSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<AppUpdateController>(tag: 'appUpdate');
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, bottom: 16 + bottomPadding),
      child: GlassSurface(
        borderRadius: const BorderRadius.all(Radius.circular(22)),
        specular: true,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Obx(() => _buildBody(context, controller)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppUpdateController controller) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(CupertinoIcons.arrow_down_circle, size: 22),
            const SizedBox(width: 8),
            Text(
              '软件更新',
              style: CupertinoTheme.of(context)
                  .textTheme
                  .textStyle
                  .copyWith(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(28, 28),
              child: Icon(
                CupertinoIcons.xmark,
                size: 18,
                color: CupertinoDynamicColor.resolve(
                    CupertinoColors.secondaryLabel, context),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ..._buildPhaseContent(context, controller),
      ],
    );
  }

  List<Widget> _buildPhaseContent(
      BuildContext context, AppUpdateController controller) {
    final textStyle = CupertinoTheme.of(context).textTheme.textStyle;
    final secondaryStyle = textStyle.copyWith(
      fontSize: 13,
      color: CupertinoDynamicColor.resolve(
          CupertinoColors.secondaryLabel, context),
    );

    switch (controller.phase.value) {
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
        return [
          SizedBox(
            height: 72,
            child: Row(
              children: [
                const CupertinoActivityIndicator(radius: 10),
                const SizedBox(width: 14),
                Text('正在检查更新…', style: textStyle),
              ],
            ),
          ),
        ];

      case AppUpdatePhase.upToDate:
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('当前已是最新版本（$appDisplayVersion）', style: textStyle),
          ),
          _primaryButton(context, '好', () => Navigator.of(context).pop()),
        ];

      case AppUpdatePhase.available:
        return [
          Text.rich(
            TextSpan(
              text: '发现新版本 v${controller.latestVersion.value}',
              style:
                  textStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
              children: [
                TextSpan(
                  text: '   当前 $appDisplayVersion',
                  style: secondaryStyle,
                ),
              ],
            ),
          ),
          if (controller.releaseNotes.value.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: CupertinoDynamicColor.resolve(
                    CupertinoColors.tertiarySystemFill, context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: Text(
                  controller.releaseNotes.value,
                  style: secondaryStyle.copyWith(height: 1.4),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _primaryButton(context, '后台下载', controller.startDownload),
              const SizedBox(width: 10),
              _textButton(context, '在浏览器打开', () async {
                if (controller.releaseUrl.value.isNotEmpty) {
                  await launchUrlString(controller.releaseUrl.value,
                      mode: LaunchMode.externalApplication);
                }
              }),
            ],
          ),
        ];

      case AppUpdatePhase.downloading:
        return [
          _GlassProgressBar(controller: controller),
          const SizedBox(height: 8),
          Obx(() {
            final received = controller.downloadedBytes.value;
            final total = controller.totalBytes.value;
            final pct = total > 0 ? '${(received * 100 / total).round()}%' : '';
            final bytes = total > 0
                ? '${_formatBytes(received)} / ${_formatBytes(total)}'
                : _formatBytes(received);
            return Text(
                '正在后台下载 v${controller.latestVersion.value}  '
                '$bytes${pct.isEmpty ? '' : '（$pct）'}',
                style: secondaryStyle);
          }),
          const SizedBox(height: 14),
          Row(
            children: [
              _primaryButton(
                  context, '隐藏（继续下载）', () => Navigator.of(context).pop()),
              const SizedBox(width: 10),
              _textButton(context, '取消下载', controller.cancelDownload),
            ],
          ),
        ];

      case AppUpdatePhase.downloaded:
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('v${controller.latestVersion.value} 下载完成。',
                style: textStyle),
          ),
          Text('安装时会提示关闭 PCelechron，按安装器指引操作即可。', style: secondaryStyle),
          const SizedBox(height: 14),
          Row(
            children: [
              _primaryButton(context, '立即安装', controller.installDownloaded),
              const SizedBox(width: 10),
              _textButton(context, '稍后', () => Navigator.of(context).pop()),
            ],
          ),
        ];

      case AppUpdatePhase.failed:
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('操作失败', style: textStyle),
          ),
          Text(
            controller.errorMessage.value.isEmpty
                ? '网络不可用或 GitHub 暂时无法访问'
                : controller.errorMessage.value,
            style: secondaryStyle,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _primaryButton(context, '重试', () => controller.checkForUpdate()),
              const SizedBox(width: 10),
              _textButton(context, '关闭', () => Navigator.of(context).pop()),
            ],
          ),
        ];
    }
  }

  Widget _primaryButton(
      BuildContext context, String label, VoidCallback onPressed) {
    final accent = CupertinoTheme.of(context).primaryColor;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: GlassPill(
        color: accent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoDynamicColor.resolve(accent, context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _textButton(
      BuildContext context, String label, VoidCallback onPressed) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: CupertinoDynamicColor.resolve(
              CupertinoColors.secondaryLabel, context),
        ),
      ),
    );
  }
}

class _GlassProgressBar extends StatelessWidget {
  const _GlassProgressBar({required this.controller});

  final AppUpdateController controller;

  @override
  Widget build(BuildContext context) {
    final accent = CupertinoTheme.of(context).primaryColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: Obx(() {
          final total = controller.totalBytes.value;
          final fraction = total > 0
              ? (controller.downloadedBytes.value / total).clamp(0.0, 1.0)
              : 0.0;
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: CupertinoDynamicColor.resolve(
                    CupertinoColors.quaternarySystemFill, context),
              ),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      colors: [
                        CupertinoDynamicColor.resolve(accent, context),
                        CupertinoDynamicColor.resolve(accent, context)
                            .withValues(alpha: 0.65),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1048576) {
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
