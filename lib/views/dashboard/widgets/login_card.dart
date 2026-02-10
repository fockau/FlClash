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
///
/// - 卡片里只显示两个按钮：登录 / 更新订阅并导入
/// - API域名/邮箱/密码/订阅备注 用弹窗输入
/// - 右上角历史记录入口保留
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
          child: XBoardLoginCard(
            onAfterImport: (profile) async {
              // ignore: use_build_context_synchronously
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已导入并更新：${profile.label ?? "XBoard"}')),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// XBoard 登录卡片本体：卡片只放按钮，输入全在弹窗里
class XBoardLoginCard extends ConsumerStatefulWidget {
  const XBoardLoginCard({
    super.key,
    this.title = 'XBoard',
    this.defaultLabel = 'King',
    this.onAfterImport,
  });

  final String title;

  /// 默认订阅备注（可在弹窗修改）
  final String defaultLabel;

  /// 导入完成回调（可选）
  final Future<void> Function(Profile importedProfile)? onAfterImport;

  @override
  ConsumerState<XBoardLoginCard> createState() => _XBoardLoginCardState();
}

class _XBoardLoginCardState extends ConsumerState<XBoardLoginCard> {
  bool _loading = false;

  /// 当前激活账号缓存
  String _baseUrl = '';
  String _email = '';
  String? _authData; // e.g. token string from data.auth_data
  String? _cookie; // *_session=...
  String? _subscribeUrl;
  int _lastFetchedAtMs = 0;

  /// 订阅备注（用于按“订阅名”去重）
  String _subLabel = '';

  /// 历史账号列表（仅保存：baseUrl/email/auth/cookie/label/subscribeUrl）
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

  // storage keys
  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentEmail = 'xboard_current_email';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentLabel = 'xboard_current_label';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kProfiles = 'xboard_profiles_json';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  // ---------- util ----------
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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

  // ---------- storage ----------
  Future<void> _saveCurrent({
    required String baseUrl,
    required String email,
    required String authData,
    required String cookie,
    required String lastSubscribeUrl,
    required String label,
    required String profileId,
  }) async {
    final sp = await _sp();
    await sp.setString(_kCurrentBaseUrl, baseUrl);
    await sp.setString(_kCurrentEmail, email);
    await sp.setString(_kCurrentAuthData, authData);
    await sp.setString(_kCurrentCookie, cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, lastSubscribeUrl);
    await sp.setString(_kCurrentLabel, label);
    await sp.setString(_kCurrentProfileId, profileId);
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
    await sp.setString(_kProfiles, jsonEncode(profiles.map((e) => e.toJson()).toList()));
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

  Future<void> _deleteLoginProfile(_LoginProfile p) async {
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
    final email = sp.getString(_kCurrentEmail) ?? '';
    final auth = sp.getString(_kCurrentAuthData) ?? '';
    final cookie = sp.getString(_kCurrentCookie) ?? '';
    final sub = sp.getString(_kCurrentLastSubscribeUrl) ?? '';
    final label = sp.getString(_kCurrentLabel) ?? '';

    final profiles = await _loadProfiles();

    if (!mounted) return;
    setState(() {
      _baseUrl = base.isNotEmpty ? base : (profiles.isNotEmpty ? profiles.first.baseUrl : '');
      _email = email;
      _authData = auth.isEmpty ? null : auth;
      _cookie = cookie.isEmpty ? null : cookie;
      _subscribeUrl = sub.isEmpty ? null : sub;
      _subLabel = (label.isNotEmpty ? label : widget.defaultLabel);
      _profiles = profiles;
    });
  }

  // ---------- dialogs ----------
  Future<void> _showLoginDialog() async {
    final baseCtrl = TextEditingController(text: _baseUrl);
    final emailCtrl = TextEditingController(text: _email);
    final pwdCtrl = TextEditingController(text: '');
    final labelCtrl = TextEditingController(text: (_subLabel.isNotEmpty ? _subLabel : widget.defaultLabel));

    final res = await showDialog<_LoginDialogResult>(
      context: context,
      barrierDismissible: !_loading,
      builder: (ctx) {
        return CommonDialog(
          title: 'XBoard 登录',
          actions: [
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      final base = _normBaseUrl(baseCtrl.text);
                      final email = emailCtrl.text.trim();
                      final pwd = pwdCtrl.text;
                      final label = labelCtrl.text.trim();
                      Navigator.of(ctx).pop(
                        _LoginDialogResult(
                          baseUrl: base,
                          email: email,
                          password: pwd,
                          label: label.isEmpty ? widget.defaultLabel : label,
                        ),
                      );
                    },
              child: const Text('登录'),
            ),
          ],
          child: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextField(
                    controller: baseCtrl,
                    enabled: !_loading,
                    decoration: const InputDecoration(
                      labelText: 'API / 面板域名',
                      hintText: 'https://example.com',
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailCtrl,
                    enabled: !_loading,
                    decoration: const InputDecoration(labelText: '邮箱'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pwdCtrl,
                    enabled: !_loading,
                    decoration: const InputDecoration(labelText: '密码（不会保存）'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: labelCtrl,
                    enabled: !_loading,
                    decoration: const InputDecoration(
                      labelText: '订阅备注（用于去重）',
                      hintText: '例如：King',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '提示：导入时按“订阅备注”去重；同名只保留一条并更新。',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (res == null) return;

    if (!_validateBaseUrl(res.baseUrl)) {
      _toast('面板域名必须以 http:// 或 https:// 开头');
      return;
    }
    if (res.email.isEmpty || res.password.isEmpty) {
      _toast('请输入邮箱和密码');
      return;
    }

    setState(() {
      _baseUrl = res.baseUrl;
      _email = res.email;
      _subLabel = res.label;
    });

    await _login(
      baseUrl: res.baseUrl,
      email: res.email,
      password: res.password,
      label: res.label,
    );
  }

  // ---------- network ----------
  Future<void> _login({
    required String baseUrl,
    required String email,
    required String password,
    required String label,
  }) async {
    setState(() => _loading = true);
    try {
      final url = '$baseUrl/api/v1/passport/auth/login';
      final resp = await _dio.post(
        url,
        data: jsonEncode({'email': email, 'password': password}),
      );

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast('登录失败：HTTP ${resp.statusCode ?? "unknown"}');
        return;
      }

      final a = _extractAuthData(resp.data);
      if (a.isEmpty) {
        _toast('登录成功但未找到 data.auth_data（返回结构不一致）');
        return;
      }

      final setCookies = <String>[];
      final raw = resp.headers.map['set-cookie'];
      if (raw != null) setCookies.addAll(raw);
      final cookie = _extractSessionCookieFromSetCookie(setCookies);

      final pid = _makeProfileId(baseUrl, email);

      setState(() {
        _authData = a;
        _cookie = cookie.isEmpty ? null : cookie;
      });

      await _saveCurrent(
        baseUrl: baseUrl,
        email: email,
        authData: a,
        cookie: cookie,
        lastSubscribeUrl: _subscribeUrl ?? '',
        label: label,
        profileId: pid,
      );

      await _upsertProfile(
        _LoginProfile(
          id: pid,
          baseUrl: baseUrl,
          email: email,
          authData: a,
          cookie: cookie,
          lastSubscribeUrl: _subscribeUrl ?? '',
          label: label,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      _toast('登录成功（已写入历史）');

      await _fetchSubscribe(showToast: true);
    } catch (e) {
      _toast('错误：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetchSubscribe({required bool showToast}) async {
    final base = _normBaseUrl(_baseUrl);
    final a = _authData;

    if (a == null || a.isEmpty) {
      _toast('未登录：请先登录');
      return;
    }
    if (!_validateBaseUrl(base)) {
      _toast('面板域名必须以 http:// 或 https:// 开头');
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
        _toast('获取订阅失败：HTTP ${resp.statusCode ?? "unknown"}');
        return;
      }

      final sub = _extractSubscribeUrl(resp.data);
      if (sub.isEmpty) {
        _toast('获取成功，但没有 data.subscribe_url');
        return;
      }

      final setCookies = <String>[];
      final raw = resp.headers.map['set-cookie'];
      if (raw != null) setCookies.addAll(raw);
      final newCookie = _extractSessionCookieFromSetCookie(setCookies);
      final finalCookie = newCookie.isNotEmpty ? newCookie : (_cookie ?? '');

      if (!mounted) return;
      setState(() {
        _subscribeUrl = sub;
        _cookie = finalCookie.isEmpty ? null : finalCookie;
        _lastFetchedAtMs = DateTime.now().millisecondsSinceEpoch;
      });

      final sp = await _sp();
      final pid = sp.getString(_kCurrentProfileId) ?? '';
      await _saveCurrent(
        baseUrl: base,
        email: _email,
        authData: a,
        cookie: finalCookie,
        lastSubscribeUrl: sub,
        label: _subLabel.isNotEmpty ? _subLabel : widget.defaultLabel,
        profileId: pid,
      );

      if (pid.isNotEmpty) {
        final profiles = await _loadProfiles();
        final idx = profiles.indexWhere((x) => x.id == pid);
        if (idx >= 0) {
          profiles[idx] = profiles[idx].copyWith(
            cookie: finalCookie,
            lastSubscribeUrl: sub,
            label: _subLabel.isNotEmpty ? _subLabel : profiles[idx].label,
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
            authData: a,
            baseUrl: base,
            email: _email,
          );
          await _saveProfiles(profiles);
          if (mounted) setState(() => _profiles = profiles);
        }
      }

      if (showToast) _toast('已获取最新订阅链接');
    } catch (e) {
      _toast('错误：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 按“订阅备注（label）”去重导入：
  /// - 已存在同名：更新第一条，其余删除
  /// - 不存在：创建并更新
  Future<void> _importByLabelDedupAndUpdate() async {
    await _fetchSubscribe(showToast: false);

    final label = (_subLabel.trim().isNotEmpty ? _subLabel.trim() : widget.defaultLabel);
    final url = (_subscribeUrl ?? '').trim();

    if (url.isEmpty) {
      _toast('暂无订阅链接：请先登录并获取订阅');
      return;
    }

    final profiles = ref.read(profilesProvider);
    final sameLabel = profiles.where((p) => (p.label ?? '').trim() == label).toList();

    Profile target;

    if (sameLabel.isNotEmpty) {
      target = sameLabel.first;

      // url/label 不一致则先修正
      if ((target.url).trim() != url) {
        final fixed = target.copyWith(url: url, label: label);
        globalState.appController.setProfile(fixed);
        target = fixed;
      } else if ((target.label ?? '').trim() != label) {
        final fixed = target.copyWith(label: label);
        globalState.appController.setProfile(fixed);
        target = fixed;
      }

      // 更新订阅
      await globalState.appController.updateProfile(target);

      // 删除重复项
      for (final dup in sameLabel.skip(1)) {
        await globalState.appController.deleteProfile(dup.id);
      }
    } else {
      // 新建并更新
      final created = Profile.normal(label: label, url: url);
      await globalState.appController.addProfile(created);
      await globalState.appController.updateProfile(created);
      target = created;
    }

    // 回调
    final cb = widget.onAfterImport;
    if (cb != null) {
      await cb(target);
    }

    globalState.showMessage(
      title: '完成',
      message: TextSpan(text: '订阅已导入并更新：${target.label ?? label}'),
    );
  }

  Future<void> _copySubscribe() async {
    final s = (_subscribeUrl ?? '').trim();
    if (s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    _toast('已复制订阅链接');
  }

  // ---------- history ----------
  Future<void> _useHistory(_LoginProfile p) async {
    setState(() {
      _baseUrl = p.baseUrl;
      _email = p.email;
      _authData = p.authData;
      _cookie = p.cookie.isEmpty ? null : p.cookie;
      _subscribeUrl = p.lastSubscribeUrl.isEmpty ? null : p.lastSubscribeUrl;
      _subLabel = p.label.isNotEmpty ? p.label : widget.defaultLabel;
    });

    await _saveCurrent(
      baseUrl: p.baseUrl,
      email: p.email,
      authData: p.authData,
      cookie: p.cookie,
      lastSubscribeUrl: p.lastSubscribeUrl,
      label: _subLabel,
      profileId: p.id,
    );

    _toast('已切换账号，正在刷新订阅…');
    await _fetchSubscribe(showToast: false);
  }

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) {
        final list = _profiles;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '历史登录',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                                // ignore: use_build_context_synchronously
                                Navigator.pop(context);
                              }
                              _toast('已清空历史记录');
                            },
                      child: const Text('清空'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('暂无历史记录（登录一次就会自动保存）'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = list[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${p.label.isNotEmpty ? p.label : "(无备注)"} · ${p.email}'),
                          subtitle: Text('${p.baseUrl}\n保存：${_fmtTime(p.savedAtMs)}'),
                          isThreeLine: true,
                          onTap: _loading
                              ? null
                              : () async {
                                  // ignore: use_build_context_synchronously
                                  Navigator.pop(context);
                                  await _useHistory(p);
                                },
                          trailing: IconButton(
                            tooltip: '删除',
                            onPressed: _loading
                                ? null
                                : () async {
                                    await _deleteLoginProfile(p);
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
    final hasSub = (_subscribeUrl != null && _subscribeUrl!.trim().isNotEmpty);
    final label = (_subLabel.trim().isNotEmpty ? _subLabel.trim() : widget.defaultLabel);

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
              tooltip: '历史登录',
              onPressed: _loading ? null : _showHistorySheet,
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.history),
                  if (_profiles.isNotEmpty)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_profiles.length}',
                          style: const TextStyle(fontSize: 10, color: Colors.white, height: 1),
                        ),
                      ),
                    ),
                ],
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
                loggedIn ? '已登录（auth_data 已缓存）' : '未登录',
                style: TextStyle(
                  color: loggedIn ? Colors.green : Theme.of(context).hintColor,
                ),
              ),
            ),
            if (hasSub)
              TextButton.icon(
                onPressed: _loading ? null : _copySubscribe,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制订阅'),
              ),
          ],
        ),

        const SizedBox(height: 8),

        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '订阅备注：$label${_lastFetchedAtMs > 0 ? '   ·   刷新：${_fmtTime(_lastFetchedAtMs)}' : ''}',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _loading ? null : _showLoginDialog,
                child: Text(_loading ? '处理中…' : '登录'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                onPressed: (!loggedIn || _loading) ? null : _importByLabelDedupAndUpdate,
                child: Text(_loading ? '处理中…' : '更新订阅并导入'),
              ),
            ),
          ],
        ),

        if (hasSub) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              _subscribeUrl!.trim(),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

class _LoginDialogResult {
  final String baseUrl;
  final String email;
  final String password;
  final String label;

  const _LoginDialogResult({
    required this.baseUrl,
    required this.email,
    required this.password,
    required this.label,
  });
}

class _LoginProfile {
  final String id;
  final String baseUrl;
  final String email;
  final String authData;
  final String cookie;
  final String lastSubscribeUrl;
  final String label;
  final int savedAtMs;

  const _LoginProfile({
    required this.id,
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.label,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'email': email,
        'authData': authData,
        'cookie': cookie,
        'lastSubscribeUrl': lastSubscribeUrl,
        'label': label,
        'savedAtMs': savedAtMs,
      };

  static _LoginProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    final baseUrl = (j['baseUrl'] ?? '').toString();
    final email = (j['email'] ?? '').toString();
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;

    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      label: (j['label'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }

  _LoginProfile copyWith({
    String? cookie,
    String? lastSubscribeUrl,
    String? label,
    int? savedAtMs,
    String? authData,
    String? baseUrl,
    String? email,
  }) {
    return _LoginProfile(
      id: id,
      baseUrl: baseUrl ?? this.baseUrl,
      email: email ?? this.email,
      authData: authData ?? this.authData,
      cookie: cookie ?? this.cookie,
      lastSubscribeUrl: lastSubscribeUrl ?? this.lastSubscribeUrl,
      label: label ?? this.label,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }
}
