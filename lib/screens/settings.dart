import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/jellyfin.dart';
import '../api/seerr.dart';
import '../platform.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'connect.dart';
import 'profiles.dart';

class SettingsScreen extends StatefulWidget {
  final String initialCategory;
  const SettingsScreen({super.key, this.initialCategory = 'Account'});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

const _cats = ['Account', 'Profiles', 'Playback', 'Trailers & calendar', 'Seerr requests', 'Interface', 'About'];

class _SettingsScreenState extends State<SettingsScreen> {
  late String _cat = widget.initialCategory;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pad = context.px(gutter(context));
    final content = switch (_cat) {
      'Account' => _account(context, app),
      'Profiles' => _profiles(context, app),
      'Seerr requests' => _seerr(context, app),
      'Playback' => _playback(context, app),
      'Trailers & calendar' => _trailers(context, app),
      'Interface' => _interface(context, app),
      _ => _about(context, app),
    };

    final catList = FocusTraversalGroup(
      child: app.isPhone
          ? Wrap(spacing: context.px(12), runSpacing: context.px(12), children: [
              for (final c in _cats) Chip2(label: c, selected: _cat == c, onTap: () => setState(() => _cat = c)),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final c in _cats)
                Padding(
                  padding: EdgeInsets.only(bottom: context.px(6)),
                  child: Focusable(
                    onTap: () => setState(() => _cat = c),
                    onFocusChange: (f) {
                      if (f && app.isTv) setState(() => _cat = c);
                    },
                    semanticLabel: c,
                    builder: (context, active) => Container(
                      height: context.px(68),
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.symmetric(horizontal: context.px(24)),
                      decoration: BoxDecoration(
                        color: active ? C.text : (_cat == c ? C.surface3 : Colors.transparent),
                        borderRadius: BorderRadius.circular(context.px(12)),
                      ),
                      child: Text(c,
                          style: body(context.px(26),
                              weight: FontWeight.w700,
                              color: active ? const Color(0xFF111111) : (_cat == c ? C.text : C.faint))),
                    ),
                  ),
                ),
            ]),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, context.px(app.isTv ? 60 : 30), pad, 0),
      child: app.isPhone
          ? ListView(children: [
              Text('Settings', style: display(context.px(72))),
              SizedBox(height: context.px(24)),
              catList,
              SizedBox(height: context.px(28)),
              content,
              SizedBox(height: context.px(80)),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Settings', style: display(context.px(72))),
              SizedBox(height: context.px(36)),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: context.px(400), child: catList),
                  SizedBox(width: context.px(70)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(bottom: context.px(80)),
                      child: FocusTraversalGroup(child: content),
                    ),
                  ),
                ]),
              ),
            ]),
    );
  }

  // ------------------------------------------------------------------ sections

  Widget _account(BuildContext context, AppState app) {
    final a = app.account!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Card(children: [
        Avatar(name: a.name, imageUrl: a.imageTag == null ? null : app.jf!.userImage(a.userId, a.imageTag!), size: 96),
        SizedBox(width: context.px(26)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.name, style: body(context.px(34), weight: FontWeight.w700)),
            Text('${a.isAdmin ? 'Administrator' : 'User'} · ${app.serverName}', style: body(context.px(22), color: C.faint)),
          ]),
        ),
      ]),
      SettingRow(label: 'Switch profile', value: '${app.serverAccounts.length} saved', onTap: () => app.leaveProfile()),
      SettingRow(
        label: 'Approve a Quick Connect code',
        value: 'Sign in on another device',
        onTap: () => _quickConnectApprove(context, app),
      ),
      SettingRow(label: 'Server', value: app.serverUrl ?? '', onTap: () => _confirm(context, 'Change server?', 'You will need to sign in again on the new server.', app.forgetServer)),
      SettingRow(
        label: 'Sign out',
        value: '',
        danger: true,
        onTap: () => _confirm(context, 'Sign out of ${a.name}?', 'This removes the saved profile from this device.', app.signOut),
      ),
    ]);
  }

  Widget _profiles(BuildContext context, AppState app) {
    final jf = app.jf!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final a in app.serverAccounts)
        Padding(
          padding: EdgeInsets.only(bottom: context.px(10)),
          child: Focusable(
            onTap: () => app.switchTo(a),
            semanticLabel: a.name,
            builder: (context, active) => Container(
              padding: EdgeInsets.symmetric(horizontal: context.px(26), vertical: context.px(14)),
              decoration: BoxDecoration(color: active ? C.text : C.surface, borderRadius: BorderRadius.circular(context.px(14))),
              child: Row(children: [
                Avatar(name: a.name, imageUrl: a.imageTag == null ? null : jf.userImage(a.userId, a.imageTag!), size: 56),
                SizedBox(width: context.px(22)),
                Expanded(
                  child: Text(a.name,
                      style: body(context.px(25), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.text)),
                ),
                Text(a.userId == app.currentUserId ? 'Watching now' : (a.isAdmin ? 'Admin' : 'Switch'),
                    style: body(context.px(21), color: active ? const Color(0xFF444444) : C.faint)),
              ]),
            ),
          ),
        ),
      SettingRow(label: 'Add a profile', value: 'Sign in another Jellyfin user', onTap: () => app.leaveProfile()),
      Padding(
        padding: EdgeInsets.only(top: context.px(10)),
        child: Text('Profiles are your Jellyfin users. Parental limits and who may request titles are set in Jellyfin and Seerr.',
            style: body(context.px(20), color: C.faint, height: 1.5)),
      ),
    ]);
  }

  Widget _seerr(BuildContext context, AppState app) {
    final user = app.seerrUser;
    final ok = app.seerrConfigured && user != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Card(children: [
        Container(
          width: context.px(16),
          height: context.px(16),
          decoration: BoxDecoration(color: ok ? C.good : (app.seerrUrl == null ? C.faint : C.warn), shape: BoxShape.circle),
        ),
        SizedBox(width: context.px(18)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                ok
                    ? 'Connected to Seerr'
                    : app.seerrUrl == null
                        ? 'Seerr is not set up'
                        : 'Seerr address saved, not signed in',
                style: body(context.px(28), weight: FontWeight.w700)),
            Text(
              ok
                  ? '${app.seerrUrl} · signed in as ${user['displayName'] ?? user['jellyfinUsername'] ?? 'you'}${app.canManageRequests ? ' · can approve requests' : ''}'
                  : app.seerrUrl == null
                      ? 'Add the address you open Seerr with. Ember signs you in with your Jellyfin profile.'
                      : (app.seerrError ?? 'Signing in…'),
              style: body(context.px(21), color: !ok && app.seerrError != null ? C.bad : C.faint),
            ),
          ]),
        ),
      ]),
      SettingRow(label: 'Seerr address', value: app.seerrUrl ?? 'Not set', onTap: () => _editSeerr(context, app)),
      SettingRow(
        label: 'Sign in to Seerr',
        value: ok ? 'Signed in' : 'Sign in',
        onTap: app.seerrUrl == null ? () => toast(context, 'Add the Seerr address first.') : () => _seerrSignIn(context, app),
      ),
      SettingRow(
        label: 'Check connection',
        value: 'Run test',
        onTap: app.seerrUrl == null ? () => toast(context, 'Add the Seerr address first.') : () => _seerrCheck(context, app),
      ),
      SettingRow(
        label: 'API key (optional)',
        value: app.seerrApiKey == null ? 'Not set' : 'Saved',
        onTap: () => _editSeerr(context, app, apiKeyOnly: true),
      ),
      ToggleRow(
        label: 'Show "Trending — not in your library" on Home',
        value: app.showTrendingRow,
        onChanged: (v) => app.update((s) => s.showTrendingRow = v),
      ),
      ToggleRow(
        label: 'Show my requests in My List',
        value: app.addRequestsToMyList,
        onChanged: (v) => app.update((s) => s.addRequestsToMyList = v),
      ),
    ]);
  }

  Widget _playback(BuildContext context, AppState app) {
    final q = qualityOptions.firstWhere((o) => o.key == app.quality, orElse: () => qualityOptions.first);
    const subModes = {'off': 'Off', 'foreign': 'Only for foreign audio', 'always': 'Always on'};
    const langs = {
      null: 'Default track',
      'eng': 'English',
      'afr': 'Afrikaans',
      'zul': 'Zulu',
      'xho': 'Xhosa',
      'fre': 'French',
      'spa': 'Spanish',
      'ger': 'German',
      'por': 'Portuguese',
      'jpn': 'Japanese',
      'kor': 'Korean',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingRow(
        label: 'Streaming quality',
        value: q.label,
        onTap: () => pickOption<String>(
          context,
          'Streaming quality',
          {for (final o in qualityOptions) o.key: o.label},
          app.quality,
          (v) => app.update((s) => s.quality = v),
        ),
      ),
      SettingRow(
        label: 'Preferred audio language',
        value: langs[app.preferredAudioLanguage] ?? app.preferredAudioLanguage!,
        onTap: () => pickOption<String?>(context, 'Preferred audio language', langs, app.preferredAudioLanguage,
            (v) => app.update((s) => s.preferredAudioLanguage = v)),
      ),
      SettingRow(
        label: 'Subtitles',
        value: subModes[app.subtitleMode] ?? '',
        onTap: () => pickOption<String>(context, 'Subtitles', subModes, app.subtitleMode, (v) => app.update((s) => s.subtitleMode = v)),
      ),
      ToggleRow(label: 'Autoplay next episode', value: app.autoplayNext, onChanged: (v) => app.update((s) => s.autoplayNext = v)),
      ToggleRow(label: 'Skip intros automatically', value: app.autoSkipIntro, onChanged: (v) => app.update((s) => s.autoSkipIntro = v)),
      if (isAppleTv) ...[
        ToggleRow(
          label: 'Ask "Are you still watching?"',
          value: app.stillWatching,
          onChanged: (v) => app.update((s) => s.stillWatching = v),
        ),
        if (app.stillWatching)
          SettingRow(
            label: 'Ask after',
            value: '${app.stillWatchingEpisodes} episodes in a row',
            onTap: () => pickOption<int>(
                context,
                'Ask "Are you still watching?" after',
                {for (final n in [1, 2, 3, 4, 5, 6, 8]) n: '$n episode${n == 1 ? '' : 's'} in a row'},
                app.stillWatchingEpisodes,
                (v) => app.update((s) => s.stillWatchingEpisodes = v)),
          ),
        Padding(
          padding: EdgeInsets.only(top: context.px(6)),
          child: Text(
            'Only when the episodes played one after another with nothing pressed on the remote: '
            'no pause or play, no skipping or scrubbing, no change of audio or subtitles. '
            'Volume goes straight from the remote to the TV, so Ember can\'t see it.',
            style: body(context.px(20), color: C.faint, height: 1.5),
          ),
        ),
      ],
      SizedBox(height: context.px(20)),
      Text('PICTURE AND SOUND', style: body(context.px(20), color: C.faint, weight: FontWeight.w700).copyWith(letterSpacing: 3)),
      SizedBox(height: context.px(12)),
      if (isAppleTv)
        Text(
          'Ember plays with Apple TV\'s own player: HDR10, HDR10+, Dolby Vision and Dolby Atmos come through as they are. '
          'For the TV to switch into HDR or Dolby Vision, turn on Apple TV Settings › Video and Audio › Match Content '
          '(Match Dynamic Range and Match Frame Rate). '
          'Enhance Dialogue (Apple TV 4K, tvOS 18 or later): while a video plays, open the player\'s audio options.',
          style: body(context.px(20), color: C.faint, height: 1.5),
        )
      else ...[
      ToggleRow(
        label: 'HDR output (HDR10, HDR10+, HLG, Dolby Vision)',
        value: app.hdrOutput,
        onChanged: (v) => app.update((s) => s.hdrOutput = v),
      ),
      ToggleRow(
        label: 'Send surround sound to my receiver or soundbar (passthrough)',
        value: app.audioPassthrough,
        onChanged: (v) => app.update((s) => s.audioPassthrough = v),
      ),
      Padding(
        padding: EdgeInsets.only(top: context.px(6)),
        child: Text(
          'Turn passthrough on when this device is connected over HDMI to an AV receiver or soundbar: '
          'Dolby Atmos, TrueHD, DTS-HD MA and DTS:X are then sent untouched for it to decode. '
          'Leave it off for TV speakers or headphones; surround is then decoded here.',
          style: body(context.px(20), color: C.faint, height: 1.5),
        ),
      ),
      ],
    ]);
  }

  Widget _trailers(BuildContext context, AppState app) {
    final t = app.trailerService;
    final status = t?['status'] as String?;
    final color = switch (status) { 'Online' => C.good, 'Degraded' => C.warn, _ => C.faint };
    final title = switch (status) {
      'Online' => 'Server trailer service is online',
      'Degraded' => 'Server trailer service is having trouble',
      'Offline' => 'Server trailer service is installed but not working',
      _ => 'Server trailer service is not installed',
    };
    final admin = app.account?.isAdmin ?? false;
    final detail = t == null
        ? (admin
            ? 'Ember can set this up on your server for you. It takes about a minute and restarts the server once. '
                'Until then, trailers open in the YouTube app.'
            : 'Ask your server admin to set it up from Ember › Settings › Trailers & calendar on an admin profile. '
                'Until then, trailers open in the YouTube app.')
        : 'Official trailers streamed by your server · nothing stored'
            '${app.trailerPluginVersion != null ? ' · plugin ${app.trailerPluginVersion}' : ''}'
            ' · yt-dlp ${t['ytDlpVersion'] ?? 'not downloaded yet'}'
            '${t['jsRuntime'] != null ? ' · Deno' : ''}'
            '${status == 'Degraded' ? ' · falling back to YouTube for now' : ''}'
            '${t['lastError'] != null ? '\nLast problem: ${t['lastError']}' : ''}';
    final outdated = t != null && !((t['features'] as List?)?.contains('streamtest') ?? false);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Card(children: [
        Container(width: context.px(16), height: context.px(16), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        SizedBox(width: context.px(18)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: body(context.px(28), weight: FontWeight.w700)),
            Text(detail, style: body(context.px(21), color: C.faint, height: 1.4)),
          ]),
        ),
      ]),
      if (t == null && admin)
        SettingRow(label: 'Set up trailer service', value: 'Install on server', onTap: () => runTrailerSetup(context)),
      if (outdated && admin)
        SettingRow(label: 'Update trailer service', value: 'New version available', onTap: () => runTrailerSetup(context)),
      if (admin && t != null && ((t['features'] as List?)?.contains('streamtest') ?? false))
        SettingRow(label: 'Test trailer playback', value: 'Run test', onTap: () => _trailerTest(context, app)),
      SettingRow(label: 'Check again', value: '', onTap: () => app.refreshTrailerService()),
      ToggleRow(label: 'Play trailers in the app', value: app.trailersInApp, onChanged: (v) => app.update((s) => s.trailersInApp = v)),
      ToggleRow(
        label: 'Autoplay previews while browsing',
        value: app.autoplayPreviews,
        onChanged: (v) => app.update((s) => s.autoplayPreviews = v),
      ),
      ToggleRow(label: 'Start previews muted', value: app.previewsMuted, onChanged: (v) => app.update((s) => s.previewsMuted = v)),
      SizedBox(height: context.px(30)),
      Text('Coming Soon calendar', style: body(context.px(26), weight: FontWeight.w700)),
      SizedBox(height: context.px(12)),
      SettingRow(
        label: 'Release dates',
        value: switch (t?['calendarKey']) {
          'jellyfin-builtin' || 'jellyfin-custom' => 'TMDB, using Jellyfin\'s key',
          'ember' => 'TMDB',
          null => t == null ? 'Needs the trailer service' : 'Update the trailer service',
          _ => 'No TMDB key found',
        },
        onTap: admin && t != null && t['calendarKey'] == null
            ? () => runTrailerSetup(context)
            : () => app.refreshTrailerService(),
      ),
      if (admin && t != null)
        SettingRow(
          label: 'Trakt (optional, more titles)',
          value: t['traktConfigured'] == true ? 'Saved on server' : 'Add key',
          onTap: () => _traktKey(context, app),
        ),
      Padding(
        padding: EdgeInsets.only(top: context.px(14)),
        child: Text(
          'Keys stay in the plugin\'s settings on your server. Ember never stores them, and they are never part of the app.',
          style: body(context.px(20), color: C.faint, height: 1.5),
        ),
      ),
    ]);
  }

  Future<void> _trailerTest(BuildContext context, AppState app) async {
    Map<String, dynamic>? result;
    String? failure;
    void Function(void Function())? refresh;
    () async {
      try {
        // Moana's official trailer: a known-good, verified upload.
        result = await app.jf!.testTrailerStream('LKFuXETZUsI');
      } catch (e) {
        failure = '$e';
      }
      refresh?.call(() {});
    }();
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        refresh = (f) {
          if (ctx.mounted) setD(f);
        };
        final r = result;
        String line(String label, Object? v) => '$label: ${v ?? '—'}';
        return _EmberDialog(title: 'Trailer playback test', children: [
          if (r == null && failure == null) ...[
            Row(children: [
              SizedBox(width: ctx.px(34), height: ctx.px(34), child: const CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(width: ctx.px(20)),
              Expanded(
                child: Text('${app.serverName ?? 'Your server'} is fetching a trailer from YouTube (up to 40 seconds)…',
                    style: body(ctx.px(23), color: C.muted)),
              ),
            ]),
          ] else if (failure != null)
            Text(failure!, style: body(ctx.px(22), color: C.bad, height: 1.4))
          else ...[
            Row(children: [
              Icon(r!['ok'] == true ? Icons.check : Icons.close, color: r['ok'] == true ? C.good : C.bad, size: ctx.px(32)),
              SizedBox(width: ctx.px(14)),
              Expanded(
                child: Text(r['ok'] == true ? 'Trailers stream from your server' : 'Streaming failed',
                    style: body(ctx.px(26), weight: FontWeight.w700)),
              ),
            ]),
            SizedBox(height: ctx.px(16)),
            SelectableText(
              [
                line('Stage', r['stage']),
                line('Looking up the video', r['infoMs'] == null ? null : '${r['infoMs']} ms'),
                line('First video data after', r['firstByteMs'] == null ? 'never' : '${r['firstByteMs']} ms'),
                line('Received', r['bytes'] == null ? null : '${((r['bytes'] as num) / 1e6).toStringAsFixed(1)} MB at ${r['mbps']} Mbps'),
                line('Format', r['container']),
                line('Deno', r['deno'] == true ? 'yes' : 'no'),
                if (r['error'] != null) line('Error', r['error']),
              ].join('\n'),
              style: body(ctx.px(21), color: C.muted, height: 1.6),
            ),
          ],
          SizedBox(height: ctx.px(26)),
          EmberButton(label: 'Close', kind: BtnKind.ghost, autofocus: true, onTap: () => Navigator.pop(ctx)),
        ]);
      }),
    );
    refresh = null;
  }

  Future<void> _traktKey(BuildContext context, AppState app) async {
    final key = TextEditingController();
    String? error;
    var busy = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => _EmberDialog(title: 'Trakt key', children: [
          Text('Paste the Client ID of your Trakt API app (trakt.tv › Settings › Your API Apps). '
              'It\'s saved on ${app.serverName ?? 'your server'} and adds Trakt\'s most anticipated titles to Coming Soon. '
              'Leave it empty and save to remove it.',
              style: body(ctx.px(22), color: C.muted, height: 1.45)),
          SizedBox(height: ctx.px(22)),
          EmberField(label: 'Client ID', controller: key, autofocus: true, width: 640),
          if (error != null) ...[SizedBox(height: ctx.px(14)), Text(error!, style: body(ctx.px(21), color: C.bad))],
          SizedBox(height: ctx.px(26)),
          Wrap(spacing: ctx.px(14), children: [
            busy
                ? SizedBox(width: ctx.px(160), height: ctx.px(72), child: const Loading())
                : EmberButton(
                    label: 'Save to server',
                    kind: BtnKind.accent,
                    onTap: () async {
                      setD(() => busy = true);
                      try {
                        await app.jf!.saveCalendarKeys(traktClientId: key.text.trim());
                        key.clear();
                        await app.refreshTrailerService();
                        app.bumpRevision();
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setD(() {
                          busy = false;
                          error = '$e';
                        });
                      }
                    },
                  ),
            EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx)),
          ]),
        ]),
      ),
    );
    key.dispose();
  }

  Widget _interface(BuildContext context, AppState app) {
    const modes = {
      InterfaceMode.auto: 'Automatic',
      InterfaceMode.tv: 'TV (remote / arrow keys)',
      InterfaceMode.desktop: 'Desktop (mouse and keyboard)',
      InterfaceMode.phone: 'Phone (touch) · preview',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingRow(
        label: 'Layout',
        value: modes[app.interfaceMode]!,
        onTap: () => pickOption<InterfaceMode>(context, 'Layout', modes, app.interfaceMode, (v) => app.update((s) => s.interfaceMode = v)),
      ),
      Padding(
        padding: EdgeInsets.only(top: context.px(14)),
        child: Text(
          'TV layout is what Apple TV and Android TV use: a side menu and big focus highlights, '
          'driven by the arrow keys, Enter and Esc. Use it on Windows to test remote navigation.',
          style: body(context.px(21), color: C.faint, height: 1.5),
        ),
      ),
    ]);
  }

  Widget _about(BuildContext context, AppState app) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingRow(label: 'App version', value: 'Ember $kClientVersion (preview)', onTap: () {}),
        SettingRow(label: 'Player', value: 'mpv (plays every format; server transcodes only for slow connections)', onTap: () {}),
        SettingRow(label: 'This device', value: app.deviceName, onTap: () {}),
      ]);

  // ------------------------------------------------------------------ dialogs

  Future<void> _confirm(BuildContext context, String title, String text, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _EmberDialog(title: title, children: [
        Text(text, style: body(ctx.px(24), color: C.muted, height: 1.4)),
        SizedBox(height: ctx.px(30)),
        Wrap(spacing: ctx.px(14), children: [
          EmberButton(label: 'Yes', kind: BtnKind.accent, onTap: () => Navigator.pop(ctx, true)),
          EmberButton(label: 'Cancel', kind: BtnKind.ghost, autofocus: true, onTap: () => Navigator.pop(ctx, false)),
        ]),
      ]),
    );
    if (ok == true) await action();
  }

  Future<void> _quickConnectApprove(BuildContext context, AppState app) async {
    final code = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => _EmberDialog(title: 'Approve Quick Connect', children: [
        Text('Enter the code shown on the device you are signing in to.', style: body(ctx.px(23), color: C.muted)),
        SizedBox(height: ctx.px(24)),
        EmberField(label: 'Code', controller: code, autofocus: true, keyboard: TextInputType.number, width: 400),
        SizedBox(height: ctx.px(28)),
        Wrap(spacing: ctx.px(14), children: [
          EmberButton(
            label: 'Approve',
            kind: BtnKind.accent,
            onTap: () async {
              try {
                await app.jf!.authorizeQuickConnect(code.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) toast(context, 'Approved. The other device is signing in.');
              } catch (e) {
                if (ctx.mounted) toast(ctx, "That code didn't work: $e");
              }
            },
          ),
          EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx)),
        ]),
      ]),
    );
  }

  Future<void> _editSeerr(BuildContext context, AppState app, {bool apiKeyOnly = false}) async {
    final url = TextEditingController(text: app.seerrUrl ?? '');
    final key = TextEditingController(text: app.seerrApiKey ?? '');
    String? error;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => _EmberDialog(title: apiKeyOnly ? 'Seerr API key' : 'Seerr address', children: [
          if (!apiKeyOnly) ...[
            EmberField(label: 'Address', controller: url, autofocus: true, hint: 'http://192.168.1.20:5055', keyboard: TextInputType.url),
            SizedBox(height: ctx.px(20)),
          ],
          if (apiKeyOnly) ...[
            Text(
              'Optional. With an API key every request is made as the key owner. Signing in with your '
              'Jellyfin password is better: requests are then made as you.',
              style: body(ctx.px(21), color: C.faint, height: 1.4),
            ),
            SizedBox(height: ctx.px(20)),
            EmberField(label: 'API key (Seerr › Settings › General)', controller: key, autofocus: true),
            SizedBox(height: ctx.px(20)),
          ],
          if (error != null) Text(error!, style: body(ctx.px(21), color: C.bad)),
          SizedBox(height: ctx.px(20)),
          Wrap(spacing: ctx.px(14), children: [
            EmberButton(
              label: 'Save',
              kind: BtnKind.accent,
              onTap: () async {
                var u = apiKeyOnly ? (app.seerrUrl ?? '') : SeerrClient.normalize(url.text);
                if (u.isNotEmpty && !apiKeyOnly && !await SeerrClient(baseUrl: u).ping()) {
                  // Try the bare server address too, in case a page path was left on the link.
                  final origin = Uri.tryParse(u)?.replace(path: '').toString();
                  final secure = u.replaceFirst('http://', 'https://');
                  if (origin != null && origin != u && await SeerrClient(baseUrl: origin).ping()) {
                    u = origin;
                  } else if (secure != u && await SeerrClient(baseUrl: secure).ping()) {
                    u = secure;
                  } else {
                    setD(() => error = "Couldn't find Seerr at that address. Use the address you open Seerr with, "
                        'e.g. https://hearth.example.ts.net:10002');
                    return;
                  }
                }
                await app.setSeerr(url: u, apiKey: apiKeyOnly ? key.text : app.seerrApiKey);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx)),
          ]),
        ]),
      ),
    );
  }

  /// Runs every Seerr call Ember uses and shows which work.
  Future<void> _seerrCheck(BuildContext context, AppState app) async {
    final results = <(String, bool, String)>[];
    var done = false;
    void Function(void Function())? refresh;
    Future<void> step(String name, Future<String> Function() f) async {
      try {
        results.add((name, true, await f()));
      } catch (e) {
        results.add((name, false, '$e'));
      }
      refresh?.call(() {});
    }

    () async {
      await app.refreshSeerr();
      final s = app.seerr!;
      await step('Server', () async {
        final st = await s.status();
        return 'Seerr ${st['version'] ?? ''} at ${s.baseUrl}';
      });
      await step('Signed in', () async {
        final u = await s.me();
        return '${u['displayName'] ?? u['jellyfinUsername'] ?? u['email'] ?? 'user'}'
            '${SeerrClient.canManageRequests(u) ? ' · can approve requests' : ''}';
      });
      await step('Trending', () async => '${(await s.trending()).length} titles');
      await step('Search', () async => '${(await s.search('dune')).length} results for "dune"');
      await step('Requests', () async => '${(await s.requests(take: 10)).length} recent requests');
      done = true;
      refresh?.call(() {});
    }();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        refresh = (f) {
          if (ctx.mounted) setD(f);
        };
        return _EmberDialog(title: 'Seerr connection', children: [
          for (final r in results)
            Padding(
              padding: EdgeInsets.only(bottom: ctx.px(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(r.$2 ? Icons.check : Icons.close, color: r.$2 ? C.good : C.bad, size: ctx.px(28)),
                SizedBox(width: ctx.px(14)),
                SizedBox(width: ctx.px(150), child: Text(r.$1, style: body(ctx.px(22), weight: FontWeight.w700))),
                Expanded(child: Text(r.$3, style: body(ctx.px(21), color: C.muted, height: 1.35))),
              ]),
            ),
          if (!done) SizedBox(height: ctx.px(60), child: const Loading()),
          SizedBox(height: ctx.px(18)),
          EmberButton(label: 'Close', kind: BtnKind.ghost, autofocus: true, onTap: () => Navigator.pop(ctx)),
        ]);
      }),
    );
    refresh = null;
  }

  Future<void> _seerrSignIn(BuildContext context, AppState app) async {
    // First try without a password (Jellyfin Quick Connect, approved by this profile).
    if (await app.seerrAutoSignIn(force: true)) {
      await app.refreshSeerr();
      if (context.mounted && app.seerrUser != null) {
        toast(context, 'Signed in to Seerr');
        return;
      }
    }
    if (!context.mounted) return;
    final user = TextEditingController(text: app.account?.name ?? '');
    final pass = TextEditingController();
    String? error;
    bool busy = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => _EmberDialog(title: 'Sign in to Seerr', children: [
          Text('Ember couldn\'t sign in automatically${app.seerrError != null ? ' (${app.seerrError})' : ''}. Use your Jellyfin username and password instead.',
              style: body(ctx.px(22), color: C.muted, height: 1.4)),
          SizedBox(height: ctx.px(22)),
          EmberField(label: 'Username', controller: user, width: 560),
          SizedBox(height: ctx.px(18)),
          EmberField(label: 'Password', controller: pass, obscure: true, autofocus: true, width: 560),
          if (error != null) ...[SizedBox(height: ctx.px(14)), Text(error!, style: body(ctx.px(21), color: C.bad))],
          SizedBox(height: ctx.px(26)),
          Wrap(spacing: ctx.px(14), children: [
            busy
                ? SizedBox(width: ctx.px(160), height: ctx.px(72), child: const Loading())
                : EmberButton(
                    label: 'Sign In',
                    kind: BtnKind.accent,
                    onTap: () async {
                      setD(() => busy = true);
                      try {
                        await app.seerrSignIn(user.text.trim(), pass.text);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setD(() {
                          busy = false;
                          error = '$e';
                        });
                      }
                    },
                  ),
            EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx)),
          ]),
        ]),
      ),
    );
  }
}

/// A list picker that works with a remote, a mouse or a finger.
Future<void> pickOption<T>(BuildContext context, String title, Map<T, String> options, T current, ValueChanged<T> onPick) async {
  await showDialog(
    context: context,
    builder: (ctx) => _EmberDialog(title: title, children: [
      for (final e in options.entries)
        Padding(
          padding: EdgeInsets.only(bottom: ctx.px(8)),
          child: Focusable(
            autofocus: e.key == current,
            onTap: () {
              onPick(e.key);
              Navigator.pop(ctx);
            },
            semanticLabel: e.value,
            builder: (context, active) => Container(
              height: context.px(66),
              padding: EdgeInsets.symmetric(horizontal: context.px(20)),
              decoration: BoxDecoration(color: active ? C.text : C.surface2, borderRadius: BorderRadius.circular(context.px(12))),
              child: Row(children: [
                SizedBox(
                  width: context.px(40),
                  child: e.key == current ? Icon(Icons.check, color: active ? const Color(0xFF111111) : C.accent, size: context.px(28)) : null,
                ),
                Expanded(
                  child: Text(e.value,
                      style: body(context.px(24), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.soft)),
                ),
              ]),
            ),
          ),
        ),
    ]),
  );
}

/// Asks an admin once (per server) whether to set up in-app trailers. Called after sign-in.
Future<void> offerTrailerSetup(BuildContext context) async {
  final app = context.read<AppState>();
  if (!await app.shouldOfferTrailerSetup() || !context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => _EmberDialog(title: 'Play trailers inside Ember?', children: [
      Text(
        'Ember can add its trailer service to ${app.serverName ?? 'your server'}. Your server then streams official '
        'trailers straight to Ember, with nothing stored. Without it, trailers open in the YouTube app.',
        style: body(ctx.px(23), color: C.muted, height: 1.45),
      ),
      SizedBox(height: ctx.px(14)),
      Text('Takes about a minute. The server restarts once, so anyone watching right now will be interrupted.',
          style: body(ctx.px(21), color: C.faint, height: 1.4)),
      SizedBox(height: ctx.px(28)),
      Wrap(spacing: ctx.px(14), runSpacing: ctx.px(14), children: [
        EmberButton(label: 'Set up now', kind: BtnKind.accent, autofocus: true, onTap: () => Navigator.pop(ctx, true)),
        EmberButton(label: 'Later', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx, false)),
      ]),
      SizedBox(height: ctx.px(16)),
      Text('You can always do this in Settings › Trailers & calendar.', style: body(ctx.px(19), color: C.faint)),
    ]),
  );
  if (go == true && context.mounted) {
    await runTrailerSetup(context, confirmed: true);
  } else {
    await app.dismissTrailerPrompt();
  }
}

/// Installs the trailer service on the server, showing each step.
Future<void> runTrailerSetup(BuildContext context, {bool confirmed = false}) async {
  final app = context.read<AppState>();
  if (!confirmed) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _EmberDialog(title: 'Set up trailer service', children: [
        Text('Ember will install its trailer plugin on ${app.serverName ?? 'your server'} and restart the server once '
            '(about a minute). Anyone watching right now will be interrupted.',
            style: body(ctx.px(23), color: C.muted, height: 1.45)),
        SizedBox(height: ctx.px(28)),
        Wrap(spacing: ctx.px(14), children: [
          EmberButton(label: 'Install', kind: BtnKind.accent, autofocus: true, onTap: () => Navigator.pop(ctx, true)),
          EmberButton(label: 'Cancel', kind: BtnKind.ghost, onTap: () => Navigator.pop(ctx, false)),
        ]),
      ]),
    );
    if (ok != true || !context.mounted) return;
  }
  String? error;
  var done = false;
  void Function(void Function())? refresh;
  () async {
    try {
      await app.installTrailerService();
    } catch (e) {
      error = '$e';
    }
    done = true;
    refresh?.call(() {});
  }();
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      refresh = (f) {
        if (ctx.mounted) setD(f);
      };
      return Consumer<AppState>(
        builder: (ctx, a, _) => _EmberDialog(title: 'Trailer service', children: [
          if (!done) ...[
            Row(children: [
              SizedBox(width: ctx.px(34), height: ctx.px(34), child: const CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(width: ctx.px(20)),
              Expanded(child: Text(a.trailerSetupStep ?? 'Starting…', style: body(ctx.px(24), color: C.muted))),
            ]),
          ] else if (error == null) ...[
            Row(children: [
              Icon(Icons.check, color: C.good, size: ctx.px(34)),
              SizedBox(width: ctx.px(16)),
              Expanded(
                child: Text('Trailers now play inside Ember.', style: body(ctx.px(25), weight: FontWeight.w700)),
              ),
            ]),
          ] else
            Text(error!, style: body(ctx.px(22), color: C.bad, height: 1.4)),
          if (done) ...[
            SizedBox(height: ctx.px(28)),
            EmberButton(label: 'Done', kind: BtnKind.accent, autofocus: true, onTap: () => Navigator.pop(ctx)),
          ],
        ]),
      );
    }),
  );
  refresh = null;
}

class _EmberDialog extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _EmberDialog({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: C.surface,
        insetPadding: EdgeInsets.all(context.px(60)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(context.px(24))),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.px(820), maxHeight: context.px(960)),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.px(48)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: display(context.px(46))),
              SizedBox(height: context.px(26)),
              ...children,
            ]),
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});
  @override
  Widget build(BuildContext context) => Container(
        margin: EdgeInsets.only(bottom: context.px(14)),
        padding: EdgeInsets.all(context.px(26)),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(context.px(16))),
        child: Row(children: children),
      );
}

class SettingRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool danger;
  const SettingRow({super.key, required this.label, required this.value, required this.onTap, this.danger = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(10)),
        child: Focusable(
          onTap: onTap,
          semanticLabel: label,
          builder: (context, active) => Container(
            constraints: BoxConstraints(minHeight: context.px(82)),
            padding: EdgeInsets.symmetric(horizontal: context.px(26), vertical: context.px(14)),
            decoration: BoxDecoration(color: active ? C.text : C.surface, borderRadius: BorderRadius.circular(context.px(14))),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    style: body(context.px(25),
                        weight: FontWeight.w600, color: active ? const Color(0xFF111111) : (danger ? C.bad : C.text))),
              ),
              SizedBox(width: context.px(20)),
              Flexible(
                fit: FlexFit.tight,
                child: Text(value,
                    textAlign: TextAlign.right,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: body(context.px(21), color: active ? const Color(0xFF444444) : C.faint)),
              ),
            ]),
          ),
        ),
      );
}

class ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const ToggleRow({super.key, required this.label, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.px(10)),
        child: Focusable(
          onTap: () => onChanged(!value),
          semanticLabel: label,
          builder: (context, active) => Container(
            constraints: BoxConstraints(minHeight: context.px(82)),
            padding: EdgeInsets.symmetric(horizontal: context.px(26), vertical: context.px(14)),
            decoration: BoxDecoration(color: active ? C.text : C.surface, borderRadius: BorderRadius.circular(context.px(14))),
            child: Row(children: [
              Expanded(
                child: Text(label, style: body(context.px(25), weight: FontWeight.w600, color: active ? const Color(0xFF111111) : C.text)),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: context.px(72),
                height: context.px(40),
                padding: EdgeInsets.all(context.px(4)),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                decoration: BoxDecoration(color: value ? C.accent : const Color(0xFF3A3A40), borderRadius: BorderRadius.circular(999)),
                child: Container(
                  width: context.px(32),
                  height: context.px(32),
                  decoration: BoxDecoration(color: value ? C.accentInk : C.text, shape: BoxShape.circle),
                ),
              ),
            ]),
          ),
        ),
      );
}
