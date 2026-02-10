// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dashboard 外层卡片（用于 enum.dart 的 DashboardWidget）
/// - 卡片只展示按钮：登录 / 更新订阅并导入
/// - 右上角：历史记录（保留不变）
class XBoardLoginDashboardCard extends ConsumerWidget {
  const XBoardLoginDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: getWidgetHeight(2),
      child: CommonCard(
        info: const Info(label: 'XBoard', iconData: Icons.login),
        onPressed: () {},
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: XBoardLoginCard(title: 'XBoard'),
        ),
      ),
    );
  }
}

/// XBoard 登录卡片本体（不套 Card，外层已经是 CommonCard）
/// - 弹窗输入：API域名/邮箱/密码/订阅备注（=订阅名）
/// - 更新订阅并导入：
///   1) getSubscribe 拿到最新 subscribe_url
///   2) 按「订阅名」(label) 去重：存在则更新并删重复，不存在则创建并更新
class XBoardLoginCard extends ConsumerStatefulWidget {
  const XBoardLoginCard({
    super.key,
    required this.title,
  });

  final String title;

  @override
  ConsumerState<XBoardLoginCard> createState() => _XBoardLoginCardState();
}

class _XBoardLoginCardState extends ConsumerState<XBoardLoginCard> {
  final _baseUrlCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();

  bool _loading = false;

  String? _authData; // e.g. "Bearer xxx"
  String? _cookie; // *_session=...
  String? _lastSubscribeUrl;
  int _lastFetchedAtMs = 0;

  List<_LoginProfile> _profiles = [];

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      sendTimeout: const Duration(seconds: 12),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      responseType: ResponseType.json,
      validateStatus: (_) => true,
    ),
  );

  // ---------- i18n ----------
  bool get _isZh {
    final code = Localizations.localeOf(context).languageCode.toLowerCase();
    return code.startsWith('zh');
  }

  String _t(String zh, String en) => _isZh ? zh : en;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- util ----------
  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  bool _validateBaseUrl(String base) {
    return base.startsWith('http://') || base.startsWith('https://');
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _extractAuthData(dynamic loginJson) {
    if (loginJson is Map) {
      final data = loginJson['data'];
      if (data is Map && data['auth_data'] != null) return '${data['auth_data']}';
    }
    return '';
  }

  String _extractSubscribeUrl(dynamic j) {
    if (j is Map) {
      final data = j['data'];
      if (data is Map && data['subscribe_url'] != null) return '${data['subscribe_url']}';
    }
    return '';
  }

  /// 从 set-cookie 里提取 session cookie（尽量泛化，不绑死 server_name）
  String _extractSessionCookieFromSetCookie(List<String> setCookies) {
    if (setCookies.isEmpty) return '';
    for (final c in setCookies) {
      final m = RegExp(r'([A-Za-z0-9_]+_session=[^;]+)').firstMatch(c);
      if (m != null) return m.group(1) ?? '';
    }
    final m2 = RegExp(r'^([^;]+)').firstMatch(setCookies.first);
    return m2?.group(1) ?? '';
  }

  String _makeProfileId(String baseUrl, String email) {
    final s = '${baseUrl.toLowerCase()}|${email.toLowerCase()}';
    return s.codeUnits.fold<int>(0, (a, b) => (a * 131 + b) & 0x7fffffff).toString();
  }

  /// 订阅名（label）生成策略（确保永远不为空）
  /// - 有备注：用备注（你要的“按订阅名去重”核心）
  /// - 没备注：fallback 用 email
  /// - 都没有：fallback 用 XBoard
  String _buildSubscriptionLabel() {
    final r = _remarkCtrl.text.trim();
    if (r.isNotEmpty) return r;
    final e = _emailCtrl.text.trim();
    if (e.isNotEmpty) return 'XBoard-$e';
    return 'XBoard';
  }

  // ---------- storage ----------
  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kCurrentRemark = 'xboard_current_remark';
  static const _kProfiles = 'xboard_profiles_json';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  Future<void> _saveCurrent({
    required String baseUrl,
    required String authData,
    required String cookie,
    required String lastSubscribeUrl,
    required String profileId,
    required String remark,
  }) async {
    final sp = await _sp();
    await sp.setString(_kCurrentBaseUrl, baseUrl);
    await sp.setString(_kCurrentAuthData, authData);
    await sp.setString(_kCurrentCookie, cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, lastSubscribeUrl);
    await sp.setString(_kCurrentProfileId, profileId);
    await sp.setString(_kCurrentRemark, remark);
  }

  Future<List<_LoginProfile>> _loadProfiles() async {
    final sp = await _sp();
    final s = sp.getString(_kProfiles);
    if (s == null || s.isEmpty) return [];
    try {
      final j = jsonDecode(s);
      if (j is List) {
        final out = <_LoginProfile>[];
        for (final it in j) {
          final p = _LoginProfile.fromJson(it);
          if (p != null) out.add(p);
        }
        out.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
        return out;
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveProfiles(List<_LoginProfile> profiles) async {
    final sp = await _sp();
    final list = profiles.map((e) => e.toJson()).toList();
    await sp.setString(_kProfiles, jsonEncode(list));
  }

  Future<void> _upsertProfile(_LoginProfile p) async {
    final profiles = await _loadProfiles();
    final idx = profiles.indexWhere((x) => x.id == p.id);
    if (idx >= 0) {
      profiles[idx] = p;
    } else {
      profiles.add(p);
    }
    profiles.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
    await _saveProfiles(profiles);
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _deleteProfile(_LoginProfile p) async {
    final sp = await _sp();
    final profiles = await _loadProfiles();
    profiles.removeWhere((x) => x.id == p.id);
    await _saveProfiles(profiles);

    final cur = sp.getString(_kCurrentProfileId) ?? '';
    if (cur == p.id) {
      await sp.setString(_kCurrentProfileId, '');
    }
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _loadLocal() async {
    final sp = await _sp();
    final base = sp.getString(_kCurrentBaseUrl) ?? '';
    final a = sp.getString(_kCurrentAuthData) ?? '';
    final c = sp.getString(_kCurrentCookie) ?? '';
    final sub = sp.getString(_kCurrentLastSubscribeUrl) ?? '';
    final pid = sp.getString(_kCurrentProfileId) ?? '';
    final remark = sp.getString(_kCurrentRemark) ?? '';

    final profiles = await _loadProfiles();
    final fallbackBase = profiles.isNotEmpty ? profiles.first.baseUrl : '';
    final fallbackEmail = profiles.isNotEmpty ? profiles.first.email : '';
    final fallbackRemark = profiles.isNotEmpty ? profiles.first.remark : '';

    _baseUrlCtrl.text = (base.isNotEmpty ? base : fallbackBase);
    _emailCtrl.text = fallbackEmail;
    _remarkCtrl.text = (remark.isNotEmpty ? remark : fallbackRemark);

    if (!mounted) return;
    setState(() {
      _authData = a.isEmpty ? null : a;
      _cookie = c.isEmpty ? null : c;
      _lastSubscribeUrl = sub.isEmpty ? null : sub;
      _profiles = profiles;
    });

    if (pid.isNotEmpty && !_profiles.any((e) => e.id == pid)) {
      await sp.setString(_kCurrentProfileId, '');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _emailCtrl.dispose();
    _pwdCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  // ---------- dialogs ----------
  Future<void> _showLoginDialog() async {
    // 预填：baseUrl / email / remark；密码永远不保存
    _pwdCtrl.text = '';

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: !_loading,
      builder: (ctx) {
        return AlertDialog(
          title: Text(_t('XBoard 登录', 'XBoard Login')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _baseUrlCtrl,
                  enabled: !_loading,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: _t('API / 面板域名', 'API / Panel URL'),
                    hintText: 'https://example.com',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _emailCtrl,
                  enabled: !_loading,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: _t('邮箱', 'Email')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pwdCtrl,
                  enabled: !_loading,
                  obscureText: true,
                  decoration: InputDecoration(labelText: _t('密码（不会保存）', 'Password (not saved)')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _remarkCtrl,
                  enabled: !_loading,
                  decoration: InputDecoration(
                    labelText: _t('订阅备注（订阅名，用于去重）', 'Subscription name (dedup key)'),
                    hintText: _t('例如：King', 'e.g. King'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(ctx).pop(false),
              child: Text(_t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: _loading ? null : () => Navigator.of(ctx).pop(true),
              child: Text(_t('登录', 'Login')),
            ),
          ],
        );
      },
    );

    if (ok == true) {
      await _login();
    }
  }

  // ---------- network ----------
  Future<void> _login() async {
    final base = _normBaseUrl(_baseUrlCtrl.text);
    final email = _emailCtrl.text.trim();
    final pwd = _pwdCtrl.text;

    if (!_validateBaseUrl(base)) {
      _toast(_t('面板域名必须以 http:// 或 https:// 开头', 'Panel URL must start with http:// or https://'));
      return;
    }
    if (email.isEmpty || pwd.isEmpty) {
      _toast(_t('请输入邮箱和密码', 'Please enter email and password'));
      return;
    }

    setState(() => _loading = true);
    try {
      final url = '$base/api/v1/passport/auth/login';
      final resp = await _dio.post(
        url,
        data: jsonEncode({'email': email, 'password': pwd}),
      );

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast(_t('登录失败：HTTP ', 'Login failed: HTTP ') + '${resp.statusCode ?? 'unknown'}');
        return;
      }

      final j = resp.data;
      final a = _extractAuthData(j);
      if (a.isEmpty) {
        _toast(_t('登录成功但未找到 data.auth_data（返回结构不一致）', 'Login ok but data.auth_data not found'));
        return;
      }

      final setCookies = <String>[];
      final raw = resp.headers.map['set-cookie'];
      if (raw != null) setCookies.addAll(raw);
      final cookie = _extractSessionCookieFromSetCookie(setCookies);

      final pid = _makeProfileId(base, email);
      final remark = _remarkCtrl.text.trim();

      setState(() {
        _authData = a;
        _cookie = cookie.isEmpty ? null : cookie;
      });

      await _saveCurrent(
        baseUrl: base,
        authData: a,
        cookie: cookie,
        lastSubscribeUrl: _lastSubscribeUrl ?? '',
        profileId: pid,
        remark: remark,
      );

      await _upsertProfile(
        _LoginProfile(
          id: pid,
          baseUrl: base,
          email: email,
          remark: remark,
          authData: a,
          cookie: cookie,
          lastSubscribeUrl: _lastSubscribeUrl ?? '',
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      _toast(_t('登录成功（已写入历史）', 'Login success (saved to history)'));

      // 登录后自动刷新订阅（不导入）
      await _fetchSubscribe(showToast: true);
    } catch (e) {
      _toast(_t('错误：', 'Error: ') + '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetchSubscribe({required bool showToast}) async {
    final base = _normBaseUrl(_baseUrlCtrl.text);
    final a = _authData;

    if (a == null || a.isEmpty) {
      _toast(_t('未登录：请先登录', 'Not logged in'));
      return;
    }
    if (!_validateBaseUrl(base)) {
      _toast(_t('面板域名必须以 http:// 或 https:// 开头', 'Panel URL must start with http:// or https://'));
      return;
    }

    setState(() => _loading = true);
    try {
      final headers = <String, dynamic>{
        'Accept': 'application/json',
        'Authorization': a,
      };
      final c = _cookie;
      if (c != null && c.isNotEmpty) headers['Cookie'] = c;

      final url = '$base/api/v1/user/getSubscribe';
      final resp = await _dio.get(url, options: Options(headers: headers));

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast(_t('获取订阅失败：HTTP ', 'Fetch subscribe failed: HTTP ') + '${resp.statusCode ?? 'unknown'}');
        return;
      }

      final j = resp.data;
      final sub = _extractSubscribeUrl(j);
      if (sub.isEmpty) {
        _toast(_t('获取成功，但没有 data.subscribe_url', 'Fetch ok but data.subscribe_url missing'));
        return;
      }

      final setCookies = <String>[];
      final raw = resp.headers.map['set-cookie'];
      if (raw != null) setCookies.addAll(raw);
      final newCookie = _extractSessionCookieFromSetCookie(setCookies);
      final finalCookie = newCookie.isNotEmpty ? newCookie : (_cookie ?? '');

      if (!mounted) return;
      setState(() {
        _lastSubscribeUrl = sub;
        _cookie = finalCookie.isEmpty ? null : finalCookie;
        _lastFetchedAtMs = DateTime.now().millisecondsSinceEpoch;
      });

      final sp = await _sp();
      final pid = sp.getString(_kCurrentProfileId) ?? '';
      await _saveCurrent(
        baseUrl: base,
        authData: a,
        cookie: finalCookie,
        lastSubscribeUrl: sub,
        profileId: pid,
        remark: _remarkCtrl.text.trim(),
      );

      // 同步到历史
      if (pid.isNotEmpty) {
        final profiles = await _loadProfiles();
        final idx = profiles.indexWhere((x) => x.id == pid);
        if (idx >= 0) {
          profiles[idx] = profiles[idx].copyWith(
            cookie: finalCookie,
            lastSubscribeUrl: sub,
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
            authData: a,
            remark: _remarkCtrl.text.trim(),
          );
          await _saveProfiles(profiles);
          if (mounted) setState(() => _profiles = profiles);
        }
      }

      if (showToast) _toast(_t('已获取最新订阅链接', 'Got latest subscription URL'));
    } catch (e) {
      _toast(_t('错误：', 'Error: ') + '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 版本 B：严格按订阅名（label）去重
  /// - 需要 label（我们保证永不为空：备注 > email > XBoard）
  /// - 同名存在：更新 URL + updateProfile + 删除同名重复项
  /// - 同名不存在：创建 + updateProfile
  Future<void> _importOrUpdateSubscriptionIntoFlClash({
    required String subscribeUrl,
    required String label,
  }) async {
    final scaffold = globalState.homeScaffoldKey.currentState;

    final run = (Future<void> Function() job) async {
      if (scaffold?.mounted == true) {
        await scaffold!.loadingRun(job);
      } else {
        await job();
      }
    };

    await run(() async {
      final url = subscribeUrl.trim();
      final wantLabel = label.trim();
      if (url.isEmpty) return;

      // 版本B：严格按名称；但我们上层保证 wantLabel 永不为空
      final profiles = ref.read(profilesProvider);
      final sameLabel = profiles.where((p) => ((p.label ?? '').trim() == wantLabel)).toList();

      Profile target;

      if (sameLabel.isNotEmpty) {
        target = sameLabel.first;

        var fixed = target;
        if (fixed.url.trim() != url) {
          fixed = fixed.copyWith(url: url);
          globalState.appController.setProfile(fixed);
        }

        // 更新订阅内容
        await globalState.appController.updateProfile(fixed);

        // 删除同名重复项
        for (final dup in sameLabel.skip(1)) {
          await globalState.appController.deleteProfile(dup.id);
        }

        // 若它是当前订阅，则更新后立即应用
        if (ref.read(currentProfileIdProvider) == fixed.id) {
          await globalState.appController.applyProfile(silence: true);
        }

        globalState.showMessage(
          title: _t('完成', 'Done'),
          message: TextSpan(text: _t('订阅已更新：', 'Subscription updated: ') + (fixed.label ?? wantLabel)),
        );
        return;
      }

      // 没有同名：新建 + 更新
      final created = Profile.normal(label: wantLabel, url: url);
      await globalState.appController.addProfile(created);
      await globalState.appController.updateProfile(created);

      if (ref.read(currentProfileIdProvider) == created.id) {
        await globalState.appController.applyProfile(silence: true);
      }

      globalState.showMessage(
        title: _t('完成', 'Done'),
        message: TextSpan(text: _t('订阅已导入并更新：', 'Subscription imported & updated: ') + (created.label ?? wantLabel)),
      );
    });
  }

  Future<void> _updateAndImport() async {
    final loggedIn = (_authData != null && _authData!.isNotEmpty);
    if (!loggedIn) {
      _toast(_t('未登录：请先登录', 'Not logged in'));
      return;
    }

    // 1) 获取最新 subscribe_url
    await _fetchSubscribe(showToast: false);

    final sub = _lastSubscribeUrl;
    if (sub == null || sub.isEmpty) {
      _toast(_t('暂无订阅链接', 'No subscription URL'));
      return;
    }

    // 2) 导入/更新到 FlClash（版本B：按订阅名去重）
    final label = _buildSubscriptionLabel();
    try {
      setState(() => _loading = true);
      await _importOrUpdateSubscriptionIntoFlClash(subscribeUrl: sub, label: label);
    } catch (e) {
      _toast(_t('导入失败：', 'Import failed: ') + '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copySubscribe() async {
    final s = _lastSubscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    _toast(_t('已复制订阅链接', 'Subscription URL copied'));
  }

  Future<void> _useProfile(_LoginProfile p) async {
    _baseUrlCtrl.text = p.baseUrl;
    _emailCtrl.text = p.email;
    _remarkCtrl.text = p.remark;
    _pwdCtrl.text = '';

    if (!mounted) return;
    setState(() {
      _authData = p.authData;
      _cookie = p.cookie.isEmpty ? null : p.cookie;
      _lastSubscribeUrl = p.lastSubscribeUrl.isEmpty ? null : p.lastSubscribeUrl;
    });

    await _saveCurrent(
      baseUrl: p.baseUrl,
      authData: p.authData,
      cookie: p.cookie,
      lastSubscribeUrl: p.lastSubscribeUrl,
      profileId: p.id,
      remark: p.remark,
    );

    _toast(_t('已切换账号，正在刷新订阅…', 'Switched account, refreshing…'));
    await _fetchSubscribe(showToast: false);
  }

  // ---------- history UI ----------
  Widget _historyIconWithBadge({required int count}) {
    // 不用 Badge 组件，最大化兼容性
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.history),
        if (count > 0)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onPrimary,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _t('历史登录', 'Login History'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              final sp = await _sp();
                              await sp.remove(_kProfiles);
                              await sp.remove(_kCurrentProfileId);
                              if (mounted) {
                                setState(() => _profiles = []);
                                Navigator.pop(context);
                              }
                              _toast(_t('已清空历史记录', 'History cleared'));
                            },
                      child: Text(_t('清空', 'Clear')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_t('暂无历史记录（登录一次就会自动保存）', 'No history (saved after login)')),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = _profiles[i];
                        final remark = p.remark.trim();
                        final title = (remark.isNotEmpty)
                            ? '$remark  ·  ${p.email.isEmpty ? '-' : p.email}'
                            : '${p.email.isEmpty ? '-' : p.email}';

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(title),
                          subtitle: Text(
                            '${p.baseUrl}\n${_t('保存：', 'Saved: ')}${_fmtTime(p.savedAtMs)}',
                          ),
                          isThreeLine: true,
                          onTap: _loading
                              ? null
                              : () async {
                                  Navigator.pop(context);
                                  await _useProfile(p);
                                },
                          trailing: IconButton(
                            tooltip: _t('删除', 'Delete'),
                            onPressed: _loading
                                ? null
                                : () async {
                                    await _deleteProfile(p);
                                    if (mounted) setState(() {});
                                  },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final loggedIn = (_authData != null && _authData!.isNotEmpty);
    final hasSub = (_lastSubscribeUrl != null && _lastSubscribeUrl!.isNotEmpty);
    final label = _buildSubscriptionLabel();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: _t('历史登录', 'History'),
              onPressed: _loading ? null : _showHistorySheet,
              icon: _historyIconWithBadge(count: _profiles.length),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 卡片主体只放按钮：登录 / 更新订阅并导入
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _loading ? null : _showLoginDialog,
                child: Text(_loading ? _t('处理中…', 'Working…') : _t('登录', 'Login')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                onPressed: (!loggedIn || _loading) ? null : _updateAndImport,
                child: Text(_loading ? _t('处理中…', 'Working…') : _t('更新订阅并导入', 'Update & Import')),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),
        Row(
          children: [
            Icon(loggedIn ? Icons.verified : Icons.info_outline, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                loggedIn
                    ? _t('已登录（auth_data 已缓存）', 'Logged in (auth cached)')
                    : _t('未登录', 'Not logged in'),
                style: TextStyle(color: loggedIn ? Colors.green : Theme.of(context).hintColor),
              ),
            ),
            IconButton(
              tooltip: _t('仅刷新订阅', 'Refresh only'),
              onPressed: (!loggedIn || _loading) ? null : () => _fetchSubscribe(showToast: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),

        // 显示将会用于去重的订阅名（避免用户不清楚为什么会合并/删除）
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _t('订阅名：', 'Name: ') + label,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
          ),
        ),

        if (hasSub) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              _lastSubscribeUrl!,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _t('最后刷新：', 'Last refresh: ') + _fmtTime(_lastFetchedAtMs),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
              TextButton.icon(
                onPressed: _loading ? null : _copySubscribe,
                icon: const Icon(Icons.copy, size: 16),
                label: Text(_t('复制', 'Copy')),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 历史登录数据模型（只存 token/cookie/订阅，不存密码）
class _LoginProfile {
  final String id;
  final String baseUrl;
  final String email;
  final String remark; // 订阅备注（用于生成 label/去重）
  final String authData;
  final String cookie;
  final String lastSubscribeUrl;
  final int savedAtMs;

  const _LoginProfile({
    required this.id,
    required this.baseUrl,
    required this.email,
    required this.remark,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'email': email,
        'remark': remark,
        'authData': authData,
        'cookie': cookie,
        'lastSubscribeUrl': lastSubscribeUrl,
        'savedAtMs': savedAtMs,
      };

  static _LoginProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    final baseUrl = (j['baseUrl'] ?? '').toString();
    final email = (j['email'] ?? '').toString();
    final remark = (j['remark'] ?? '').toString();
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;

    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      remark: remark,
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }

  _LoginProfile copyWith({
    String? cookie,
    String? lastSubscribeUrl,
    int? savedAtMs,
    String? authData,
    String? remark,
  }) {
    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      remark: remark ?? this.remark,
      authData: authData ?? this.authData,
      cookie: cookie ?? this.cookie,
      lastSubscribeUrl: lastSubscribeUrl ?? this.lastSubscribeUrl,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }
}
