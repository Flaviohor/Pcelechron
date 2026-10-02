import 'dart:async';
import 'dart:io';

/// 浙大主机「共享 ingress 钉扎」：绕行校外线路黑洞。
///
/// 2026-10 实测（pktmon 抓包 + check-host 全球对测）：校外部分线路
/// （杭州电信家宽、手机热点）到 classroom/zdbk/tgmedia 等服务器的真实 IP
/// 会被静默黑洞——TCP SYN 发出后零入向包，而境外探测点全部可达，校园网
/// 内正常。这些 vhost 同时由共享 ingress（`courses.zju.edu.cn` 当前解析到
/// 的 Tengine）按 SNI/Host 服务，其通配证书 `*.zju.edu.cn` 覆盖一层子域。
///
/// 通过 [HttpOverrides] 给进程内所有 [HttpClient] 挂 connectionFactory：
/// 清单内主机改连 ingress 地址；TLS 的 SNI 与证书校验仍按原域名进行
/// （[SecureSocket.secure] 的 host 参数），安全强度与直连一致。ingress
/// 不可用时整体退回与原版完全相同的直连路径。
///
/// 注意：设置了 connectionFactory 后，https 的 TLS 握手由本工厂负责
/// （SDK 不再自动包装），因此这里对 https 显式 [SecureSocket.secure]。
///
/// 唯一例外：`tgmedia.cmc.zju.edu.cn` 是两层子域，不在通配证书 SAN 里，
/// 经 ingress 访问需放行该张浙大证书（见 [_isZjuWildcardCertificate]）。
/// 该通道只承载一次性 ST ticket 与 PHP 会话 cookie，不传输长效凭据。
class ZjuIngressFallback extends HttpOverrides {
  /// ingress 锚点。不硬编码 IP：每次连接重新解析，ZJU 换入口地址时自动
  /// 跟随；校园网内该域名同样解析到本机可达的 ingress，行为不变。
  static const String ingressHost = 'courses.zju.edu.cn';

  /// 已验证由 ingress 正确服务（SNI 路由正确 + 证书校验可过）的主机。
  static const Set<String> pinnedHosts = {
    'classroom.zju.edu.cn',
    'zdbk.zju.edu.cn',
    'tgmedia.cmc.zju.edu.cn',
  };

  /// 钉扎路径各阶段上限。正常 ~0.5s 内完成；超时即退回直连，
  /// 保证最坏情况仍与旧版行为一致。
  static const Duration _pinTcpTimeout = Duration(seconds: 4);
  static const Duration _pinTlsTimeout = Duration(seconds: 8);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // 仅 tgmedia 经 ingress 时证书主机名不匹配：限定主机 + 浙大通配证书
    // 特征（含真实 CA 签发链，自签名伪证书的 issuer 与 subject 相同，
    // 不会命中 TrustAsia 检查）。
    bool allowTgmediaCertificate(X509Certificate cert, String host, int port) {
      return host == 'tgmedia.cmc.zju.edu.cn' &&
          _isZjuWildcardCertificate(cert);
    }

    client.badCertificateCallback = allowTgmediaCertificate;
    client.connectionFactory = (uri, proxyHost, proxyPort) => _connect(
          uri,
          proxyHost,
          proxyPort,
          context,
          (cert) => allowTgmediaCertificate(cert, uri.host, uri.port),
        );
    return client;
  }

  static Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
    SecurityContext? context,
    bool Function(X509Certificate) onBadCertificate,
  ) async {
    final isSecure = uri.isScheme('https');
    final port = uri.port;

    if (proxyHost != null) {
      // 走代理：与原版一致，只连代理本身，隧道与 TLS 由 HttpClient 处理。
      return Socket.startConnect(proxyHost, proxyPort ?? port);
    }
    if (!pinnedHosts.contains(uri.host)) {
      // 非钉扎主机：完全复刻 SDK 默认直连路径。
      return isSecure
          ? SecureSocket.startConnect(uri.host, port,
              context: context, onBadCertificate: onBadCertificate)
          : Socket.startConnect(uri.host, port);
    }

    // 钉扎主机：TCP 连 ingress，TLS 按原域名握手。
    final pinned = await Socket.startConnect(ingressHost, port);
    Socket? raw;
    try {
      raw = await pinned.socket.timeout(_pinTcpTimeout);
      if (!isSecure) {
        return ConnectionTask.fromSocket(
            Future<Socket>.value(raw), pinned.cancel);
      }
      final secure = await SecureSocket.secure(
        raw,
        host: uri.host,
        context: context,
        onBadCertificate: onBadCertificate,
      ).timeout(_pinTlsTimeout);
      return ConnectionTask.fromSocket(
          Future<Socket>.value(secure), () => secure.destroy());
    } on Object {
      pinned.cancel();
      raw?.destroy();
    }
    // ingress 不可用：退回直连（与未挂 override 之前完全一致）。
    return isSecure
        ? SecureSocket.startConnect(uri.host, port,
            context: context, onBadCertificate: onBadCertificate)
        : Socket.startConnect(uri.host, port);
  }

  /// ingress 为 tgmedia 出示的是 `*.zju.edu.cn` 通配证书（SAN 只覆盖一层
  /// 子域）。仅当证书主题确为浙大通配证书、且由公共 CA（TrustAsia）签发
  /// 时放行——自签名伪证书无法同时满足这两点。
  static bool _isZjuWildcardCertificate(X509Certificate certificate) {
    final subject = certificate.subject;
    final issuer = certificate.issuer;
    return subject.contains('*.zju.edu.cn') &&
        subject.contains('浙江大学') &&
        issuer.contains('TrustAsia');
  }
}
