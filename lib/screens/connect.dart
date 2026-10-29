import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/tv_keyboard.dart';
import '../ui/widgets.dart';

class EmberLogo extends StatelessWidget {
  final double size;
  const EmberLogo({super.key, this.size = 44});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.local_fire_department, color: C.accent, size: context.px(size * 0.95)),
      SizedBox(width: context.px(10)),
      Text('ember', style: display(context.px(size))),
    ],
  );
}

/// A labelled text field sized for TV / desktop / phone.
class EmberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboard;
  final ValueChanged<String>? onSubmitted;
  final String? hint;
  final double width;
  const EmberField({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.autofocus = false,
    this.keyboard,
    this.onSubmitted,
    this.hint,
    this.width = 680,
  });

  InputDecoration _decoration(BuildContext context, {bool focused = false}) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(context.px(14)),
      borderSide: BorderSide(color: c, width: context.px(3)),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: body(context.px(26), color: C.faint),
      filled: true,
      fillColor: C.surface,
      contentPadding: EdgeInsets.symmetric(horizontal: context.px(24), vertical: context.px(22)),
      enabledBorder: border(focused ? C.accent : const Color(0xFF2C2C31)),
      focusedBorder: border(C.accent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: body(context.px(22), color: C.muted, weight: FontWeight.w600),
        ),
        SizedBox(height: context.px(10)),
        SizedBox(
          width: context.app.isPhone ? double.infinity : context.px(width),
          child: isAppleTv
              ? _tvBox(context)
              : FieldFocusEscape(
                  child: TextField(
                    controller: controller,
                    obscureText: obscure,
                    autofocus: autofocus,
                    keyboardType: keyboard,
                    onSubmitted: onSubmitted,
                    style: body(context.px(28)),
                    decoration: _decoration(context),
                  ),
                ),
        ),
      ],
    );
  }

  /// On Apple TV the box is a button: Select opens Apple's keyboard on a native text field, and
  /// the remote moves on from the box like from any other button (a Flutter text field there
  /// keeps the remote stuck after the keyboard closes).
  Widget _tvBox(BuildContext context) => Focusable(
    autofocus: autofocus,
    semanticLabel: label,
    onTap: () async {
      final r = await editOnAppleTv(context, label: label, text: controller.text, obscure: obscure, keyboard: keyboard);
      if (r == null) return;
      controller.text = r.text;
      if (r.submitted) onSubmitted?.call(r.text);
    },
    builder: (context, active) => ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) => InputDecorator(
        decoration: _decoration(context, focused: active),
        isEmpty: v.text.isEmpty,
        child: Text(
          obscure ? '•' * v.text.length : v.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: body(context.px(28)),
        ),
      ),
    ),
  );
}

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _addr = TextEditingController();
  List<DiscoveredServer>? _found;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _found = null);
    final list = await JellyfinClient.discover();
    if (mounted) setState(() => _found = list);
  }

  Future<void> _connect(String url) async {
    if (url.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    // Try the address as typed, then with Jellyfin's usual ports if none was given.
    final base = JellyfinClient.normalizeUrl(url);
    final uri = Uri.tryParse(base);
    final candidates = <String>[base];
    final typedScheme = url.trim().startsWith('http://') || url.trim().startsWith('https://');
    if (!typedScheme) candidates.add(base.replaceFirst('http://', 'https://'));
    if (uri != null && !uri.hasPort) {
      candidates.add(uri.replace(scheme: 'http', port: 8096).toString());
      candidates.add(uri.replace(scheme: 'https', port: 8920).toString());
    }
    Object? lastError;
    try {
      for (final candidate in candidates) {
        try {
          final c = JellyfinClient(baseUrl: candidate, deviceId: app.deviceId, deviceName: app.deviceName);
          final info = await c.publicInfo();
          await app.setServer(c.baseUrl, info['ServerName'] as String? ?? 'Jellyfin');
          return;
        } catch (e) {
          lastError ??= e;
        }
      }
      setState(() => _error = "Couldn't reach a Jellyfin server at that address. ($lastError)");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final form = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const EmberLogo(size: 56),
        SizedBox(height: context.px(56)),
        Text('Connect to your Jellyfin server', style: display(context.px(app.isPhone ? 56 : 72))),
        SizedBox(height: context.px(24)),
        Text(
          "Pick a server found on your network, or type its address. You'll only need to do this once.",
          style: body(context.px(26), color: C.muted, height: 1.45),
        ),
        SizedBox(height: context.px(40)),
        EmberField(
          label: 'Server address',
          controller: _addr,
          hint: 'http://192.168.1.20:8096',
          keyboard: TextInputType.url,
          onSubmitted: _connect,
        ),
        if (_error != null) ...[
          SizedBox(height: context.px(16)),
          Text(_error!, style: body(context.px(22), color: C.bad)),
        ],
        SizedBox(height: context.px(28)),
        _busy
            ? SizedBox(
                height: context.px(72),
                child: const Center(child: CircularProgressIndicator()),
              )
            : EmberButton(label: 'Connect', kind: BtnKind.primary, onTap: () => _connect(_addr.text)),
      ],
    );

    final found = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: context.px(20),
          runSpacing: context.px(12),
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Found on your network',
              style: body(context.px(28), color: C.muted, weight: FontWeight.w700),
            ),
            EmberButton(label: 'Scan again', icon: Icons.refresh, kind: BtnKind.ghost, compact: true, onTap: _scan),
          ],
        ),
        SizedBox(height: context.px(20)),
        if (_found == null)
          Padding(padding: EdgeInsets.all(context.px(24)), child: const Loading())
        else if (_found!.isEmpty)
          Text('No servers found automatically. Type the address instead.', style: body(context.px(22), color: C.faint))
        else
          for (final s in _found!) ...[
            _ServerTile(server: s, autofocus: s == _found!.first, onTap: () => _connect(s.address)),
            SizedBox(height: context.px(14)),
          ],
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: app.isPhone
            ? ListView(
                padding: EdgeInsets.all(context.px(40)),
                children: [
                  form,
                  SizedBox(height: context.px(56)),
                  found,
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(context.px(160), context.px(110), context.px(100), context.px(60)),
                      child: form,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      color: const Color(0xFF121214),
                      height: double.infinity,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(context.px(100), context.px(130), context.px(140), context.px(60)),
                        child: found,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final DiscoveredServer server;
  final VoidCallback onTap;
  final bool autofocus;
  const _ServerTile({required this.server, required this.onTap, this.autofocus = false});

  @override
  Widget build(BuildContext context) => Focusable(
    onTap: onTap,
    autofocus: autofocus,
    semanticLabel: server.name,
    builder: (context, active) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.all(context.px(26)),
      decoration: BoxDecoration(
        color: active ? C.text : C.surface,
        borderRadius: BorderRadius.circular(context.px(16)),
      ),
      child: Row(
        children: [
          Container(
            width: context.px(72),
            height: context.px(72),
            decoration: BoxDecoration(color: C.accentDark, borderRadius: BorderRadius.circular(context.px(16))),
            child: Icon(Icons.dns_outlined, color: C.accent, size: context.px(40)),
          ),
          SizedBox(width: context.px(24)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.name,
                  style: body(
                    context.px(30),
                    weight: FontWeight.w700,
                    color: active ? const Color(0xFF111111) : C.text,
                  ),
                ),
                SizedBox(height: context.px(4)),
                Text(server.address, style: body(context.px(21), color: active ? const Color(0xFF444444) : C.faint)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
