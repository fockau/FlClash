import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'; // ✅ 必须有
import 'package:shared_preferences/shared_preferences.dart';

/// Dashboard 外层卡片（用于 enum.dart 的 DashboardWidget）
/// ✅ 卡片只显示两个按钮：登录 / 更新订阅并写入
/// ✅ 输入在弹窗里
class XBoardLoginDashboardCard extends StatelessWidget {
  const XBoardLoginDashboardCard({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        info: const Info(label: 'XBoard', iconData: Icons.login),
        onPressed: () {},
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: const XBoardLoginCard(),
        ),
      ),
    );
  }
}

/// XBoard 登录卡片本体（不套 Card，外层已经是 CommonCard）
/// ✅ 输入全部弹窗化
/// ✅ 更新订阅会写入 FlClash（去重/命名/更新/必要时应用）
class XBoardLoginCard extends ConsumerStatefulWidget {
  const XBoardLoginCard({super.key});

  @override
  ConsumerState<XBoardLoginCard> createState() => _XBoardLoginCardState();
}

class _XBoardLoginCardState extends ConsumerState<XBoardLoginCard> {
  final _baseUrlCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();

  bool _loading = false;

  String? _authData; // 例如 "Bearer xxx"
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
    super.dispose();
  }

  // ---------- util ----------
  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  String _deriveImportLabel() {
    final base = _normBaseUrl(_baseUrlCtrl.text);
    final email = _emailCtrl.text.trim();
    String host = base;
    try {
      host = Uri.parse(base).host;
    } catch (_) {}
    if (email.isEmpty) return 'XBoard · $host';
    return 'XBoard · $host · $email';
  }

  Future<void> _runWithScaffoldLoading(Future<void> Function() job) async {
    final scaffold = globalState.homeScaffoldKey.currentState;
    if (scaffold?.mounted == true) {
      await scaffold!.loadingRun(job);
    } else {
      await job();
    }
  }

  // ---------- storage ----------
  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kProfiles = 'xboard_profiles_json';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  Future<void> _saveCurrent({
    required String baseUrl,
    required String authData,
    required String cookie,
    required String lastSubscribeUrl,
    required String profileId,
  }) async {
    final sp = await _sp();
    await sp.setString(_kCurrentBaseUrl, baseUrl);
    await sp.setString(_kCurrentAuthData, authData);
    await sp.setString(_kCurrentCookie, cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, lastSubscribeUrl);
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
    if (cur == p.id) await sp.setString(_kCurrentProfileId, '');
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _loadLocal() async {
    final sp = await _sp();
    final base = sp.getString(_kCurrentBaseUrl) ?? '';
    final a = sp.getString(_kCurrentAuthData) ?? '';
    final c = sp.getString(_kCurrentCookie) ?? '';
    final sub = sp.getString(_kCurrentLastSubscribeUrl) ?? '';
    final pid = sp.getString(_kCurrentProfileId) ?? '';

    final profiles = await _loadProfiles();
    final fallbackBase = profiles.isNotEmpty ? profiles.first.baseUrl : '';
    _baseUrlCtrl.text = (base.isNotEmpty ? base : fallbackBase);

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

  // ---------- network ----------
  bool _validateBaseUrl(String base) {
    return base.startsWith('http://') || base.startsWith('https://');
  }

  Future<void> _login() async {
    final base = _normBaseUrl(_baseUrlCtrl.text);
    final email = _emailCtrl.text.trim();
    final pwd = _pwdCtrl.text;

    if (!_validateBaseUrl(base)) {
      _toast('面板域名必须以 http:// 或 https:// 开头');
      return;
    }
    if (email.isEmpty || pwd.isEmpty) {
      _toast('请输入邮箱和密码');
      return;
    }

    setState(() => _loading = true);
    try {
      final url = '$base/api/v1/passport/auth/login';
      final resp = await _dio.post(url, data: jsonEncode({'email': email, 'password': pwd}));

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast('登录失败：HTTP ${resp.statusCode ?? 'unknown'}');
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

      final pid = _makeProfileId(base, email);

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
      );

      await _upsertProfile(
        _LoginProfile(
          id: pid,
          baseUrl: base,
          email: email,
          authData: a,
          cookie: cookie,
          lastSubscribeUrl: _lastSubscribeUrl ?? '',
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
    final base = _normBaseUrl(_baseUrlCtrl.text);
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
        _toast('获取订阅失败：HTTP ${resp.statusCode ?? 'unknown'}');
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
      );

      if (pid.isNotEmpty) {
        final profiles = await _loadProfiles();
        final idx = profiles.indexWhere((x) => x.id == pid);
        if (idx >= 0) {
          profiles[idx] = profiles[idx].copyWith(
            cookie: finalCookie,
            lastSubscribeUrl: sub,
            savedAtMs: DateTime.now().millisecondsSinceEpoch,
            authData: a,
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

  // ---------- FlClash import ----------
  Future<void> _importToFlClashDedupAndUpdate(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    final label = _deriveImportLabel();
    final profiles = ref.read(profilesProvider);
    final sameUrl = profiles.where((p) => (p.url).trim() == trimmed).toList();

    Profile target;

    if (sameUrl.isNotEmpty) {
      target = sameUrl.first;

      final oldLabel = (target.label ?? '').trim();
      if (oldLabel != label) {
        final fixed = target.copyWith(label: label);
        globalState.appController.setProfile(fixed);
        target = fixed;
      }

      await globalState.appController.updateProfile(target);

      for (final dup in sameUrl.skip(1)) {
        await globalState.appController.deleteProfile(dup.id);
      }
    } else {
      final created = Profile.normal(label: label, url: trimmed);
      await globalState.appController.addProfile(created);
      await globalState.appController.updateProfile(created);
      target = created;
    }

    if (ref.read(currentProfileIdProvider) == target.id) {
      await globalState.appController.applyProfile(silence: true);
    }

    globalState.showMessage(
      title: '完成',
      message: TextSpan(text: '订阅已导入并更新：${target.label ?? label}'),
    );
  }

  Future<void> _applyToFlClash() async {
    await _fetchSubscribe(showToast: false);
    final sub = _lastSubscribeUrl;
    if (sub == null || sub.isEmpty) {
      _toast('暂无订阅链接');
      return;
    }

    await _runWithScaffoldLoading(() async {
      await _importToFlClashDedupAndUpdate(sub);
    });
  }

  Future<void> _copySubscribe() async {
    final s = _lastSubscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    _toast('已复制订阅链接');
  }

  Future<void> _useProfile(_LoginProfile p) async {
    _baseUrlCtrl.text = p.baseUrl;
    _emailCtrl.text = p.email;
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
    );

    _toast('已切换账号，正在刷新订阅…');
    await _fetchSubscribe(showToast: false);
  }

  // ---------- dialogs ----------
  Future<void> _showLoginDialog() async {
    final canLogin = !_loading;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('XBoard 登录'),
          content: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _baseUrlCtrl,
                    enabled: canLogin,
                    decoration: const InputDecoration(
                      labelText: 'API / 面板域名',
                      hintText: 'https://example.com',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _emailCtrl,
                    enabled: canLogin,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: '邮箱'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pwdCtrl,
                    enabled: canLogin,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码（不会保存）'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: canLogin ? () => Navigator.of(ctx).pop() : null,
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: canLogin
                  ? () async {
                      Navigator.of(ctx).pop();
                      await _runWithScaffoldLoading(() async {
                        await _login();
                      });
                    }
                  : null,
              child: const Text('登录'),
            ),
          ],
        );
      },
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
                                Navigator.pop(context);
                              }
                              _toast('已清空历史记录');
                            },
                      child: const Text('清空'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('暂无历史记录（登录一次就会自动保存）'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = _profiles[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${p.email.isEmpty ? '(未记录邮箱)' : p.email}  ·  ${p.baseUrl}'),
                          subtitle: Text(
                            '保存：${_fmtTime(p.savedAtMs)}'
                            '${p.lastSubscribeUrl.isNotEmpty ? '\n订阅：${p.lastSubscribeUrl}' : ''}',
                          ),
                          isThreeLine: p.lastSubscribeUrl.isNotEmpty,
                          onTap: _loading
                              ? null
                              : () async {
                                  Navigator.pop(context);
                                  await _useProfile(p);
                                },
                          trailing: IconButton(
                            tooltip: '删除',
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'XBoard',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '历史登录',
              onPressed: _loading ? null : _showHistorySheet,
              icon: Badge(
                isLabelVisible: _profiles.isNotEmpty,
                label: Text('${_profiles.length}'),
                child: const Icon(Icons.history),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

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
                onPressed: (!loggedIn || _loading) ? null : _applyToFlClash,
                child: Text(_loading ? '处理中…' : '更新订阅并写入'),
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
                    ? '已登录（auth_data 已缓存）'
                    : '未登录（点击“登录”输入面板域名/邮箱/密码）',
                style: TextStyle(
                  color: loggedIn ? Colors.green : Theme.of(context).hintColor,
                ),
              ),
            ),
            IconButton(
              tooltip: '仅刷新订阅',
              onPressed: (!loggedIn || _loading)
                  ? null
                  : () => _runWithScaffoldLoading(() async {
                        await _fetchSubscribe(showToast: true);
                      }),
              icon: const Icon(Icons.refresh),
            ),
          ],
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
                  '最后刷新：${_fmtTime(_lastFetchedAtMs)}',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
              TextButton.icon(
                onPressed: _loading ? null : _copySubscribe,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _LoginProfile {
  final String id;
  final String baseUrl;
  final String email;
  final String authData;
  final String cookie;
  final String lastSubscribeUrl;
  final int savedAtMs;

  const _LoginProfile({
    required this.id,
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'email': email,
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
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;
    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
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
  }) {
    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      authData: authData ?? this.authData,
      cookie: cookie ?? this.cookie,
      lastSubscribeUrl: lastSubscribeUrl ?? this.lastSubscribeUrl,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }
}
