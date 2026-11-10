import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/netdisk_service.dart';
import '../core/storage_service.dart';
import '../core/quark_account.dart';
import 'apple_theme.dart';
import 'local_qr_code.dart';
import 'quark_library_sheet.dart';

/// Opens the Apple-styled Netdisk QR Code Login & Account Management sheet
/// matching Android TV's `🗂我的云盘┃配置` (`我的夸父 / 我的优汐 / 我的嘟嘟 / 我的阿狸`).
Future<void> showNetdiskAccountSheet(
  BuildContext context,
  StorageService storage, {
  String? initialDriveKey,
  VoidCallback? onChanged,
  NetdiskService? service,
}) async {
  await showAppleModalSheet<void>(
    context: context,
    title: '我的云盘 · 扫码与账号配置',
    builder: (ctx) => _NetdiskAccountSheet(
      storage: storage,
      initialDriveKey: initialDriveKey,
      onChanged: onChanged,
      service: service,
    ),
  );
}

class _NetdiskAccountSheet extends StatefulWidget {
  final StorageService storage;
  final String? initialDriveKey;
  final VoidCallback? onChanged;
  final NetdiskService? service;

  const _NetdiskAccountSheet({
    required this.storage,
    this.initialDriveKey,
    this.onChanged,
    this.service,
  });

  @override
  State<_NetdiskAccountSheet> createState() => _NetdiskAccountSheetState();
}

class _NetdiskAccountSheetState extends State<_NetdiskAccountSheet>
    with WidgetsBindingObserver {
  late final NetdiskService _service =
      widget.service ??
      NetdiskService(quarkAccounts: widget.storage.quarkAccounts);
  String? _activeQrDriveKey;
  NetdiskQrSession? _qrSession;
  bool _loadingQr = false;
  String _qrStatusText = '';
  Timer? _pollTimer;
  int _qrAttempt = 0;
  int? _pollingAttempt;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (widget.initialDriveKey != null && widget.initialDriveKey!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startQrLogin(widget.initialDriveKey!);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _pollTimer?.cancel();
      return;
    }
    final session = _qrSession;
    if (session != null && _pollingAttempt == null) {
      _pollQr(_qrAttempt, session);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _qrAttempt++;
    _pollTimer?.cancel();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  NetdiskDriveInfo _driveByKey(String key) {
    return NetdiskService.drives.firstWhere(
      (d) => d.key == key,
      orElse: () => NetdiskService.drives.first,
    );
  }

  Future<void> _startQrLogin(String driveKey) async {
    final attempt = ++_qrAttempt;
    _pollTimer?.cancel();
    setState(() {
      _activeQrDriveKey = driveKey;
      _loadingQr = true;
      _qrSession = null;
      _qrStatusText = '正在连接${_driveByKey(driveKey).providerName}生成登录二维码…';
    });
    try {
      final session = await _service.createQrSession(driveKey);
      if (!mounted || attempt != _qrAttempt) return;
      setState(() {
        _loadingQr = false;
        _qrSession = session;
        _qrStatusText = _driveByKey(driveKey).appHint;
      });
      if (_foreground) _pollTimer = Timer(
        const Duration(seconds: 3),
        () => _pollQr(attempt, session),
      );
    } catch (_) {
      if (!mounted || attempt != _qrAttempt) return;
      setState(() {
        _loadingQr = false;
        _qrStatusText = '暂时无法获取登录二维码，请稍后刷新';
      });
    }
  }

  void _cancelQr() {
    _qrAttempt++;
    _pollTimer?.cancel();
    _activeQrDriveKey = null;
    _qrSession = null;
  }

  Future<void> _pollQr(int attempt, NetdiskQrSession session) async {
    bool current() =>
        mounted && ModalRoute.of(context)?.isCurrent != false &&
        attempt == _qrAttempt && identical(_qrSession, session);
    if (!current() || !_foreground || _pollingAttempt == attempt) return;
    _pollTimer?.cancel();
    _pollingAttempt = attempt;
    try {
      final res = await _service.pollQrStatus(session);
      if (!current()) return;
      if (res.state == NetdiskPollState.confirmed &&
          res.credential.isNotEmpty) {
        if (session.driveKey == 'quark' &&
            QuarkAccountSession.tryParseCredential(res.credential) == null) {
          setState(() => _qrStatusText = '账户验证未完成，请刷新二维码重试');
          return;
        }
        await widget.storage.setNetdiskCredential(
          session.driveKey,
          res.credential,
        );
        if (!current()) return;
        widget.onChanged?.call();
        setState(_cancelQr);
      } else {
        setState(() => _qrStatusText = res.message);
        if (res.state == NetdiskPollState.waiting ||
            res.state == NetdiskPollState.scanned) {
          if (_foreground) _pollTimer = Timer(
            const Duration(seconds: 3),
            () => _pollQr(attempt, session),
          );
        }
      }
    } catch (_) {
      if (current()) setState(() => _qrStatusText = '登录状态获取失败，请重试');
    } finally {
      if (_pollingAttempt == attempt) _pollingAttempt = null;
    }
  }

  Future<void> _showManualInputDialog(String driveKey) async {
    setState(_cancelQr);
    final drive = _driveByKey(driveKey);
    final stored = widget.storage.netdiskCredential(driveKey);
    final controller = TextEditingController(
      text: driveKey == 'quark'
          ? QuarkAccountSession.tryParseCredential(stored)?.cookie ?? stored
          : stored,
    );
    var saving = false;
    var error = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => Dialog(
          backgroundColor: Colors.transparent,
          child: AppleGlassSurface(
            padding: const EdgeInsets.all(22),
            borderRadius: BorderRadius.circular(26),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${drive.providerName} · 账号配置',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    maxLines: 3,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      hintText: '粘贴 Cookie 或 Token…',
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      error,
                      style: const TextStyle(color: AppleColors.systemRed),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      AppleCapsuleButton(
                        label: '取消',
                        compact: true,
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                      AppleCapsuleButton(
                        label: saving
                            ? '正在验证…'
                            : driveKey == 'quark'
                            ? '验证并保存'
                            : '保存配置',
                        primary: true,
                        compact: true,
                        onPressed: () async {
                          if (saving) return;
                          update(() {
                            saving = true;
                            error = '';
                          });
                          try {
                            var credential = controller.text.trim();
                            if (driveKey == 'quark' && credential.isNotEmpty) {
                              credential =
                                  (await widget.storage.quarkAccounts
                                          .validateCredential(credential))
                                      .toCredential();
                            }
                            if (!mounted ||
                                !ctx.mounted ||
                                ModalRoute.of(ctx)?.isCurrent == false)
                              return;
                            await widget.storage.setNetdiskCredential(
                              driveKey,
                              credential,
                            );
                            widget.onChanged?.call();
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (mounted) setState(() {});
                          } catch (_) {
                            if (ctx.mounted)
                              update(() {
                                saving = false;
                                error = '账户验证失败，请检查凭据或重新扫码';
                              });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Dialog exit animations may still use its controller on this frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> _rotateDriveOrder() async {
    final current = List<String>.from(widget.storage.driveOrder);
    if (current.length > 1) {
      final first = current.removeAt(0);
      current.add(first);
      await widget.storage.setDriveOrder(current);
      widget.onChanged?.call();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderLabels = widget.storage.driveOrder
        .map((k) {
          return switch (k) {
            'quark' => '夸父',
            'uc' => '优汐',
            'baidu' => '嘟嘟',
            'ali' => '阿狸',
            _ => k,
          };
        })
        .join(' > ');

    return SingleChildScrollView(
      key: const ValueKey('netdisk-account-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Priority Order Banner (matches TV's `盘序: 夸父>优汐>嘟嘟>阿狸`)
          AppleGlassSurface(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            borderRadius: BorderRadius.circular(18),
            color: const Color(0x9926262E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.arrow_up_arrow_down_circle_fill,
                      color: AppleColors.systemBlue,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '盘序优先：$orderLabels',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    AppleCapsuleButton(
                      icon: CupertinoIcons.refresh,
                      label: '切换盘序',
                      compact: true,
                      onPressed: _rotateDriveOrder,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '与电视端「🗂我的云盘┃配置」保持一致，支持优汐智1 / 夸父智1 / 嘟嘟无限2 / 阿狸原画',
                  style: TextStyle(color: Color(0x99EBEBF5), fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Active QR Code Scanner Box if a drive is selected
          if (_activeQrDriveKey != null) ...[
            _buildQrScannerCard(_driveByKey(_activeQrDriveKey!)),
            const SizedBox(height: 16),
          ],

          // 4 Netdisk Drives List
          for (final drive in NetdiskService.drives) ...[
            _buildDriveTile(drive),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildQrScannerCard(NetdiskDriveInfo drive) {
    final qrData = _qrSession?.qrContent ?? '';

    return Container(
      key: ValueKey('netdisk-qr-card-${drive.key}'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF0A84FF).withValues(alpha: 0.22),
            const Color(0xFF1C1C1E).withValues(alpha: 0.92),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF0A84FF).withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.qrcode_viewfinder,
                color: Color(0xFF5AC8FA),
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${drive.tvAlias}（${drive.providerName}）扫码登录',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(_cancelQr);
                },
                child: const Text(
                  '收起',
                  style: TextStyle(
                    color: Color(0xFF5AC8FA),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: 196,
            height: 196,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: _loadingQr
                ? const Center(child: CupertinoActivityIndicator(radius: 14))
                : qrData.isEmpty
                ? const Center(
                    child: Icon(
                      CupertinoIcons.exclamationmark_circle,
                      color: Colors.black54,
                      size: 36,
                    ),
                  )
                : LocalQrCode(data: qrData),
          ),
          const SizedBox(height: 12),
          Text(
            _qrStatusText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFEBEBF5),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              AppleCapsuleButton(
                key: ValueKey('netdisk-confirm-${drive.key}'),
                icon: CupertinoIcons.checkmark_seal,
                label: '检查登录状态',
                primary: true,
                compact: true,
                onPressed: () {
                  final session = _qrSession;
                  if (session != null) _pollQr(_qrAttempt, session);
                },
              ),
              AppleCapsuleButton(
                icon: CupertinoIcons.arrow_clockwise,
                label: '刷新二维码',
                compact: true,
                onPressed: () => _startQrLogin(drive.key),
              ),
              AppleCapsuleButton(
                icon: CupertinoIcons.doc_on_clipboard,
                label: '复制授权链接',
                compact: true,
                onPressed: () {
                  if (qrData.isEmpty) return;
                  Clipboard.setData(ClipboardData(text: qrData));
                  setState(() {
                    _qrStatusText = '已复制授权链接，可在浏览器或网盘 App 中打开';
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDriveTile(NetdiskDriveInfo drive) {
    final loggedIn = widget.storage.isNetdiskLoggedIn(drive.key);
    final isScanning = _activeQrDriveKey == drive.key;

    return Container(
      key: ValueKey('netdisk-tile-${drive.key}'),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isScanning
              ? [
                  const Color(0xFF0A84FF).withValues(alpha: 0.22),
                  const Color(0xFF20222C).withValues(alpha: 0.78),
                ]
              : [
                  const Color(0xFF2E2E36).withValues(alpha: 0.68),
                  const Color(0xFF1E1E24).withValues(alpha: 0.68),
                ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: loggedIn
              ? const Color(0xFF30D158).withValues(alpha: 0.48)
              : Colors.white.withValues(alpha: 0.14),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: loggedIn
                      ? const Color(0xFF30D158).withValues(alpha: 0.18)
                      : const Color(0xFF0A84FF).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  loggedIn ? CupertinoIcons.cloud_fill : CupertinoIcons.qrcode,
                  color: loggedIn
                      ? const Color(0xFF30D158)
                      : const Color(0xFF5AC8FA),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          drive.tvAlias,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            drive.providerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0x99EBEBF5),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '对应线路：${drive.lineBadges.join(" / ")}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xB3EBEBF5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3.5,
                ),
                decoration: BoxDecoration(
                  color: loggedIn
                      ? const Color(0xFF30D158).withValues(alpha: 0.20)
                      : const Color(0xFF3A3A42).withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: loggedIn
                        ? const Color(0xFF30D158).withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.14),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  loggedIn ? (drive.key == 'quark' ? '已登录' : '已配置') : '未登录',
                  style: TextStyle(
                    color: loggedIn
                        ? const Color(0xFF30D158)
                        : const Color(0x99EBEBF5),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (drive.key == 'quark' &&
              widget.storage.getNetdiskCred('quark').isNotEmpty) ...[
            const SizedBox(height: 12),
            AppleCapsuleButton(
              key: const ValueKey('quark-browse-files'),
              icon: CupertinoIcons.folder,
              label: '浏览网盘视频',
              compact: true,
              onPressed: () {
                setState(_cancelQr);
                showQuarkLibrarySheet(context, widget.storage);
              },
            ),
          ],
          const SizedBox(height: 10),
          Container(height: 0.5, color: Colors.white.withValues(alpha: 0.10)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppleCapsuleButton(
                  key: ValueKey('netdisk-scan-btn-${drive.key}'),
                  icon: CupertinoIcons.qrcode_viewfinder,
                  label: loggedIn ? '重新扫码' : '扫码登录',
                  primary: !loggedIn,
                  compact: true,
                  onPressed: () => _startQrLogin(drive.key),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppleCapsuleButton(
                  icon: CupertinoIcons.pencil,
                  label: '手动配置 Token',
                  compact: true,
                  onPressed: () => _showManualInputDialog(drive.key),
                ),
              ),
              if (loggedIn) ...[
                const SizedBox(width: 8),
                AppleCapsuleButton(
                  icon: CupertinoIcons.trash,
                  label: '退出',
                  destructive: true,
                  compact: true,
                  onPressed: () async {
                    setState(_cancelQr);
                    await widget.storage.setNetdiskCredential(drive.key, '');
                    widget.onChanged?.call();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
