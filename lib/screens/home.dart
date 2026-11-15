import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ads.dart';
import '../documents.dart';
import '../docx_page_estimate.dart';
import '../home_activity.dart';
import '../home_strings.dart';
import '../home_tips.dart';
import '../legacy_preferences.dart';
import '../localization.dart';
import 'document_viewer.dart';

const _muted = Color(0xFF716D63);
const _appBackground = Color(0xFFFFFDF6);
const _radius = 18.0;
const _preferencesKey = 'document-history';
const _legacyHistoryPendingKey = 'legacy-document-history-pending';
const _systemViewerKey = 'prefer-system-viewer';
const _activityKey = 'home-reading-activity';
const _summaryAnimation = Duration(milliseconds: 1200);

class Home extends StatefulWidget {
  const Home({super.key, this.language, this.onLanguageChanged});

  final String? language;
  final ValueChanged<String?>? onLanguageChanged;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  bool get _hasDocumentAccess => Platform.isAndroid || Platform.isIOS;

  final _history = <Document>[];
  Set<String>? _savedHistoryUris;
  final _tipIndex = Random().nextInt(1 << 31);
  final _preferences = SharedPreferencesAsync();
  HomeActivity _activity = HomeActivity.decode(null);
  Future<void> _activityWrite = Future<void>.value();
  Future<void> _historyWrite = Future<void>.value();
  bool _loaded = false;
  bool _activityLoaded = false;
  bool _historyLoaded = false;
  bool _legacyHistoryPending = false;
  bool _preferSystem = false;
  bool _picking = false;
  bool _viewing = false;
  Document? _active;
  Route<void>? _viewerRoute;
  Document? _pending;

  String _t(String korean) => translate(context, korean, homeStrings);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_hasDocumentAccess) {
      documentsChannel.setMethodCallHandler(_handleIntent);
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final saved = await _preferences.getStringList(_preferencesKey);
      final preferSystem = await _preferences.getBool(_systemViewerKey);
      final activityData = await _preferences.getString(_activityKey);
      final historyWasPending =
          await _preferences.getBool(_legacyHistoryPendingKey) ?? false;
      final restoreHistory = saved == null || historyWasPending;
      LegacyPreferences? legacy;
      if (restoreHistory || preferSystem == null || activityData == null) {
        try {
          legacy = await LegacyPreferences.read(
            now: DateTime.now(),
            restoreHistory: restoreHistory,
            restoreSystem: preferSystem == null,
            restoreActivity: activityData == null,
          );
          if (legacy.historyRestoreFailed) {
            _homeMessage('이전 버전의 최근 문서를 불러올 수 없습니다.');
          }
        } on PlatformException {
          _homeMessage('이전 버전의 기록을 불러올 수 없습니다.');
        }
      }
      if (!mounted) return;
      final history = <Document>[];
      for (final entry in (saved ?? []).take(10)) {
        try {
          history.add(Document.fromMap(jsonDecode(entry) as Map));
        } catch (_) {
          continue;
        }
      }
      final migratedHistory = legacy?.history;
      _savedHistoryUris = history.map((document) => document.uri).toSet();
      if (migratedHistory != null) {
        final knownUris = history.map((document) => document.uri).toSet();
        history.addAll(
          migratedHistory.where((document) => knownUris.add(document.uri)),
        );
      }
      final prunedHistory = await _pruneMissingRecent(history);
      if (!mounted) return;
      final migratedPreference = preferSystem == null
          ? legacy?.preferSystem
          : null;
      final activity = HomeActivity.decode(activityData ?? legacy?.activity);
      setState(() {
        _history.addAll(history.take(10));
        _historyLoaded = true;
        _preferSystem = preferSystem ?? migratedPreference ?? !Platform.isIOS;
        _activity = activity;
        _activityLoaded = activityData != null || legacy != null;
        _legacyHistoryPending =
            restoreHistory && (legacy == null || legacy.historyRestoreFailed);
      });
      final clearLegacyPending = historyWasPending && !_legacyHistoryPending;
      if (migratedHistory != null || prunedHistory || clearLegacyPending) {
        await _saveHistory(clearLegacyPending: clearLegacyPending);
      }
      if (migratedPreference != null) {
        await _preferences.setBool(_systemViewerKey, migratedPreference);
      }
    } on PlatformException {
      _homeMessage('최근 문서 기록을 불러올 수 없습니다.');
    } finally {
      if (mounted) {
        _loaded = true;
        _updateActivity(_activity.recordUse);
      }
      if (mounted && _hasDocumentAccess) {
        await documentsChannel.invokeMethod<void>('ready');
      }
    }
  }

  Future<bool> _pruneMissingRecent(List<Document> history) async {
    if (!_hasDocumentAccess || history.isEmpty) return false;
    try {
      final missing = await documentsChannel.invokeListMethod<String>(
        'findMissingRecentDocuments',
        history.map((document) => document.uri).toList(),
      );
      if (missing == null || missing.isEmpty) return false;
      final size = history.length;
      history.removeWhere((document) => missing.contains(document.uri));
      return history.length != size;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _handleIntent(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'open') {
      await _open(
        Document.fromMap(call.arguments as Map),
        rememberImport: true,
        fromIntent: true,
      );
    } else if (call.method == 'openError') {
      _message(
        nativeMessage(context, call.arguments as String?, '파일을 열 수 없습니다.'),
      );
    }
  }

  void _homeMessage(String korean) {
    if (mounted) _message(_t(korean));
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _pick({bool photo = false}) async {
    if (_picking || !_loaded) return;
    if (!_hasDocumentAccess) {
      _homeMessage('Android 또는 iOS에서 문서를 열 수 있습니다.');
      return;
    }
    setState(() => _picking = true);
    try {
      final data = await documentsChannel.invokeMapMethod<Object?, Object?>(
        photo ? 'pickPhoto' : 'pick',
      );
      if (data != null && mounted) {
        await _open(Document.fromMap(data), rememberImport: true);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        _message(nativeMessage(context, error.message, '파일을 열 수 없습니다.'));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _open(
    Document document, {
    bool rememberImport = false,
    bool fromIntent = false,
  }) async {
    if (_viewing) {
      final previous = _pending;
      _pending = document;
      if (rememberImport) unawaited(_rememberImport(document));
      if (previous != null) unawaited(_forgetIfUnused(previous));
      final route = _viewerRoute;
      if (fromIntent && route != null && route.isActive) {
        final navigator = Navigator.of(context);
        navigator.popUntil((candidate) => candidate == route);
        navigator.removeRoute(route);
      }
      return;
    }
    _viewing = true;
    _active = document;
    String? convertedPdf;
    try {
      if (rememberImport) await _rememberImport(document);
      if (!mounted || _pending != null) return;
      if (_preferSystem &&
          !document.isHwp &&
          !document.isOffice &&
          !document.isImage &&
          !const {'tsv', 'md'}.contains(document.extension)) {
        try {
          await documentsChannel.invokeMethod<void>(
            'openExternal',
            document.toMap(),
          );
          _recordOpen(pages: 0);
          return;
        } on PlatformException {
          // The bundled viewer handles files with no matching installed app.
        }
      }
      if (!mounted) return;
      if (Platform.isAndroid &&
          const {'txt', 'csv', 'tsv'}.contains(document.extension)) {
        try {
          convertedPdf = await documentsChannel.invokeMethod<String>(
            'convertLocalText',
            document.toMap(),
          );
        } on PlatformException {
          // The WebView can preview text and tables that cannot be paginated.
        }
      }
      if (!mounted || _pending != null) return;
      final pdf = convertedPdf;
      final estimatedPages = Platform.isAndroid && document.extension == 'docx'
          ? await _estimateLocalDocx(document)
          : null;
      if (!mounted || _pending != null) return;
      final route = MaterialPageRoute<void>(
        builder: (_) => DocumentViewer(
          document: document,
          convertedPdf: pdf,
          onOpened: (pages) => _recordOpen(pages: estimatedPages ?? pages),
        ),
      );
      _viewerRoute = route;
      await Navigator.of(context).push(route);
    } finally {
      _viewing = false;
      _active = null;
      _viewerRoute = null;
      if (convertedPdf != null) {
        unawaited(
          documentsChannel.invokeMethod<void>(
            'discardConvertedPdf',
            convertedPdf,
          ),
        );
      }
      unawaited(_forgetIfUnused(document));
      final next = _pending;
      _pending = null;
      if (next != null && mounted) unawaited(_open(next));
    }
  }

  Future<int?> _estimateLocalDocx(Document document) async {
    try {
      final bytes = await documentsChannel
          .invokeMethod<Uint8List>('docxEstimateBytes', document.uri)
          .timeout(const Duration(seconds: 3));
      return bytes == null ? null : await estimateDocxPages(bytes);
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  void _recordOpen({required int pages}) {
    _updateActivity((at) => _activity.recordOpen(at, pages: pages));
  }

  Future<void> _rememberImport(Document document) async {
    Document? removed;
    setState(() {
      _history.removeWhere((entry) => entry.uri == document.uri);
      _history.insert(0, document.opened(DateTime.now()));
      if (_history.length > 10) removed = _history.removeLast();
    });
    await _saveHistory();
    final stale = removed;
    if (stale != null) await _forgetIfUnused(stale);
  }

  void _updateActivity(void Function(DateTime) update) {
    if (!mounted || !_loaded) return;
    setState(() => update(DateTime.now()));
    if (!_activityLoaded) return;
    final snapshot = _activity.encode();
    _activityWrite = _activityWrite.then((_) async {
      try {
        await _preferences.setString(_activityKey, snapshot);
      } on PlatformException {
        _homeMessage('열람 기록을 저장할 수 없습니다.');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateActivity(_activity.recordUse);
    }
  }

  Future<void> _remove(Document document) async {
    setState(() => _history.remove(document));
    await _saveHistory();
    await _forgetIfUnused(document);
  }

  Future<void> _forgetIfUnused(Document document) async {
    if (document.uri == _active?.uri ||
        document.uri == _pending?.uri ||
        _savedHistoryUris?.contains(document.uri) != false ||
        _history.any((entry) => entry.uri == document.uri)) {
      return;
    }
    await documentsChannel.invokeMethod<void>('forget', document.toMap());
  }

  Future<void> _saveHistory({bool clearLegacyPending = false}) {
    // An unread history would be overwritten by the in-memory list.
    if (!_historyLoaded) return _historyWrite;
    final uris = _history.map((document) => document.uri).toSet();
    final snapshot = _history
        .map((entry) => jsonEncode(entry.toMap()))
        .toList();
    final legacyHistoryPending = _legacyHistoryPending;
    return _historyWrite = _historyWrite.then((_) async {
      try {
        if (legacyHistoryPending) {
          await _preferences.setBool(_legacyHistoryPendingKey, true);
        }
        await _preferences.setStringList(_preferencesKey, snapshot);
        _savedHistoryUris = uris;
        if (clearLegacyPending) {
          await _preferences.remove(_legacyHistoryPendingKey);
        }
      } on PlatformException {
        _homeMessage('최근 문서 기록을 저장할 수 없습니다.');
      }
    });
  }

  void _settings() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          String t(String korean) => translate(context, korean, homeStrings);

          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          t('설정'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: t('닫기'),
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  if (widget.onLanguageChanged != null)
                    DropdownButtonFormField<String>(
                      initialValue: widget.language ?? '',
                      isExpanded: true,
                      decoration: InputDecoration(labelText: t('언어')),
                      items: [
                        DropdownMenuItem(value: '', child: Text(t('시스템 기본값'))),
                        for (final entry in supportedLanguages.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          widget.onLanguageChanged!(
                            value.isEmpty ? null : value,
                          );
                        }
                      },
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('시스템 뷰어 우선 사용')),
                    subtitle: Text(t('PDF와 텍스트 파일을 가능한 경우 시스템 앱으로 열기')),
                    value: _preferSystem,
                    onChanged: (value) {
                      setSheetState(() => _preferSystem = value ?? false);
                      unawaited(
                        _preferences
                            .setBool(_systemViewerKey, _preferSystem)
                            .catchError(
                              (_) => _homeMessage('설정을 저장할 수 없습니다.'),
                              test: (error) => error is PlatformException,
                            ),
                      );
                    },
                  ),
                  const AdPrivacyOptions(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_hasDocumentAccess) documentsChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const sectionTitle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: Color(0xFF5B5851),
    );
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: _appBackground,
      appBar: AppBar(
        title: Text(
          _t('홈'),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF3D3A35),
          ),
        ),
        titleSpacing: 32,
        toolbarHeight: 52,
        actions: [
          IconButton(
            tooltip: _t('설정'),
            onPressed: _loaded ? _settings : null,
            icon: const Icon(Icons.settings, size: 22, color: _muted),
          ),
          const SizedBox(width: 20),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 24),
          physics: const BouncingScrollPhysics(),
          children: [
            Text(_t('요약'), style: sectionTitle),
            const SizedBox(height: 8),
            _HomeSummary(
              activity: _activity,
              now: now,
              tip: homeTip(languageOf(context), _tipIndex),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_t('문서'), style: sectionTitle),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _t('HWP · HWPX 오프라인 열람'),
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _HomeCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const _Illustration('document_history'),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _t('최근 문서 (최대 10개)'),
                            style: sectionTitle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_history.isEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 120),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.insert_drive_file_outlined,
                                size: 32,
                                color: Color(0xFFBDBDBD),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _t('최근에 연 문서가 없어요'),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _t('파일을 열면 여기에 표시돼요'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: _muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        height: MediaQuery.textScalerOf(context).scale(146),
                        child: ListView.separated(
                          primary: false,
                          physics: const ClampingScrollPhysics(),
                          padding: EdgeInsets.zero,
                          itemCount: _history.length,
                          itemBuilder: (_, index) => _recent(_history[index]),
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, thickness: 0.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            _HomeCard(
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_radius),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                horizontalTitleGap: 8,
                minTileHeight: 68,
                leading: const _Illustration('open_file'),
                title: Text(_t('파일 열기'), style: sectionTitle),
                subtitle: Text(
                  'HWP · PDF · Office · CSV · TXT · ${_t('이미지')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: _muted,
                ),
                onTap: _picking || !_loaded ? null : _pick,
              ),
            ),
            if (Platform.isIOS) ...[
              const SizedBox(height: 10),
              _HomeCard(
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(_radius),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  horizontalTitleGap: 8,
                  minTileHeight: 56,
                  leading: const Icon(Icons.photo_outlined, color: _muted),
                  title: Text(_t('사진 열기'), style: sectionTitle),
                  trailing: const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: _muted,
                  ),
                  onTap: _picking || !_loaded ? null : () => _pick(photo: true),
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const SafeArea(top: false, child: AdBanner()),
    );
  }

  String _elapsed(DateTime date) {
    final seconds = DateTime.now().difference(date).inMilliseconds / 1000;
    final minutes = seconds / 60;
    final hours = minutes / 60;
    final days = hours / 24;
    final (key, value) = switch (seconds) {
      < 45 => ('방금 전', null),
      < 90 => ('약 1분 전', null),
      _ when minutes < 45 => ('{n}분 전', minutes.round()),
      _ when minutes < 90 => ('약 1시간 전', null),
      _ when hours < 24 => ('{n}시간 전', hours.round()),
      _ when hours < 48 => ('약 1일 전', null),
      _ when days < 30 => ('{n}일 전', days.round()),
      _ when days < 60 => ('약 1달 전', null),
      _ when days < 365 => ('{n}달 전', (days / 30).round()),
      _ when days < 730 => ('약 1년 전', null),
      _ => ('{n}년 전', (days / 365).round()),
    };
    final text = _t(key);
    return value == null ? text : text.replaceAll('{n}', '$value');
  }

  Widget _recent(Document document) {
    final (background, ink) = switch (document.extension) {
      'pdf' => (const Color(0xFFF9ECEB), const Color(0xFFB83B33)),
      'hwp' || 'hwpx' => (const Color(0xFFEAF3FB), const Color(0xFF2867B7)),
      'doc' || 'docx' => (const Color(0xFFEBF2EB), const Color(0xFF3D7533)),
      _ => (const Color(0xFFF3F3F3), const Color(0xFF6F6F6F)),
    };
    return Row(
      children: [
        Expanded(
          child: ListTile(
            dense: true,
            minTileHeight: 48,
            horizontalTitleGap: 10,
            minLeadingWidth: 44,
            contentPadding: EdgeInsets.zero,
            leading: Container(
              constraints: const BoxConstraints(minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                document.extension.toUpperCase(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),
            title: Text(
              document.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF555555),
              ),
            ),
            trailing: document.openedAt == null
                ? null
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 85),
                    child: Text(
                      _elapsed(document.openedAt!),
                      maxLines: 2,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6F6F6F),
                      ),
                    ),
                  ),
            onTap: () => _open(document),
          ),
        ),
        Semantics(
          button: true,
          label: '${_t('최근 문서 목록에서 제거')}\n${document.name}',
          onTap: () => unawaited(_remove(document)),
          excludeSemantics: true,
          child: IconButton(
            tooltip: _t('최근 문서 목록에서 제거'),
            onPressed: () => unawaited(_remove(document)),
            icon: const Icon(Icons.close, size: 16, color: _muted),
          ),
        ),
      ],
    );
  }
}

class _Illustration extends StatelessWidget {
  const _Illustration(this.name, {this.size = 22});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/$name.webp',
    width: size,
    height: size,
    excludeFromSemantics: true,
  );
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 7,
    shadowColor: const Color(0x22000000),
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _HomeSummary extends StatelessWidget {
  const _HomeSummary({
    required this.activity,
    required this.now,
    required this.tip,
  });

  final HomeActivity activity;
  final DateTime now;
  final String tip;

  @override
  Widget build(BuildContext context) {
    String t(String korean) => translate(context, korean, homeStrings);
    final formatNumber = MaterialLocalizations.of(context).formatDecimal;

    return _HomeCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Illustration('usage', size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(
                      begin: 0,
                      end: activity.weeklyOpens(now).toDouble(),
                    ),
                    duration: _summaryAnimation,
                    curve: Curves.easeOutCubic,
                    builder: (context, opens, _) {
                      final progress = min(opens / 100, 1.0);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(
                                t('주간 열람'),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF616161),
                                ),
                              ),
                              Text(
                                '${formatNumber(opens.toInt())} / ∞',
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 7),
                          LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            borderRadius: BorderRadius.circular(8),
                            trackGap: 0,
                            stopIndicatorRadius: 0,
                            backgroundColor: const Color(0xFFEEEEEE),
                            color: switch (progress) {
                              >= 0.9 => const Color(0xFFE53935),
                              >= 0.75 => const Color(0xFFFFA726),
                              _ => const Color(0xFF67AD5B),
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _Stat(
                    icon: 'calendar_bun',
                    title: t('연속 사용'),
                    value: activity.streak(now),
                    formatValue: (number, capped) => t(
                      !capped && number == 1 ? '1일' : '{n}일',
                    ).replaceAll('{n}', capped ? '999+' : '$number'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Stat(
                    icon: 'document_open',
                    title: t('이번 주 페이지'),
                    value: activity.weeklyPages(now),
                    formatValue: (number, capped) => t(
                      '{n}p',
                    ).replaceAll('{n}', capped ? '999+' : '$number'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _SummaryTile(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Illustration('light', size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tip,
                      style: const TextStyle(fontSize: 13, color: _muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.title,
    required this.value,
    required this.formatValue,
  });

  final String icon;
  final String title;
  final int value;
  final String Function(int value, bool capped) formatValue;

  @override
  Widget build(BuildContext context) => _SummaryTile(
    child: Row(
      children: [
        _Illustration(icon, size: 24),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  color: Color(0xFF6F6F6F),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: value.toDouble()),
                duration: _summaryAnimation,
                curve: Curves.easeOutCubic,
                builder: (context, animatedValue, _) => Text(
                  formatValue(animatedValue.toInt(), animatedValue >= 1000),
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFFFAFAFA),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(padding: const EdgeInsets.all(12), child: child),
  );
}
