// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dashboard 外层卡片（用于 enum.dart 的 DashboardWidget）
class XBoardLoginDashboardCard extends StatelessWidget {
  const XBoardLoginDashboardCard({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(2),
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

/// XBoard 登录卡片本体
class XBoardLoginCard extends StatefulWidget {
  const XBoardLoginCard({super.key});

  @override
  State<XBoardLoginCard> createState() => _XBoardLoginCardState();
}

class _XBoardLoginCardState extends State<XBoardLoginCard> {
  final _baseUrlCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  bool _loading = false;

  String? _authData;
  String? _cookie;
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
    super.dispose();
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
    _emailCtrl.text = profiles.isNotEmpty ? profiles.first.email : '';

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

  // ---------- dialogs ----------
  Future<_LoginFormData?> _showLoginDialog() async {
    final baseCtrl = TextEditingController(text: _baseUrlCtrl.text.trim());
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final pwdCtrl = TextEditingController();
    final remarkCtrl = TextEditingController(
      text: _profiles.isNotEmpty ? _profiles.first.remark : '',
    );

    final formKey = GlobalKey<FormState>();

    Future<void> submit() async {
      if (!(formKey.currentState?.validate() ?? false)) return;
      Navigator.of(context).pop<_LoginFormData>(
        _LoginFormData(
          baseUrl: baseCtrl.text.trim(),
          email: emailCtrl.text.trim(),
          password: pwdCtrl.text,
          remark: remarkCtrl.text.trim(),
        ),
      );
    }

    final result = await showDialog<_LoginFormData>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('XBoard 登录'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: baseCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'API / 面板域名',
                      hintText: 'https://example.com',
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return '请输入域名';
                      if (!_validateBaseUrl(s)) return '必须以 http:// 或 https:// 开头';
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: '邮箱'),
                    validator: (v) => (v ?? '').trim().isEmpty ? '请输入邮箱' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: pwdCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码（不会保存）'),
                    validator: (v) => (v ?? '').isEmpty ? '请输入密码' : null,
                    onFieldSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: remarkCtrl,
                    decoration: const InputDecoration(
                      labelText: '备注（用于订阅命名）',
                      hintText: '例如：主号 / 公司 / 备用',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: submit,
            child: const Text('登录'),
          ),
        ],
      ),
    );

    baseCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    remarkCtrl.dispose();
    return result;
  }

  // ---------- network ----------
  Future<void> _loginWith(_LoginFormData f) async {
    final base = _normBaseUrl(f.baseUrl);
    final email = f.email.trim();
    final pwd = f.password;

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
      final resp = await _dio.post(
        url,
        data: jsonEncode({'email': email, 'password': pwd}),
      );

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

      _baseUrlCtrl.text = base;
      _emailCtrl.text = email;

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
          remark: f.remark,
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

  // ✅ 导入订阅：复用 FlClash 官方入口
  Future<void> _updateAndImport() async {
    await _fetchSubscribe(showToast: false);
    final sub = _lastSubscribeUrl;
    if (sub == null || sub.isEmpty) {
      _toast('暂无订阅链接：请先登录或检查面板');
      return;
    }

    try {
      setState(() => _loading = true);
      await appController.addProfileFormURL(sub.trim());
      _toast('已导入订阅（如需强制刷新请到 Profiles 里手动更新）');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------- history ----------
  Future<void> _useProfile(_LoginProfile p) async {
    _baseUrlCtrl.text = p.baseUrl;
    _emailCtrl.text = p.email;

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

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
                        final remark = p.remark.trim();
                        final title = [
                          if (remark.isNotEmpty) remark,
                          if (p.email.isNotEmpty) p.email else '(未记录邮箱)',
                          p.baseUrl,
                        ].join('  ·  ');
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(title),
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

  Future<void> _copySubscribe() async {
    final s = _lastSubscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    _toast('已复制订阅链接');
  }

  Widget _historyIconWithCount() {
    final count = _profiles.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.history),
        if (count > 0)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
            ),
          ),
      ],
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
              icon: _historyIconWithCount(),
            ),
          ],
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _loading
                    ? null
                    : () async {
                        HapticFeedback.selectionClick();
                        final form = await _showLoginDialog();
                        if (form == null) return;
                        await _loginWith(form);
                      },
                child: Text(_loading ? '处理中…' : '登录'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.tonal(
                onPressed: (!loggedIn || _loading)
                    ? null
                    : () async {
                        HapticFeedback.selectionClick();
                        await _updateAndImport();
                      },
                child: Text(_loading ? '处理中…' : '更新订阅并导入'),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Icon(loggedIn ? Icons.verified : Icons.info_outline, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                loggedIn ? '已登录（auth_data 已缓存）' : '未登录（点“登录”填写信息）',
                style: TextStyle(
                  color: loggedIn ? Colors.green : Theme.of(context).hintColor,
                ),
              ),
            ),
            IconButton(
              tooltip: '仅刷新订阅（不导入）',
              onPressed: (!loggedIn || _loading) ? null : () => _fetchSubscribe(showToast: true),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),

        if (hasSub) ...[
          const SizedBox(height: 8),
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

class _LoginFormData {
  final String baseUrl;
  final String email;
  final String password;
  final String remark;

  const _LoginFormData({
    required this.baseUrl,
    required this.email,
    required this.password,
    required this.remark,
  });
}

class _LoginProfile {
  final String id;
  final String baseUrl;
  final String email;
  final String remark;
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
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;

    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      remark: (j['remark'] ?? '').toString(),
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }

  _LoginProfile copyWith({
    String? remark,
    String? cookie,
    String? lastSubscribeUrl,
    int? savedAtMs,
    String? authData,
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
