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

/// Dashboard 卡片：
/// - 卡片本体保持短小（不受高度影响）
/// - API/邮箱/密码放弹窗输入
/// - “更新订阅并导入”走 FlClash 原生 profile 逻辑（add/update/apply + 去重）
class LoginCard extends ConsumerStatefulWidget {
  const LoginCard({super.key});

  @override
  ConsumerState<LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends ConsumerState<LoginCard> {
  bool _loading = false;

  String _baseUrl = '';
  String? _authData; // e.g. "Bearer xxxxxx"
  String? _cookie; // server_name_session=...
  String? _lastSubscribeUrl;
  int _lastFetchedAtMs = 0;

  List<_LoginProfile> _profiles = [];

  // ====== SharedPreferences keys ======
  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kProfiles = 'xboard_profiles_json';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  // ================== Utils ==================
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

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

  String _makeProfileId(String baseUrl, String email) {
    final s = '${baseUrl.toLowerCase()}|${email.toLowerCase()}';
    return s.codeUnits.fold<int>(0, (a, b) => (a * 131 + b) & 0x7fffffff).toString();
  }

  String _extractAuthData(dynamic loginJson) {
    if (loginJson is Map) {
      final data = loginJson['data'];
      if (data is Map && data['auth_data'] != null) {
        return '${data['auth_data']}';
      }
    }
    return '';
  }

  String _extractSubscribeUrl(dynamic j) {
    if (j is Map) {
      final data = j['data'];
      if (data is Map && data['subscribe_url'] != null) {
        return '${data['subscribe_url']}';
      }
    }
    return '';
  }

  String _extractSessionCookieFromSetCookieList(List<String> setCookies) {
    // 只抓 server_name_session=...
    for (final sc in setCookies) {
      final m = RegExp(r'(server_name_session=[^;]+)').firstMatch(sc);
      if (m != null) return m.group(1) ?? '';
    }
    return '';
  }

  Dio _dio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 12),
        responseType: ResponseType.json,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        validateStatus: (code) => code != null && code >= 200 && code < 500,
      ),
    );
  }

  // ================== Local storage ==================
  Future<void> _loadLocal() async {
    final sp = await _sp();
    final base = sp.getString(_kCurrentBaseUrl) ?? '';
    final a = sp.getString(_kCurrentAuthData) ?? '';
    final c = sp.getString(_kCurrentCookie) ?? '';
    final sub = sp.getString(_kCurrentLastSubscribeUrl) ?? '';
    final pid = sp.getString(_kCurrentProfileId) ?? '';

    final profiles = await _loadProfiles();
    final fallbackBase = profiles.isNotEmpty ? profiles.first.baseUrl : '';

    if (mounted) {
      setState(() {
        _baseUrl = (base.isNotEmpty ? base : fallbackBase);
        _authData = a.isEmpty ? null : a;
        _cookie = c.isEmpty ? null : c;
        _lastSubscribeUrl = sub.isEmpty ? null : sub;
        _profiles = profiles;
      });
    }

    // 防止 currentProfileId 指向已删除历史
    if (pid.isNotEmpty && !profiles.any((e) => e.id == pid)) {
      await sp.setString(_kCurrentProfileId, '');
    }
  }

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
    await sp.setString(_kProfiles, jsonEncode(profiles.map((e) => e.toJson()).toList()));
  }

  Future<void> _upsertProfile(_LoginProfile p) async {
    final list = await _loadProfiles();
    final idx = list.indexWhere((x) => x.id == p.id);
    if (idx >= 0) {
      list[idx] = p;
    } else {
      list.add(p);
    }
    list.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
    await _saveProfiles(list);
    if (mounted) setState(() => _profiles = list);
  }

  Future<void> _deleteProfile(_LoginProfile p) async {
    final sp = await _sp();
    final list = await _loadProfiles();
    list.removeWhere((x) => x.id == p.id);
    await _saveProfiles(list);

    final cur = sp.getString(_kCurrentProfileId) ?? '';
    if (cur == p.id) {
      await sp.setString(_kCurrentProfileId, '');
    }
    if (mounted) setState(() => _profiles = list);
  }

  // ================== FlClash: Import subscription (dedup + update + apply) ==================
  Future<void> _importSubscriptionToFlClash({
    required String url,
    required String label,
  }) async {
    final profiles = ref.read(profilesProvider);
    final sameUrl = profiles.where((p) => (p.url).trim() == url.trim()).toList();

    Profile target;

    if (sameUrl.isNotEmpty) {
      target = sameUrl.first;

      // 需要时改名
      if ((target.label ?? '').trim() != label.trim()) {
        final fixed = target.copyWith(label: label);
        globalState.appController.setProfile(fixed);
        target = fixed;
      }

      // 更新订阅
      await globalState.appController.updateProfile(target);

      // 删除多余重复
      for (final dup in sameUrl.skip(1)) {
        await globalState.appController.deleteProfile(dup.id);
      }
    } else {
      // 不存在：创建 + 更新
      final created = Profile.normal(label: label, url: url.trim());
      await globalState.appController.addProfile(created);
      await globalState.appController.updateProfile(created);
      target = created;
    }

    // 若它是当前订阅，则更新后立即应用
    if (ref.read(currentProfileIdProvider) == target.id) {
      await globalState.appController.applyProfile(silence: true);
    }
  }

  // ================== UI: Login dialog ==================
  Future<void> _loginWithDialog() async {
    if (_loading) return;

    final baseCtrl = TextEditingController(text: _baseUrl);
    final emailCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    bool obscure = true;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setD) {
            return AlertDialog(
              title: const Text('XBoard 登录'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: baseCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'API / 面板域名',
                        hintText: 'https://example.com',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: '邮箱'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: pwdCtrl,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: '密码（不会保存）',
                        suffixIcon: IconButton(
                          tooltip: obscure ? '显示' : '隐藏',
                          onPressed: () => setD(() => obscure = !obscure),
                          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '提示：仅缓存 auth_data / cookie，不保存密码。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('登录'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;

    final base = _normBaseUrl(baseCtrl.text);
    final email = emailCtrl.text.trim();
    final pwd = pwdCtrl.text;

    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      _toast('面板域名必须以 http:// 或 https:// 开头');
      return;
    }
    if (email.isEmpty || pwd.isEmpty) {
      _toast('请输入邮箱和密码');
      return;
    }

    setState(() => _loading = true);
    try {
      final dio = _dio();
      final resp = await dio.post(
        '$base/api/v1/passport/auth/login',
        data: {'email': email, 'password': pwd},
        options: Options(
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
        ),
      );

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast('登录失败：HTTP ${resp.statusCode ?? '-'}');
        return;
      }

      final a = _extractAuthData(resp.data);
      if (a.isEmpty) {
        _toast('登录成功但未找到 data.auth_data（返回结构不一致）');
        return;
      }

      final setCookies = resp.headers.map['set-cookie'] ?? const <String>[];
      final c = _extractSessionCookieFromSetCookieList(setCookies);

      final pid = _makeProfileId(base, email);

      setState(() {
        _baseUrl = base;
        _authData = a;
        _cookie = c.isEmpty ? null : c;
      });

      await _saveCurrent(
        baseUrl: base,
        authData: a,
        cookie: c,
        lastSubscribeUrl: _lastSubscribeUrl ?? '',
        profileId: pid,
      );

      await _upsertProfile(
        _LoginProfile(
          id: pid,
          baseUrl: base,
          email: email,
          authData: a,
          cookie: c,
          lastSubscribeUrl: _lastSubscribeUrl ?? '',
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      _toast('登录成功');
    } catch (e) {
      _toast('错误：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ================== Fetch subscribe ==================
  Future<String?> _fetchSubscribe({required bool showToast}) async {
    final base = _baseUrl;
    final a = _authData;

    if (a == null || a.isEmpty) {
      _toast('未登录：请先登录');
      return null;
    }
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      _toast('面板域名必须以 http:// 或 https:// 开头');
      return null;
    }

    setState(() => _loading = true);
    try {
      final dio = _dio();

      final headers = <String, dynamic>{
        'Accept': 'application/json',
        'Authorization': a,
      };
      final c = _cookie;
      if (c != null && c.isNotEmpty) headers['Cookie'] = c;

      final resp = await dio.get(
        '$base/api/v1/user/getSubscribe',
        options: Options(headers: headers),
      );

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast('获取订阅失败：HTTP ${resp.statusCode ?? '-'}');
        return null;
      }

      final sub = _extractSubscribeUrl(resp.data);
      if (sub.isEmpty) {
        _toast('获取成功，但没有 data.subscribe_url');
        return null;
      }

      final setCookies = resp.headers.map['set-cookie'] ?? const <String>[];
      final newCookie = _extractSessionCookieFromSetCookieList(setCookies);
      final finalCookie = newCookie.isNotEmpty ? newCookie : (_cookie ?? '');

      final now = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _lastSubscribeUrl = sub;
        _cookie = finalCookie.isEmpty ? null : finalCookie;
        _lastFetchedAtMs = now;
      });

      // 写 current
      final sp = await _sp();
      final pid = sp.getString(_kCurrentProfileId) ?? '';
      await _saveCurrent(
        baseUrl: base,
        authData: a,
        cookie: finalCookie,
        lastSubscribeUrl: sub,
        profileId: pid,
      );

      // 同步历史
      if (pid.isNotEmpty) {
        final list = await _loadProfiles();
        final idx = list.indexWhere((x) => x.id == pid);
        if (idx >= 0) {
          list[idx] = list[idx].copyWith(
            cookie: finalCookie,
            lastSubscribeUrl: sub,
            savedAtMs: now,
            authData: a,
          );
          await _saveProfiles(list);
          setState(() => _profiles = list);
        }
      }

      if (showToast) _toast('已获取最新订阅链接');
      return sub;
    } catch (e) {
      _toast('错误：$e');
      return null;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ================== Update + Import ==================
  Future<void> _updateAndImport() async {
    if (_loading) return;

    final scaffold = globalState.homeScaffoldKey.currentState;

    final run = (Future<void> Function() job) async {
      if (scaffold?.mounted == true) {
        await scaffold!.loadingRun(job);
      } else {
        await job();
      }
    };

    await run(() async {
      // 先拉订阅
      final sub = await _fetchSubscribe(showToast: false);
      if (sub == null || sub.isEmpty) return;

      // label：尽量用当前登录邮箱命名
      String label = 'XBoard 订阅';
      final sp = await _sp();
      final pid = sp.getString(_kCurrentProfileId) ?? '';
      final p = pid.isEmpty ? null : _profiles.cast<_LoginProfile?>().firstWhere(
            (x) => x?.id == pid,
            orElse: () => null,
          );
      if (p != null && p.email.trim().isNotEmpty) {
        label = 'XBoard - ${p.email.trim()}';
      }

      await _importSubscriptionToFlClash(url: sub, label: label);

      globalState.showMessage(
        title: '完成',
        message: TextSpan(text: '订阅已导入并更新：$label'),
      );
    });
  }

  Future<void> _copySubscribe() async {
    final s = _lastSubscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    _toast('已复制订阅链接');
  }

  Future<void> _useProfile(_LoginProfile p) async {
    if (_loading) return;

    setState(() {
      _baseUrl = p.baseUrl;
      _authData = p.authData;
      _cookie = p.cookie.isEmpty ? null : p.cookie;
      _lastSubscribeUrl = p.lastSubscribeUrl.isEmpty ? null : p.lastSubscribeUrl;
      _lastFetchedAtMs = p.savedAtMs;
    });

    await _saveCurrent(
      baseUrl: p.baseUrl,
      authData: p.authData,
      cookie: p.cookie,
      lastSubscribeUrl: p.lastSubscribeUrl,
      profileId: p.id,
    );

    _toast('已切换账号（可直接点“更新订阅并导入”）');
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
                              if (mounted) setState(() => _profiles = []);
                              if (mounted) Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
    final loggedIn = (_authData != null && _authData!.isNotEmpty);
    final hasSub = (_lastSubscribeUrl != null && _lastSubscribeUrl!.isNotEmpty);

    return SizedBox(
      height: getWidgetHeight(1),
      child: CommonCard(
        info: const Info(label: 'XBoard', iconData: Icons.login),
        onPressed: () {},
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题 + 历史
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'XBoard 登录',
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
              const SizedBox(height: 8),

              // 当前 baseUrl 展示
              Text(
                'API / 面板域名',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 4),
              Text(
                _baseUrl.isEmpty ? '-' : _baseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),

              // 登录 / 更新订阅并导入
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _loading ? null : _loginWithDialog,
                      child: Text(_loading ? '处理中…' : (loggedIn ? '重新登录' : '登录')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: (!loggedIn || _loading) ? null : _updateAndImport,
                      child: Text(_loading ? '处理中…' : '更新订阅并导入'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // 状态 + 仅刷新
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
                  IconButton(
                    tooltip: '仅刷新订阅',
                    onPressed: (!loggedIn || _loading)
                        ? null
                        : () => _fetchSubscribe(showToast: true),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),

              if (hasSub) ...[
                const SizedBox(height: 6),
                SelectableText(
                  _lastSubscribeUrl!,
                  style: const TextStyle(fontSize: 12),
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
          ),
        ),
      ),
    );
  }
}

/// ==================== 历史登录数据模型（本卡片内部用） ====================
class _LoginProfile {
  final String id; // baseUrl|email hash
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
