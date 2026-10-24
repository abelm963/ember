import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// Ember's own on-screen keyboard, used for text boxes on Apple TV.
///
/// tvOS's system keyboard hands focus back to a text box the Siri Remote can't leave, so on Apple
/// TV a text box is a button that opens this instead. Returns the new text when the viewer picks
/// Done, or null when they press Menu (the text stays as it was).
Future<String?> showTvKeyboard(
  BuildContext context, {
  required String label,
  required String text,
  bool obscure = false,
  TextInputType? keyboard,
}) => Navigator.of(context).push<String>(
  PageRouteBuilder(
    opaque: false,
    barrierColor: const Color(0xE6000000),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, _, _) => _TvKeyboard(label: label, text: text, obscure: obscure, keyboard: keyboard),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ),
);

enum _Mode { lower, upper, symbols }

class _TvKeyboard extends StatefulWidget {
  final String label;
  final String text;
  final bool obscure;
  final TextInputType? keyboard;
  const _TvKeyboard({required this.label, required this.text, required this.obscure, this.keyboard});
  @override
  State<_TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<_TvKeyboard> {
  late String _text = widget.text;
  _Mode _mode = _Mode.lower;
  bool _reveal = false;

  static const _lower = 'abcdefghijklmnopqrstuvwxyz1234567890';
  static const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';
  static const _symbols = '.:/-_@!?#\$%&*+=()[]{}<>\'",;~^|\\`';

  bool get _isUrl => widget.keyboard == TextInputType.url;
  bool get _isNumber => widget.keyboard == TextInputType.number;

  void _type(String s) => setState(() => _text += s);
  void _delete() => setState(() => _text = _text.isEmpty ? _text : _text.substring(0, _text.length - 1));

  @override
  Widget build(BuildContext context) {
    final keys = _isNumber
        ? '1234567890'
        : switch (_mode) {
            _Mode.lower => _lower,
            _Mode.upper => _upper,
            _Mode.symbols => _symbols,
          };
    final shown = widget.obscure && !_reveal ? '•' * _text.length : _text;

    Widget key(String label, VoidCallback onTap, {bool first = false, bool on = false, IconData? icon}) => Focusable(
      onTap: onTap,
      autofocus: first,
      semanticLabel: label,
      scrollIntoView: false,
      builder: (context, active) => Container(
        height: context.px(64),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: context.px(14)),
        decoration: BoxDecoration(
          color: active ? C.text : (on ? C.accentDark : C.surface2),
          borderRadius: BorderRadius.circular(context.px(10)),
        ),
        child: icon != null
            ? Icon(icon, size: context.px(30), color: active ? const Color(0xFF111111) : C.muted)
            : Text(
                label,
                maxLines: 1,
                style: body(context.px(28), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.soft),
              ),
      ),
    );

    Widget row(List<Widget> children) => Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(width: context.px(8)), Expanded(child: children[i])],
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SizedBox(
          width: context.px(1100),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.label,
                style: body(context.px(26), color: C.muted, weight: FontWeight.w600),
              ),
              SizedBox(height: context.px(12)),
              Container(
                padding: EdgeInsets.symmetric(horizontal: context.px(24), vertical: context.px(20)),
                decoration: BoxDecoration(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(context.px(14)),
                  border: Border.all(color: C.accent, width: context.px(3)),
                ),
                child: Text(shown.isEmpty ? ' ' : '$shown▏', style: body(context.px(34), weight: FontWeight.w600)),
              ),
              SizedBox(height: context.px(28)),
              FocusTraversalGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GridView.count(
                      crossAxisCount: 10,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: context.px(8),
                      crossAxisSpacing: context.px(8),
                      childAspectRatio: 1.45,
                      children: [for (var i = 0; i < keys.length; i++) key(keys[i], () => _type(keys[i]), first: i == 0)],
                    ),
                    SizedBox(height: context.px(8)),
                    if (_isUrl) ...[
                      row([
                        key('http://', () => _type('http://')),
                        key('https://', () => _type('https://')),
                        key('.', () => _type('.')),
                        key(':', () => _type(':')),
                        key('/', () => _type('/')),
                        key(':8096', () => _type(':8096')),
                      ]),
                      SizedBox(height: context.px(8)),
                    ],
                    row([
                      if (!_isNumber) ...[
                        key(
                          _mode == _Mode.upper ? 'abc' : 'ABC',
                          () => setState(() => _mode = _mode == _Mode.upper ? _Mode.lower : _Mode.upper),
                          on: _mode == _Mode.upper,
                        ),
                        key(
                          _mode == _Mode.symbols ? 'abc' : '#+=',
                          () => setState(() => _mode = _mode == _Mode.symbols ? _Mode.lower : _Mode.symbols),
                          on: _mode == _Mode.symbols,
                        ),
                        key('Space', () => _type(' ')),
                      ],
                      if (widget.obscure)
                        key(
                          _reveal ? 'Hide' : 'Show',
                          () => setState(() => _reveal = !_reveal),
                          icon: _reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        ),
                      key('Delete', _delete, icon: Icons.backspace_outlined),
                      key('Clear', () => setState(() => _text = '')),
                    ]),
                    SizedBox(height: context.px(20)),
                    Align(
                      alignment: Alignment.centerRight,
                      child: EmberButton(label: 'Done', kind: BtnKind.primary, onTap: () => Navigator.of(context).pop(_text)),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.px(16)),
              Text('Press Menu to cancel', style: body(context.px(20), color: C.faint)),
            ],
          ),
        ),
      ),
    );
  }
}
