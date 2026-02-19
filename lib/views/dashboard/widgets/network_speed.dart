import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/controller.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkSpeed extends ConsumerStatefulWidget {
  const NetworkSpeed({super.key});

  @override
  ConsumerState<NetworkSpeed> createState() => _NetworkSpeedState();
}

class _NetworkSpeedState extends ConsumerState<NetworkSpeed> {
  bool _loading = false;
  int _loadingCount = 0;

  String _baseUrl = '';
  String? _authData;
  String? _cookie;
  String? _lastSubscribeUrl;

  String _currentProfileId = '';
  List<_LoginProfile> _profiles = [];

  _SubCache? _subCache;
  SharedPreferences? _spCache;

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

  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kProfiles = 'xboard_profiles_json';
  static const _kSubCachePrefix = 'xboard_sub_cache_json__';

  @override
  void initState() {
    super.initState();
    _initLocal();
  }

  Future<SharedPreferences> _sp() async {
    final cached = _spCache;
    if (cached != null) return cached;
    final sp = await SharedPreferences.getInstance();
    _spCache = sp;
    return sp;
  }

  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  bool _validateBaseUrl(String base) =>
      base.startsWith('http://') || base.startsWith('https://');

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _fmtTimeMs(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _fmtDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0B';
    const k = 1024.0;
    final b = bytes.toDouble();
    if (b < k) return '${bytes}B';
    final kb = b / k;
    if (kb < k) return '${kb.toStringAsFixed(2)}KB';
    final mb = kb / k;
    if (mb < k) return '${mb.toStringAsFixed(2)}MB';
    final gb = mb / k;
    if (gb < k) return '${gb.toStringAsFixed(2)}GB';
    final tb = gb / k;
    return '${tb.toStringAsFixed(2)}TB';
  }

  String _fmtExpiredAt(dynamic v) {
    if (v == null) return '-';
    final s0 = v.toString().trim();
    if (s0.isEmpty) return '-';

    if (RegExp(r'^\d+$').hasMatch(s0)) {
      if (s0.length == 10) {
        final sec = int.tryParse(s0) ?? 0;
        if (sec <= 0) return '-';
        return _fmtDate(DateTime.fromMillisecondsSinceEpoch(sec * 1000));
      }
      if (s0.length == 13) {
        final ms = int.tryParse(s0) ?? 0;
        if (ms <= 0) return '-';
        return _fmtDate(DateTime.fromMillisecondsSinceEpoch(ms));
      }
      final n = int.tryParse(s0);
      if (n == null || n <= 0) return '-';
      final ms = n > 1000000000000 ? n : n * 1000;
      return _fmtDate(DateTime.fromMillisecondsSinceEpoch(ms));
    }

    if (s0.length >= 10) {
      final head = s0.substring(0, 10);
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head)) return head;
    }

    final dt = DateTime.tryParse(s0.replaceFirst(' ', 'T'));
    if (dt != null) return _fmtDate(dt);

    return s0;
  }

  Future<void> _runLoading(Future<void> Function() job) async {
    _loadingCount++;
    if (_loadingCount == 1 && mounted) setState(() => _loading = true);
    try {
      await job();
    } finally {
      _loadingCount--;
      if (_loadingCount <= 0) {
        _loadingCount = 0;
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  String _extractAuthData(dynamic loginJson) {
    if (loginJson is Map) {
      final data = loginJson['data'];
      if (data is Map && data['auth_data'] != null) return '${data['auth_data']}';
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

  String _subCacheKey(String profileId) => '$_kSubCachePrefix$profileId';

  Future<void> _initLocal() async {
    final sp = await _sp();

    final base = sp.getString(_kCurrentBaseUrl) ?? '';
    final a = sp.getString(_kCurrentAuthData) ?? '';
    final c = sp.getString(_kCurrentCookie) ?? '';
    final sub = sp.getString(_kCurrentLastSubscribeUrl) ?? '';
    final pid = sp.getString(_kCurrentProfileId) ?? '';

    final profiles = await _loadProfiles(sp);
    final fallbackBase = profiles.isNotEmpty ? profiles.first.baseUrl : '';
    final fallbackPid = profiles.isNotEmpty ? profiles.first.id : '';
    final finalPid = pid.isNotEmpty ? pid : fallbackPid;

    if (!mounted) return;
    setState(() {
      _baseUrl = base.isNotEmpty ? base : fallbackBase;
      _authData = a.isEmpty ? null : a;
      _cookie = c.isEmpty ? null : c;
      _lastSubscribeUrl = sub.isEmpty ? null : sub;
      _profiles = profiles;
      _currentProfileId = finalPid;
    });

    await _loadSubCacheOnly(profileId: finalPid);
  }

  Future<void> _loadSubCacheOnly({required String profileId}) async {
    if (profileId.isEmpty) {
      if (!mounted) return;
      setState(() => _subCache = null);
      return;
    }
    final sp = await _sp();
    final s = sp.getString(_subCacheKey(profileId));
    if (s == null || s.isEmpty) {
      if (!mounted) return;
      setState(() => _subCache = null);
      return;
    }
    try {
      final j = jsonDecode(s);
      final cache = _SubCache.fromJson(j);
      if (!mounted) return;
      setState(() => _subCache = cache);
    } catch (_) {
      if (!mounted) return;
      setState(() => _subCache = null);
    }
  }

  Future<List<_LoginProfile>> _loadProfiles(SharedPreferences sp) async {
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

  Future<void> _saveProfiles(SharedPreferences sp, List<_LoginProfile> profiles) async {
    final list = profiles.map((e) => e.toJson()).toList();
    await sp.setString(_kProfiles, jsonEncode(list));
  }

  Future<void> _upsertProfile(SharedPreferences sp, _LoginProfile p) async {
    final profiles = await _loadProfiles(sp);
    final idx = profiles.indexWhere((x) => x.id == p.id);
    if (idx >= 0) {
      profiles[idx] = p;
    } else {
      profiles.add(p);
    }
    profiles.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
    await _saveProfiles(sp, profiles);
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _deleteHistoryProfile(SharedPreferences sp, _LoginProfile p) async {
    final profiles = await _loadProfiles(sp);
    profiles.removeWhere((x) => x.id == p.id);
    await _saveProfiles(sp, profiles);

    final cur = sp.getString(_kCurrentProfileId) ?? '';
    if (cur == p.id) {
      await sp.remove(_kCurrentProfileId);
      await sp.remove(_kCurrentBaseUrl);
      await sp.remove(_kCurrentAuthData);
      await sp.remove(_kCurrentCookie);
      await sp.remove(_kCurrentLastSubscribeUrl);

      if (mounted) {
        setState(() {
          _currentProfileId = '';
          _subCache = null;
          _authData = null;
          _cookie = null;
          _lastSubscribeUrl = null;
          _baseUrl = '';
        });
      }
    }

    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _saveCurrent(
    SharedPreferences sp, {
    required String baseUrl,
    required String authData,
    required String cookie,
    required String lastSubscribeUrl,
    required String profileId,
  }) async {
    await sp.setString(_kCurrentBaseUrl, baseUrl);
    await sp.setString(_kCurrentAuthData, authData);
    await sp.setString(_kCurrentCookie, cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, lastSubscribeUrl);
    await sp.setString(_kCurrentProfileId, profileId);
  }

  Future<_LoginFormData?> _showLoginDialog() async {
    final baseCtrl = TextEditingController(text: _baseUrl);
    final emailCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    final remarkCtrl = TextEditingController(text: _profiles.isNotEmpty ? _profiles.first.remark : '');
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
        title: const Text('登录'),
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
                      labelText: '备注（可选）',
                      hintText: '例如：主号 / 备用',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(onPressed: submit, child: const Text('登录')),
        ],
      ),
    );

    baseCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    remarkCtrl.dispose();
    return result;
  }

  Future<void> _loginWith(_LoginFormData f) async {
    final sp = await _sp();
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

    await _runLoading(() async {
      final url = '$base/api/v1/passport/auth/login';
      final resp = await _dio.post(url, data: {'email': email, 'password': pwd});

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        _toast('登录失败：HTTP ${resp.statusCode ?? 'unknown'}');
        return;
      }

      final a = _extractAuthData(resp.data);
      if (a.isEmpty) {
        _toast('登录成功但未找到 auth_data');
        return;
      }

      final raw = resp.headers.map['set-cookie'];
      final cookie = _extractSessionCookieFromSetCookie(raw ?? const []);
      final pid = _makeProfileId(base, email);

      if (!mounted) return;
      setState(() {
        _baseUrl = base;
        _authData = a;
        _cookie = cookie.isEmpty ? null : cookie;
        _currentProfileId = pid;
      });

      await _saveCurrent(
        sp,
        baseUrl: base,
        authData: a,
        cookie: cookie,
        lastSubscribeUrl: _lastSubscribeUrl ?? '',
        profileId: pid,
      );

      await _upsertProfile(
        sp,
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

      await _refreshSubscribeImportAndWriteCache(doImport: true, showToast: false);

      _toast('登录成功');
    });
  }

  Future<void> _refreshButtonTapped() async {
    await _refreshSubscribeImportAndWriteCache(doImport: true, showToast: true);
  }

  Future<void> _refreshSubscribeImportAndWriteCache({
    required bool doImport,
    required bool showToast,
  }) async {
    final sp = await _sp();
    final base = _normBaseUrl(_baseUrl);
    final a = _authData;
    final pid = _currentProfileId;

    if (a == null || a.isEmpty) {
      if (showToast) _toast('未登录：请先登录');
      return;
    }
    if (pid.isEmpty) {
      if (showToast) _toast('缺少账号标识：请重新登录一次');
      return;
    }
    if (!_validateBaseUrl(base)) {
      if (showToast) _toast('面板域名必须以 http:// 或 https:// 开头');
      return;
    }

    await _runLoading(() async {
      final headers = <String, dynamic>{
        'Accept': 'application/json',
        'Authorization': a,
      };
      final c = _cookie;
      if (c != null && c.isNotEmpty) headers['Cookie'] = c;

      final url = '$base/api/v1/user/getSubscribe';
      final resp = await _dio.get(url, options: Options(headers: headers));

      if (resp.statusCode == null || resp.statusCode! < 200 || resp.statusCode! >= 300) {
        if (showToast) _toast('更新失败：HTTP ${resp.statusCode ?? 'unknown'}');
        return;
      }

      final root = resp.data;
      final data = (root is Map) ? root['data'] : null;
      if (data is! Map) {
        if (showToast) _toast('更新失败：返回结构不一致');
        return;
      }

      final u = (data['u'] as num?)?.toInt() ?? 0;
      final d = (data['d'] as num?)?.toInt() ?? 0;
      final transferEnable = (data['transfer_enable'] as num?)?.toInt() ?? 0;
      final expiredAtPretty = _fmtExpiredAt(data['expired_at']);
      final subscribeUrl = (data['subscribe_url'] ?? '').toString().trim();

      final raw = resp.headers.map['set-cookie'];
      final newCookie = _extractSessionCookieFromSetCookie(raw ?? const []);
      final finalCookie = newCookie.isNotEmpty ? newCookie : (_cookie ?? '');
      if (finalCookie.isNotEmpty) {
        _cookie = finalCookie;
        await sp.setString(_kCurrentCookie, finalCookie);
      }

      final cache = _SubCache(
        u: u,
        d: d,
        transferEnable: transferEnable,
        expiredAtPretty: expiredAtPretty,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await sp.setString(_subCacheKey(pid), jsonEncode(cache.toJson()));

      if (subscribeUrl.isNotEmpty) {
        _lastSubscribeUrl = subscribeUrl;
        await sp.setString(_kCurrentLastSubscribeUrl, subscribeUrl);
      }

      if (!mounted) return;
      setState(() => _subCache = cache);

      if (doImport) {
        if (subscribeUrl.isEmpty) {
          if (showToast) _toast('更新成功，但没有订阅链接');
          return;
        }
        try {
          await appController.addProfileFormURL(subscribeUrl);
          if (showToast) _toast('已更新并导入/更新订阅');
        } catch (_) {
          if (showToast) _toast('数据已更新，但导入失败');
        }
      } else {
        if (showToast) _toast('已更新');
      }
    });
  }

  Future<void> _useHistory(_LoginProfile p) async {
    final sp = await _sp();

    if (!mounted) return;
    setState(() {
      _baseUrl = p.baseUrl;
      _authData = p.authData;
      _cookie = p.cookie.isEmpty ? null : p.cookie;
      _lastSubscribeUrl = p.lastSubscribeUrl.isEmpty ? null : p.lastSubscribeUrl;
      _currentProfileId = p.id;
    });

    await _saveCurrent(
      sp,
      baseUrl: p.baseUrl,
      authData: p.authData,
      cookie: p.cookie,
      lastSubscribeUrl: p.lastSubscribeUrl,
      profileId: p.id,
    );

    await _loadSubCacheOnly(profileId: p.id);

    await _refreshSubscribeImportAndWriteCache(doImport: true, showToast: false);

    _toast('已切换账号');
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
                      child: Text('历史登录信息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              Navigator.pop(context);
                              HapticFeedback.selectionClick();
                              final form = await _showLoginDialog();
                              if (form == null) return;
                              await _loginWith(form);
                            },
                      child: const Text('切换账号'),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              final sp = await _sp();
                              await sp.remove(_kProfiles);
                              await sp.remove(_kCurrentBaseUrl);
                              await sp.remove(_kCurrentAuthData);
                              await sp.remove(_kCurrentCookie);
                              await sp.remove(_kCurrentLastSubscribeUrl);
                              await sp.remove(_kCurrentProfileId);

                              if (mounted) {
                                setState(() {
                                  _profiles = [];
                                  _currentProfileId = '';
                                  _subCache = null;
                                  _authData = null;
                                  _cookie = null;
                                  _lastSubscribeUrl = null;
                                  _baseUrl = '';
                                });
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
                    child: Text('暂无历史记录'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = _profiles[i];
                        final title = [
                          if (p.remark.trim().isNotEmpty) p.remark.trim(),
                          if (p.email.isNotEmpty) p.email,
                          p.baseUrl,
                        ].join('  ·  ');
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(title),
                          subtitle: Text('保存：${_fmtTimeMs(p.savedAtMs)}'),
                          onTap: _loading
                              ? null
                              : () async {
                                  Navigator.pop(context);
                                  await _useHistory(p);
                                },
                          trailing: IconButton(
                            tooltip: '删除',
                            onPressed: _loading
                                ? null
                                : () async {
                                    final sp = await _sp();
                                    await _deleteHistoryProfile(sp, p);
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

  Widget _chip(String label, String value) {
    return SizedBox(
      height: 40,
      child: Chip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        labelPadding: const EdgeInsets.symmetric(horizontal: 10),
        label: Text('$label：$value', style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _loggedInBody(BuildContext context) {
    final cache = _subCache;

    if (cache == null) {
      return Expanded(
        child: Center(
          child: Text(
            _loading ? '正在加载…' : '暂无数据',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      );
    }

    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Expanded(child: _chip('上传', _fmtBytes(cache.u))),
              const SizedBox(width: 10),
              Expanded(child: _chip('下载', _fmtBytes(cache.d))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _chip('总量', _fmtBytes(cache.transferEnable))),
              const SizedBox(width: 10),
              Expanded(child: _chip('到期', cache.expiredAtPretty)),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = (_authData != null && _authData!.isNotEmpty);
    final cacheText = _subCache == null ? '无缓存' : '缓存：${_fmtTimeMs(_subCache!.fetchedAtMs)}';

    return SizedBox(
      height: getWidgetHeight(2),
      child: RepaintBoundary(
        child: CommonCard(
          onPressed: () {},
          child: Padding(
            padding: baseInfoEdgeInsets.copyWith(bottom: 12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: loggedIn
                          ? Text(
                              cacheText,
                              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Text(
                              '订阅状态',
                              style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    if (loggedIn) ...[
                      Tooltip(
                        message: '更新并导入/更新订阅',
                        child: IconButton(
                          onPressed: _loading ? null : _refreshButtonTapped,
                          icon: const Icon(Icons.sync),
                        ),
                      ),
                      Tooltip(
                        message: '历史登录信息',
                        child: IconButton(
                          onPressed: _loading ? null : _showHistorySheet,
                          icon: const Icon(Icons.history),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (!loggedIn)
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        width: 160,
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
                    ),
                  )
                else
                  _loggedInBody(context),
              ],
            ),
          ),
        ),
      ),
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
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;

    return _LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: (j['email'] ?? '').toString(),
      remark: (j['remark'] ?? '').toString(),
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }
}

class _SubCache {
  final int u;
  final int d;
  final int transferEnable;
  final String expiredAtPretty;
  final int fetchedAtMs;

  const _SubCache({
    required this.u,
    required this.d,
    required this.transferEnable,
    required this.expiredAtPretty,
    required this.fetchedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'u': u,
        'd': d,
        'transfer_enable': transferEnable,
        'expired_at_pretty': expiredAtPretty,
        'fetched_at_ms': fetchedAtMs,
      };

  static _SubCache? fromJson(dynamic j) {
    if (j is! Map) return null;
    return _SubCache(
      u: (j['u'] as num?)?.toInt() ?? 0,
      d: (j['d'] as num?)?.toInt() ?? 0,
      transferEnable: (j['transfer_enable'] as num?)?.toInt() ?? 0,
      expiredAtPretty: (j['expired_at_pretty'] ?? '').toString(),
      fetchedAtMs: (j['fetched_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}
