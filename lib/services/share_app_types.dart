/*
 * Plain values shared by share_app_service_io.dart and its web stub.
 */

class ShareApkInfo {
  final String path;
  final int splits;
  final int size;
  final String abi;
  const ShareApkInfo(
      {required this.path,
      required this.splits,
      required this.size,
      required this.abi});
  bool get shareable => path.isNotEmpty && splits == 0;
}

class ShareAppException implements Exception {
  final String code;
  const ShareAppException(this.code);
  @override
  String toString() => 'ShareAppException($code)';
}

/// How good an interface is for a visitor next to us (lower is better),
/// or null to leave it out. Android, Linux, macOS and Windows names.
int? shareInterfaceRank(String name) {
  final n = name.toLowerCase();
  const skip = [
    'rmnet', 'ccmni', 'tun', 'tap', 'dummy', 'v4-', 'clat', 'ppp', 'ipsec',
    'docker', 'veth', 'br-', 'virbr', 'vmnet', 'vboxnet', 'lxc', 'lxd',
    'podman', 'cni', 'flannel', 'zt', 'tailscale', 'wg', 'utun', 'awdl',
    'llw', 'anpi', 'bridge', 'vethernet', 'loopback', 'bluetooth', 'npcap',
  ];
  if (skip.any(n.startsWith) || n.contains('virtual') || n.contains('vpn')) {
    return null;
  }
  if (n.startsWith('ap') || n.startsWith('swlan') || n.startsWith('softap')) {
    return 0;
  }
  if (n.startsWith('wl') || n.startsWith('wi-fi') || n.startsWith('wifi') ||
      n.contains('wireless')) {
    return 1;
  }
  if (n.startsWith('eth') || n.startsWith('en') || n.startsWith('ethernet')) {
    return 2;
  }
  return 3;
}
