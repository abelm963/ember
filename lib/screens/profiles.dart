import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'connect.dart';

const _avatarColors = [Color(0xFF3B7DD8), Color(0xFFC2513A), Color(0xFF4C8C55), Color(0xFF8A56C9), Color(0xFFB8862F), Color(0xFF2F8C8C)];

Color avatarColor(String name) => _avatarColors[name.hashCode.abs() % _avatarColors.length];

class Avatar extends StatelessWidget {
  final String name;
  final String? imageUrl;
  final double size;
  const Avatar({super.key, required this.name, this.imageUrl, this.size = 52});
  @override
  Widget build(BuildContext context) {
    final s = context.px(size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(s * 0.22),
      child: SizedBox(
        width: s,
        height: s,
        child: NetImage(
          imageUrl,
          fallback: Container(
            color: avatarColor(name),
            alignment: Alignment.center,
            child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: display(s * 0.44, height: 1)),
          ),
        ),
      ),
    );
  }
}

/// "Who's watching?" — saved profiles switch instantly; others sign in.
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final saved = app.serverAccounts;
    final jf = app.jf!;
    return Scaffold(
      body: SafeArea(
        child: Loader<List<Map<String, dynamic>>>(
          deps: app.serverUrl,
          load: () async {
            try {
              return await jf.publicUsers();
            } catch (_) {
              return <Map<String, dynamic>>[];
            }
          },
          builder: (context, publicUsers) {
            final savedIds = saved.map((a) => a.userId).toSet();
            final others = publicUsers.where((u) => !savedIds.contains(u['Id'])).toList();
            final tiles = <Widget>[
              for (final a in saved)
                _ProfileTile(
                  name: a.name,
                  note: a.isAdmin ? 'Admin' : '',
                  imageUrl: a.imageTag == null ? null : jf.userImage(a.userId, a.imageTag!),
                  autofocus: a == saved.first,
                  onTap: () => app.switchTo(a),
                ),
              for (final u in others)
                _ProfileTile(
                  name: u['Name'] as String? ?? '',
                  note: 'Sign in',
                  imageUrl: u['PrimaryImageTag'] == null ? null : jf.userImage(u['Id'] as String, u['PrimaryImageTag'] as String),
                  autofocus: saved.isEmpty && u == others.first,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SignInScreen(presetUser: u['Name'] as String?))),
                ),
              _ProfileTile(
                name: 'Add Profile',
                note: 'Another Jellyfin user',
                add: true,
                autofocus: saved.isEmpty && others.isEmpty,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SignInScreen())),
              ),
            ];
            return Stack(children: [
              Positioned(left: context.px(app.isPhone ? 40 : 160), top: context.px(70), child: const EmberLogo()),
              Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: context.px(60), vertical: context.px(160)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text("Who's watching?", style: display(context.px(80))),
                    SizedBox(height: context.px(72)),
                    Wrap(spacing: context.px(56), runSpacing: context.px(48), alignment: WrapAlignment.center, children: tiles),
                    SizedBox(height: context.px(72)),
                    EmberButton(
                      label: 'Change server · ${app.serverName ?? ''}',
                      icon: Icons.dns_outlined,
                      kind: BtnKind.ghost,
                      compact: true,
                      onTap: () => app.forgetServer(),
                    ),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final String name;
  final String note;
  final String? imageUrl;
  final bool add;
  final bool autofocus;
  final VoidCallback onTap;
  const _ProfileTile({
    required this.name,
    required this.note,
    required this.onTap,
    this.imageUrl,
    this.add = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.px(context.app.isPhone ? 170 : 210);
    return Focusable(
      onTap: onTap,
      autofocus: autofocus,
      semanticLabel: name,
      builder: (context, active) => AnimatedScale(
        scale: active ? 1.08 : 1,
        duration: const Duration(milliseconds: 180),
        child: SizedBox(
          width: s + context.px(20),
          child: Column(children: [
            Container(
              padding: EdgeInsets.all(context.px(6)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(context.px(30)),
                border: Border.all(color: active ? C.text : Colors.transparent, width: context.px(5)),
              ),
              child: add
                  ? Container(
                      width: s,
                      height: s,
                      decoration: BoxDecoration(
                        color: C.surface,
                        borderRadius: BorderRadius.circular(context.px(24)),
                        border: Border.all(color: const Color(0xFF4A4A50), width: context.px(3)),
                      ),
                      child: Icon(Icons.add, color: C.faint, size: context.px(88)),
                    )
                  : Avatar(name: name, imageUrl: imageUrl, size: s / scaleOf(context)),
            ),
            SizedBox(height: context.px(16)),
            Text(name,
                textAlign: TextAlign.center,
                style: body(context.px(30), weight: FontWeight.w600, color: active ? C.text : C.muted)),
            SizedBox(height: context.px(4)),
            Text(note, style: body(context.px(19), color: C.faint)),
          ]),
        ),
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  final String? presetUser;
  const SignInScreen({super.key, this.presetUser});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final _user = TextEditingController(text: widget.presetUser ?? '');
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  String? _qcCode;
  String? _qcSecret;
  Timer? _poll;
  bool _qcEnabled = false;

  @override
  void initState() {
    super.initState();
    _startQuickConnect();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _startQuickConnect() async {
    final jf = context.read<AppState>().jf!;
    final enabled = await jf.quickConnectEnabled();
    if (!mounted) return;
    setState(() => _qcEnabled = enabled);
    if (!enabled) return;
    try {
      final (secret, code) = await jf.quickConnectInitiate();
      if (!mounted) return;
      setState(() {
        _qcSecret = secret;
        _qcCode = code;
      });
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkQc());
    } catch (_) {
      setState(() => _qcEnabled = false);
    }
  }

  Future<void> _checkQc() async {
    final app = context.read<AppState>();
    if (_qcSecret == null) return;
    try {
      if (await app.jf!.quickConnectAuthorized(_qcSecret!)) {
        _poll?.cancel();
        final r = await app.jf!.authenticateWithQuickConnect(_qcSecret!);
        await app.signedIn(r);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } catch (_) {}
  }

  Future<void> _signIn() async {
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await app.jf!.authenticateByName(_user.text.trim(), _pass.text);
      await app.signedIn(r, username: _user.text.trim(), password: _pass.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      setState(() => _error = e.status == 401 ? 'Wrong username or password.' : e.message);
    } catch (e) {
      setState(() => _error = "Couldn't sign in: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final qc = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Sign in with your phone', style: display(context.px(60))),
      SizedBox(height: context.px(24)),
      Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'Open Jellyfin on your phone or computer, go to '),
          TextSpan(text: 'Settings › Quick Connect', style: body(context.px(26), weight: FontWeight.w700)),
          const TextSpan(text: ' and enter this code.'),
        ]),
        style: body(context.px(26), color: C.muted, height: 1.5),
      ),
      SizedBox(height: context.px(32)),
      if (_qcCode == null)
        const Loading()
      else
        Wrap(spacing: context.px(14), runSpacing: context.px(14), children: [
          for (final d in _qcCode!.split(''))
            Container(
              width: context.px(92),
              height: context.px(124),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: C.surface,
                borderRadius: BorderRadius.circular(context.px(16)),
                border: Border.all(color: const Color(0xFF2C2C31), width: context.px(2)),
              ),
              child: Text(d, style: display(context.px(68), height: 1)),
            ),
        ]),
      SizedBox(height: context.px(22)),
      Row(children: [
        Container(width: context.px(14), height: context.px(14), decoration: const BoxDecoration(color: C.accent, shape: BoxShape.circle)),
        SizedBox(width: context.px(12)),
        Text('Waiting for approval…', style: body(context.px(22), color: C.faint)),
      ]),
    ]);

    final pw = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(_qcEnabled ? 'Or use your password' : 'Sign in', style: display(context.px(48))),
      SizedBox(height: context.px(28)),
      EmberField(label: 'Username', controller: _user, width: 620, autofocus: !app.isTv && widget.presetUser == null),
      SizedBox(height: context.px(22)),
      EmberField(label: 'Password', controller: _pass, obscure: true, width: 620, onSubmitted: (_) => _signIn()),
      if (_error != null) ...[
        SizedBox(height: context.px(16)),
        Text(_error!, style: body(context.px(22), color: C.bad)),
      ],
      SizedBox(height: context.px(30)),
      Wrap(spacing: context.px(18), runSpacing: context.px(18), children: [
        _busy
            ? SizedBox(width: context.px(160), height: context.px(72), child: const Loading())
            : EmberButton(label: 'Sign In', kind: BtnKind.primary, onTap: _signIn, autofocus: app.isTv && !_qcEnabled),
        EmberButton(label: 'Back', kind: BtnKind.ghost, onTap: () => Navigator.of(context).maybePop()),
      ]),
      if (app.seerrUrl != null) ...[
        SizedBox(height: context.px(30)),
        SizedBox(
          width: context.px(620),
          child: Text('Signing in with a password also signs you in to Seerr, so you can request titles.',
              style: body(context.px(20), color: C.faint, height: 1.4)),
        ),
      ],
    ]);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(context.px(app.isPhone ? 40 : 160), context.px(70), context.px(app.isPhone ? 40 : 160), context.px(60)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const EmberLogo(),
              SizedBox(width: context.px(24)),
              Text(app.serverName ?? '', style: body(context.px(22), color: C.faint)),
            ]),
            SizedBox(height: context.px(80)),
            if (app.isPhone || !_qcEnabled)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_qcEnabled) ...[qc, SizedBox(height: context.px(64))],
                pw,
              ])
            else
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: qc),
                  SizedBox(width: context.px(60)),
                  Container(width: context.px(2), color: const Color(0xFF222226)),
                  SizedBox(width: context.px(60)),
                  Expanded(child: Align(alignment: Alignment.topLeft, child: pw)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
