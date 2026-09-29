import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/http/github_service.dart';

class CreditsPage extends StatefulWidget {
  final String version;
  const CreditsPage({required this.version, super.key});

  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage> {
  /// 本分支（Windows 桌面端）的维护者，不随网络变化
  static const List<String> maintainers = ['Kepler16f', 'Flaviohor'];

  /// 上游的设计人员，随致谢一并保留
  static const List<String> designers = ['nosig', '空之探险队的 Kate'];

  /// 上游开发人员，优先取自 GitHub 接口，失败时退回默认名单
  List<String> _upstreamContributors = [];
  bool _isLoading = true;
  final _githubService = GitHubService();
  final _httpClient = HttpClient();

  @override
  void initState() {
    super.initState();
    _loadUpstreamContributors();
  }

  Future<void> _loadUpstreamContributors() async {
    try {
      var result = await _githubService.getContributors(_httpClient);
      // 无论是否有错误，都使用返回的 contributors 列表
      // GitHubService 保证即使出错也会返回默认作者名单
      setState(() {
        _upstreamContributors = result.item2;
        _isLoading = false;
      });
    } catch (e) {
      // 如果 GitHubService 本身抛出异常
      // 则使用 GitHubService 中的默认名单
      setState(() {
        _upstreamContributors = GitHubService.defaultContributors;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  /// 每行两人，行间留白；奇数个时末行只占左半
  Widget _buildNameGrid(List<String> names) {
    List<Widget> rows = [];
    for (int i = 0; i < names.length; i += 2) {
      List<Widget> children = [];

      children.add(
        Expanded(
          child: Text(
            names[i],
            textAlign: TextAlign.center,
          ),
        ),
      );

      if (i + 1 < names.length) {
        children.add(
          Expanded(
            child: Text(
              names[i + 1],
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      rows.add(
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.center,
          verticalDirection: VerticalDirection.down,
          children: children,
        ),
      );

      if (i + 2 < names.length) {
        rows.add(const SizedBox(height: 12));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: rows,
      ),
    );
  }

  /// 上游名单依赖网络，加载中显示菊花
  Widget _buildUpstreamGrid() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: CupertinoActivityIndicator(),
      );
    }
    return _buildNameGrid(_upstreamContributors);
  }

  Widget _buildSectionHeader(String title) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildGroupHeader(String title) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: const Color(0x00000000),
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            const CelechronSliverTextHeader(subtitle: '关于'),
            SliverToBoxAdapter(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    height: 64,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset(
                        "assets/logo.png",
                        height: 108,
                      ),
                      const SizedBox(
                        width: 8,
                      ),
                      Column(
                        children: [
                          const Text(
                            'Pcelechron',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 32,
                            ),
                          ),
                          Text(
                            '${widget.version} 版本',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Celechron的PC版本构建，目前已支持Windows/Mac OS，基于上游1.3.0，\n有任何问题请到项目仓库反馈，\n目前应用图标仅为临时占位作用，如系侵权请在GitHub上联系作者更换',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: CupertinoDynamicColor.resolve(
                                  CupertinoColors.secondaryLabel, context),
                            ),
                          ),
                        ],
                      )
                    ],
                  ),
                  const SizedBox(
                    height: 24,
                  ),
                  _buildSectionHeader('制作人员'),
                  _buildNameGrid(maintainers),
                  const SizedBox(
                    height: 32,
                  ),
                  _buildSectionHeader('上游制作人员'),
                  _buildGroupHeader('🧑‍💻开发'),
                  _buildUpstreamGrid(),
                  const SizedBox(
                    height: 24,
                  ),
                  _buildGroupHeader('🎨设计'),
                  _buildNameGrid(designers),
                ],
              ),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '本程序采用 GPLv3 协议开源',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.secondaryLabel, context)),
                  ),
                  const SizedBox(
                    height: 4,
                  ),
                  Text(
                    'github.com/Flaviohor/Celechron',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel, context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
