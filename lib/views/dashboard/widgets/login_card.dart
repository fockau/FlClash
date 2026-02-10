import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// =======================
/// 外层 Dashboard Widget（大卡）
/// - 默认高度：getWidgetHeight(2)（最大卡片）
/// =======================
class LoginCard extends StatefulWidget {
  const LoginCard({
    super.key,
    required this.onApplySubscription,
    this.title = 'XBoard',
  });

  /// ✅ 把订阅链接写入 FlClash 并触发“导入/更新订阅”
  final Future<void> Function(String subscribeUrl) onApplySubscription;

  final String title;

  @override
  State<LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends State<LoginCard> {
  late final http.Client _client;
  late final XBoardController _c;

  @override
  void initState() {
    super.initState();
    _client = http.Client();
    _c = XBoardController(
      api: XBoardApi(client: _client),
      store: XBoardStore(),
      onApplySubscription: widget.onApplySubscription,
    )..init();
  }

  @override
  void dispose() {
    _c.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: getWidgetHeight(2), // ✅ 最大卡片：三个输入框+按钮+历史
      child: CommonCard(
        info: Info(label: widget.title, iconData: Icons.login),
        onPressed: () {},
        child: Padding(
          padding: baseInfoEdgeInsets.copyWith(top: 0),
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => _LoginCardBody(c: _c),
          ),
        ),
      ),
    );
  }
}

/// =======================
/// UI（只负责展示，不负责业务）
/// =======================
class _LoginCardBody extends StatelessWidget {
  const _LoginCardBody({required this.c});
  final XBoardController c;

  @override
  Widget build(BuildContext context) {
    final st = c.state;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部：标题 + 状态 + 历史按钮
        Row(
          children: [
            const Expanded(
              child: Text(
                '面板登录与订阅更新',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              st.statusLabel,
              style: TextStyle(
                fontSize: 12,
                color: st.isLoggedIn ? Colors.green : theme.hintColor,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '历史登录',
              onPressed: st.busy ? null : () => _showHistory(context),
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.history),
                  if (st.profiles.isNotEmpty)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: _CountDot(text: '${st.profiles.length}'),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ✅ 三个输入框（最大卡重点）
        TextField(
          controller: c.baseUrlCtrl,
          enabled: !st.busy,
          decoration: const InputDecoration(
            labelText: 'API / 面板域名',
            hintText: 'https://example.com',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: c.emailCtrl,
          enabled: !st.busy,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: '邮箱'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: c.passwordCtrl,
          enabled: !st.busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '密码',
            helperText: '密码不会被保存',
          ),
        ),
        const SizedBox(height: 14),

        // ✅ 两个主按钮：登录 / 更新订阅（拉取并写入 FlClash）
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: st.busy ? null : () => c.login(context),
                child: _BtnChild(loading: st.phase == XBoardPhase.loggingIn, text: '登录'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: (!st.isLoggedIn || st.busy) ? null : () => c.updateAndApply(context),
                child: _BtnChild(
                  loading: st.phase == XBoardPhase.fetchingSub || st.phase == XBoardPhase.applying,
                  text: '更新订阅',
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // 错误提示 + “仅获取订阅”
        Row(
          children: [
            Expanded(
              child: Text(
                st.lastError ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ),
            TextButton.icon(
              onPressed: (!st.isLoggedIn || st.busy) ? null : () => c.fetchSubscribeOnly(context),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('仅获取'),
            ),
          ],
        ),

        const SizedBox(height: 10),

        // 订阅展示区
        if (st.subscribeUrl.isNotEmpty)
          _SubscribeBox(
            url: st.subscribeUrl,
            lastFetchedAtMs: st.lastFetchedAtMs,
            busy: st.busy,
            onCopy: () => c.copySubscribe(context),
          )
        else
          _HintBox(
            text: st.isLoggedIn
                ? '已登录，点击「更新订阅」即可获取并写入 FlClash'
                : '请先输入面板域名/邮箱/密码并登录',
          ),
      ],
    );
  }

  void _showHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) {
        final st = c.state;
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
                      onPressed: st.busy
                          ? null
                          : () async {
                              Navigator.pop(context);
                              await c.clearHistory(context);
                            },
                      child: const Text('清理'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (st.profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('暂无历史记录（登录成功会自动保存）'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: st.profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = st.profiles[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${p.email} · ${p.baseUrl}'),
                          subtitle: Text(
                            '保存：${XBoardFmt.time(p.savedAtMs)}'
                            '${p.lastSubscribeUrl.isNotEmpty ? '\n订阅：${p.lastSubscribeUrl}' : ''}',
                          ),
                          isThreeLine: p.lastSubscribeUrl.isNotEmpty,
                          onTap: st.busy
                              ? null
                              : () async {
                                  Navigator.pop(context);
                                  await c.useProfile(context, p);
                                },
                          trailing: IconButton(
                            tooltip: '删除',
                            onPressed: st.busy ? null : () => c.deleteProfile(context, p.id),
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
}

class _CountDot extends StatelessWidget {
  const _CountDot({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.redAccent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10, color: Colors.white, height: 1.0),
      ),
    );
  }
}

class _BtnChild extends StatelessWidget {
  const _BtnChild({required this.loading, required this.text});
  final bool loading;
  final String text;

  @override
  Widget build(BuildContext context) {
    if (!loading) return Text(text);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 8),
        Text('处理中…'),
      ],
    );
  }
}

class _HintBox extends StatelessWidget {
  const _HintBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).cardColor.withOpacity(0.6);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
    );
  }
}

class _SubscribeBox extends StatelessWidget {
  const _SubscribeBox({
    required this.url,
    required this.lastFetchedAtMs,
    required this.busy,
    required this.onCopy,
  });

  final String url;
  final int lastFetchedAtMs;
  final bool busy;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).cardColor.withOpacity(0.6);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('订阅地址', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText(url, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '最后刷新：${XBoardFmt.time(lastFetchedAtMs)}',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : onCopy,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// =======================
/// Controller（业务逻辑）
/// =======================
enum XBoardPhase { idle, loggingIn, fetchingSub, applying }

class XBoardState {
  XBoardState({
    required this.phase,
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.subscribeUrl,
    required this.lastFetchedAtMs,
    required this.lastError,
    required this.profiles,
    required this.currentProfileId,
  });

  final XBoardPhase phase;
  final String baseUrl;
  final String email;
  final String authData;
  final String cookie;
  final String subscribeUrl;
  final int lastFetchedAtMs;
  final String? lastError;
  final List<XBoardProfile> profiles;
  final String currentProfileId;

  bool get busy => phase != XBoardPhase.idle;
  bool get isLoggedIn => authData.isNotEmpty;

  String get statusLabel {
    switch (phase) {
      case XBoardPhase.loggingIn:
        return '登录中';
      case XBoardPhase.fetchingSub:
        return '获取订阅中';
      case XBoardPhase.applying:
        return '写入中';
      case XBoardPhase.idle:
        return isLoggedIn ? '已登录' : '未登录';
    }
  }

  static XBoardState initial() => XBoardState(
        phase: XBoardPhase.idle,
        baseUrl: '',
        email: '',
        authData: '',
        cookie: '',
        subscribeUrl: '',
        lastFetchedAtMs: 0,
        lastError: null,
        profiles: const [],
        currentProfileId: '',
      );

  XBoardState copyWith({
    XBoardPhase? phase,
    String? baseUrl,
    String? email,
    String? authData,
    String? cookie,
    String? subscribeUrl,
    int? lastFetchedAtMs,
    String? lastError,
    List<XBoardProfile>? profiles,
    String? currentProfileId,
  }) {
    return XBoardState(
      phase: phase ?? this.phase,
      baseUrl: baseUrl ?? this.baseUrl,
      email: email ?? this.email,
      authData: authData ?? this.authData,
      cookie: cookie ?? this.cookie,
      subscribeUrl: subscribeUrl ?? this.subscribeUrl,
      lastFetchedAtMs: lastFetchedAtMs ?? this.lastFetchedAtMs,
      lastError: lastError,
      profiles: profiles ?? this.profiles,
      currentProfileId: currentProfileId ?? this.currentProfileId,
    );
  }
}

class XBoardController extends ChangeNotifier {
  XBoardController({
    required this.api,
    required this.store,
    required this.onApplySubscription,
  });

  final XBoardApi api;
  final XBoardStore store;
  final Future<void> Function(String subscribeUrl) onApplySubscription;

  final baseUrlCtrl = TextEditingController();
  final emailCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();

  XBoardState _state = XBoardState.initial();
  XBoardState get state => _state;

  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    final cur = await store.loadCurrent();
    final profiles = await store.loadProfiles();

    final base = cur.baseUrl.isNotEmpty ? cur.baseUrl : (profiles.isNotEmpty ? profiles.first.baseUrl : '');
    final email = cur.email.isNotEmpty ? cur.email : (profiles.isNotEmpty ? profiles.first.email : '');

    baseUrlCtrl.text = base;
    emailCtrl.text = email;

    _state = _state.copyWith(
      baseUrl: base,
      email: email,
      authData: cur.authData,
      cookie: cur.cookie,
      subscribeUrl: cur.lastSubscribeUrl,
      lastFetchedAtMs: cur.lastFetchedAtMs,
      profiles: profiles,
      currentProfileId: cur.profileId,
      lastError: null,
    );
    notifyListeners();
  }

  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  bool _validate(BuildContext context, {required bool needPassword}) {
    final base = _normBaseUrl(baseUrlCtrl.text);
    final email = emailCtrl.text.trim();
    final pwd = passwordCtrl.text;

    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      _toast(context, 'API/面板域名必须以 http:// 或 https:// 开头');
      return false;
    }
    if (email.isEmpty) {
      _toast(context, '请输入邮箱');
      return false;
    }
    if (needPassword && pwd.isEmpty) {
      _toast(context, '请输入密码');
      return false;
    }
    return true;
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _setPhase(XBoardPhase p) {
    _state = _state.copyWith(phase: p, lastError: null);
    notifyListeners();
  }

  void _setError(String msg) {
    _state = _state.copyWith(phase: XBoardPhase.idle, lastError: msg);
    notifyListeners();
  }

  String _makeProfileId(String baseUrl, String email) {
    final s = '${baseUrl.toLowerCase()}|${email.toLowerCase()}';
    return s.codeUnits.fold<int>(0, (a, b) => (a * 131 + b) & 0x7fffffff).toString();
  }

  Future<void> login(BuildContext context) async {
    if (state.busy) return;
    if (!_validate(context, needPassword: true)) return;

    final base = _normBaseUrl(baseUrlCtrl.text);
    final email = emailCtrl.text.trim();
    final pwd = passwordCtrl.text;

    _setPhase(XBoardPhase.loggingIn);

    try {
      final resp = await api.login(baseUrl: base, email: email, password: pwd);
      if (resp.authData.isEmpty) {
        _setError('登录成功但未找到 data.auth_data（返回结构不一致）');
        return;
      }

      final pid = _makeProfileId(base, email);

      _state = _state.copyWith(
        phase: XBoardPhase.idle,
        baseUrl: base,
        email: email,
        authData: resp.authData,
        cookie: resp.cookie,
        currentProfileId: pid,
        lastError: null,
      );
      notifyListeners();

      await store.saveCurrent(
        XBoardCurrent(
          baseUrl: base,
          email: email,
          authData: resp.authData,
          cookie: resp.cookie,
          lastSubscribeUrl: state.subscribeUrl,
          lastFetchedAtMs: state.lastFetchedAtMs,
          profileId: pid,
        ),
      );

      final profile = XBoardProfile(
        id: pid,
        baseUrl: base,
        email: email,
        authData: resp.authData,
        cookie: resp.cookie,
        lastSubscribeUrl: state.subscribeUrl,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      final profiles = await store.upsertProfile(profile);

      _state = _state.copyWith(profiles: profiles, lastError: null);
      notifyListeners();

      _toast(context, '登录成功');
    } catch (e) {
      _setError('登录失败：$e');
    }
  }

  Future<void> fetchSubscribeOnly(BuildContext context) async {
    if (state.busy) return;
    if (!state.isLoggedIn) {
      _toast(context, '未登录：请先登录');
      return;
    }

    final base = _normBaseUrl(baseUrlCtrl.text);
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      _toast(context, 'API/面板域名必须以 http:// 或 https:// 开头');
      return;
    }

    _setPhase(XBoardPhase.fetchingSub);

    try {
      final resp = await api.getSubscribe(baseUrl: base, authData: state.authData, cookie: state.cookie);
      if (resp.subscribeUrl.isEmpty) {
        _setError('获取成功，但没有 data.subscribe_url');
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final finalCookie = resp.cookie.isNotEmpty ? resp.cookie : state.cookie;

      _state = _state.copyWith(
        phase: XBoardPhase.idle,
        subscribeUrl: resp.subscribeUrl,
        cookie: finalCookie,
        lastFetchedAtMs: now,
        lastError: null,
      );
      notifyListeners();

      await store.saveCurrent(
        XBoardCurrent(
          baseUrl: base,
          email: emailCtrl.text.trim(),
          authData: state.authData,
          cookie: finalCookie,
          lastSubscribeUrl: resp.subscribeUrl,
          lastFetchedAtMs: now,
          profileId: state.currentProfileId,
        ),
      );

      if (state.currentProfileId.isNotEmpty) {
        final profiles = await store.updateProfileSubscribe(
          id: state.currentProfileId,
          authData: state.authData,
          cookie: finalCookie,
          subscribeUrl: resp.subscribeUrl,
        );
        _state = _state.copyWith(profiles: profiles, lastError: null);
        notifyListeners();
      }

      _toast(context, '已获取最新订阅（未写入 FlClash）');
    } catch (e) {
      _setError('获取订阅失败：$e');
    }
  }

  Future<void> updateAndApply(BuildContext context) async {
    if (state.busy) return;
    if (!state.isLoggedIn) {
      _toast(context, '未登录：请先登录');
      return;
    }

    await fetchSubscribeOnly(context);
    if (state.subscribeUrl.isEmpty) return;

    _setPhase(XBoardPhase.applying);
    try {
      await onApplySubscription(state.subscribeUrl);
      _state = _state.copyWith(phase: XBoardPhase.idle, lastError: null);
      notifyListeners();
      _toast(context, '订阅已写入并触发更新');
    } catch (e) {
      _setError('写入 FlClash 失败：$e');
    }
  }

  Future<void> useProfile(BuildContext context, XBoardProfile p) async {
    if (state.busy) return;

    baseUrlCtrl.text = p.baseUrl;
    emailCtrl.text = p.email;
    passwordCtrl.text = '';

    _state = _state.copyWith(
      phase: XBoardPhase.idle,
      baseUrl: p.baseUrl,
      email: p.email,
      authData: p.authData,
      cookie: p.cookie,
      subscribeUrl: p.lastSubscribeUrl,
      currentProfileId: p.id,
      lastError: null,
    );
    notifyListeners();

    await store.saveCurrent(
      XBoardCurrent(
        baseUrl: p.baseUrl,
        email: p.email,
        authData: p.authData,
        cookie: p.cookie,
        lastSubscribeUrl: p.lastSubscribeUrl,
        lastFetchedAtMs: state.lastFetchedAtMs,
        profileId: p.id,
      ),
    );

    _toast(context, '已切换账号');
  }

  Future<void> deleteProfile(BuildContext context, String id) async {
    final profiles = await store.deleteProfile(id);
    _state = _state.copyWith(profiles: profiles, lastError: null);
    notifyListeners();
    _toast(context, '已删除');
  }

  Future<void> clearHistory(BuildContext context) async {
    await store.clearHistory();
    _state = _state.copyWith(profiles: const [], lastError: null);
    notifyListeners();
    _toast(context, '已清空历史记录');
  }

  Future<void> copySubscribe(BuildContext context) async {
    if (state.subscribeUrl.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: state.subscribeUrl));
    _toast(context, '已复制订阅链接');
  }

  @override
  void dispose() {
    baseUrlCtrl.dispose();
    emailCtrl.dispose();
    passwordCtrl.dispose();
    super.dispose();
  }
}

/// =======================
/// API（网络层）
/// =======================
class XBoardApi {
  XBoardApi({required this.client});
  final http.Client client;

  Future<_LoginResp> login({
    required String baseUrl,
    required String email,
    required String password,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/passport/auth/login');
    final resp = await client
        .post(
          uri,
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw 'HTTP ${resp.statusCode}';
    }

    final j = _safeJson(resp.body);
    final authData = _pickString(j, ['data', 'auth_data']);
    final cookie = _extractSessionCookie(resp.headers['set-cookie']);

    return _LoginResp(authData: authData, cookie: cookie);
  }

  Future<_SubscribeResp> getSubscribe({
    required String baseUrl,
    required String authData,
    required String cookie,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/user/getSubscribe');

    final headers = <String, String>{
      'Accept': 'application/json',
      'Authorization': authData,
    };
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final resp = await client.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw 'HTTP ${resp.statusCode}';
    }

    final j = _safeJson(resp.body);
    final subscribeUrl = _pickString(j, ['data', 'subscribe_url']);
    final newCookie = _extractSessionCookie(resp.headers['set-cookie']);

    return _SubscribeResp(subscribeUrl: subscribeUrl, cookie: newCookie);
  }

  static dynamic _safeJson(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static String _pickString(dynamic root, List<String> path) {
    dynamic cur = root;
    for (final k in path) {
      if (cur is Map && cur.containsKey(k)) {
        cur = cur[k];
      } else {
        return '';
      }
    }
    return (cur ?? '').toString();
  }

  static String _extractSessionCookie(String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return '';
    final m = RegExp(r'(server_name_session=[^;]+)').firstMatch(setCookie);
    return m?.group(1) ?? '';
  }
}

class _LoginResp {
  _LoginResp({required this.authData, required this.cookie});
  final String authData;
  final String cookie;
}

class _SubscribeResp {
  _SubscribeResp({required this.subscribeUrl, required this.cookie});
  final String subscribeUrl;
  final String cookie;
}

/// =======================
/// 存储层（SharedPreferences）
/// =======================
class XBoardStore {
  static const _kCurrentBaseUrl = 'xboard_current_baseUrl';
  static const _kCurrentEmail = 'xboard_current_email';
  static const _kCurrentAuthData = 'xboard_current_authData';
  static const _kCurrentCookie = 'xboard_current_cookie';
  static const _kCurrentLastSubscribeUrl = 'xboard_current_lastSubscribeUrl';
  static const _kCurrentLastFetchedAtMs = 'xboard_current_lastFetchedAtMs';
  static const _kCurrentProfileId = 'xboard_current_profile_id';
  static const _kProfiles = 'xboard_profiles_json';

  Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  Future<XBoardCurrent> loadCurrent() async {
    final sp = await _sp();
    return XBoardCurrent(
      baseUrl: sp.getString(_kCurrentBaseUrl) ?? '',
      email: sp.getString(_kCurrentEmail) ?? '',
      authData: sp.getString(_kCurrentAuthData) ?? '',
      cookie: sp.getString(_kCurrentCookie) ?? '',
      lastSubscribeUrl: sp.getString(_kCurrentLastSubscribeUrl) ?? '',
      lastFetchedAtMs: sp.getInt(_kCurrentLastFetchedAtMs) ?? 0,
      profileId: sp.getString(_kCurrentProfileId) ?? '',
    );
  }

  Future<void> saveCurrent(XBoardCurrent c) async {
    final sp = await _sp();
    await sp.setString(_kCurrentBaseUrl, c.baseUrl);
    await sp.setString(_kCurrentEmail, c.email);
    await sp.setString(_kCurrentAuthData, c.authData);
    await sp.setString(_kCurrentCookie, c.cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, c.lastSubscribeUrl);
    await sp.setInt(_kCurrentLastFetchedAtMs, c.lastFetchedAtMs);
    await sp.setString(_kCurrentProfileId, c.profileId);
  }

  Future<List<XBoardProfile>> loadProfiles() async {
    final sp = await _sp();
    final raw = sp.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return [];
      final out = <XBoardProfile>[];
      for (final it in j) {
        final p = XBoardProfile.fromJson(it);
        if (p != null) out.add(p);
      }
      out.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveProfiles(List<XBoardProfile> list) async {
    final sp = await _sp();
    await sp.setString(_kProfiles, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<List<XBoardProfile>> upsertProfile(XBoardProfile p) async {
    final profiles = await loadProfiles();
    final idx = profiles.indexWhere((x) => x.id == p.id);
    if (idx >= 0) {
      profiles[idx] = p;
    } else {
      profiles.add(p);
    }
    profiles.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
    await _saveProfiles(profiles);
    return profiles;
  }

  Future<List<XBoardProfile>> updateProfileSubscribe({
    required String id,
    required String authData,
    required String cookie,
    required String subscribeUrl,
  }) async {
    final profiles = await loadProfiles();
    final idx = profiles.indexWhere((x) => x.id == id);
    if (idx >= 0) {
      profiles[idx] = profiles[idx].copyWith(
        authData: authData,
        cookie: cookie,
        lastSubscribeUrl: subscribeUrl,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      profiles.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
      await _saveProfiles(profiles);
    }
    return profiles;
  }

  Future<List<XBoardProfile>> deleteProfile(String id) async {
    final profiles = await loadProfiles();
    profiles.removeWhere((x) => x.id == id);
    await _saveProfiles(profiles);

    final sp = await _sp();
    final cur = sp.getString(_kCurrentProfileId) ?? '';
    if (cur == id) {
      await sp.setString(_kCurrentProfileId, '');
    }
    return profiles;
  }

  Future<void> clearHistory() async {
    final sp = await _sp();
    await sp.remove(_kProfiles);
    await sp.remove(_kCurrentProfileId);
  }
}

class XBoardCurrent {
  XBoardCurrent({
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.lastFetchedAtMs,
    required this.profileId,
  });

  final String baseUrl;
  final String email;
  final String authData;
  final String cookie;
  final String lastSubscribeUrl;
  final int lastFetchedAtMs;
  final String profileId;
}

class XBoardProfile {
  XBoardProfile({
    required this.id,
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.savedAtMs,
  });

  final String id;
  final String baseUrl;
  final String email;
  final String authData;
  final String cookie;
  final String lastSubscribeUrl;
  final int savedAtMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'email': email,
        'authData': authData,
        'cookie': cookie,
        'lastSubscribeUrl': lastSubscribeUrl,
        'savedAtMs': savedAtMs,
      };

  static XBoardProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    final baseUrl = (j['baseUrl'] ?? '').toString();
    final email = (j['email'] ?? '').toString();
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;

    return XBoardProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }

  XBoardProfile copyWith({
    String? authData,
    String? cookie,
    String? lastSubscribeUrl,
    int? savedAtMs,
  }) {
    return XBoardProfile(
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

class XBoardFmt {
  static String time(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}
