import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ads.dart';
import '../documents.dart';
import '../localization.dart';
import 'document_viewer_strings.dart';

class DocumentViewer extends StatefulWidget {
  const DocumentViewer({
    super.key,
    required this.document,
    required this.onOpened,
    this.convertedPdf,
  });

  final Document document;
  final ValueChanged<int> onOpened;
  final String? convertedPdf;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  MethodChannel? _viewer;
  Timer? _debounce;
  String? _error;
  bool _searching = false;
  int _pageCount = 0;
  int _page = 0;
  int _searchRequest = 0;
  int? _matches;
  int _currentMatch = 0;
  bool _preparingPdf = false;
  bool _hwpCanPrint = false;
  bool _imageFit = true;

  bool get _isPdf =>
      widget.document.extension == 'pdf' || widget.convertedPdf != null;
  bool get _hasPageToolbar => _isPdf || widget.document.isHwp;
  bool get _bottomSearch =>
      _hasPageToolbar || widget.document.extension == 'docx';

  String _text(String key) => translate(context, key, viewerStrings);

  String _errorText(String? message, String fallback) {
    if (viewerStrings.containsKey(message)) return _text(message!);
    return nativeMessage(context, message, _text(fallback));
  }

  Future<void> _saveConvertedPdf() async {
    try {
      await documentsChannel.invokeMethod<void>('saveConvertedPdf', {
        'uri': widget.convertedPdf,
        'name': widget.document.name,
      });
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorText(error.message, 'PDF를 저장할 수 없습니다.')),
          ),
        );
      }
    }
  }

  Future<void> _printPdf() async {
    if (_preparingPdf) return;
    setState(() => _preparingPdf = true);
    try {
      await _viewer?.invokeMethod<void>('print');
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorText(error.message, 'PDF를 저장할 수 없습니다.')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _preparingPdf = false);
    }
  }

  void _created(int id) {
    final channel = MethodChannel('kkomi/viewer/$id');
    _viewer = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'ready':
          final firstLoad = _pageCount == 0;
          setState(() => _pageCount = call.arguments as int);
          if (firstLoad && _pageCount > 0) widget.onOpened(_pageCount);
        case 'page':
          setState(() => _page = call.arguments as int);
        case 'password':
          unawaited(_promptPassword(call.arguments as bool));
        case 'canPrint':
          setState(() => _hwpCanPrint = call.arguments == true);
        case 'error':
          setState(() => _error = call.arguments as String);
        case 'matches':
          final data = call.arguments as Map;
          if (data['request'] == _searchRequest) {
            setState(() {
              _matches = data['count'] as int;
              _currentMatch = data['current'] as int? ?? 0;
            });
          }
      }
    });
    unawaited(_invoke('start'));
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _viewer?.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? '문서 뷰어를 열 수 없습니다.');
      }
    }
  }

  void _find(String query) {
    _debounce?.cancel();
    final request = ++_searchRequest;
    setState(() {
      _matches = null;
      _currentMatch = 0;
    });
    final arguments = {'query': query, 'request': request};
    if (query.isEmpty) {
      unawaited(_invoke('find', arguments));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 200),
        () => unawaited(_invoke('find', arguments)),
      );
    }
  }

  void _toggleSearch() {
    if (_searching) {
      _search.clear();
      _find('');
    }
    setState(() => _searching = !_searching);
  }

  Future<void> _promptPassword(bool incorrect) async {
    String password = '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_text('문서 암호')),
        content: TextField(
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (value) => password = value,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
          decoration: InputDecoration(
            labelText: _text('암호'),
            errorText: incorrect ? _text('암호가 올바르지 않습니다.') : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_text('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, password),
            child: Text(_text('열기')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _invoke('password', result);
    if (result == null &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  Future<void> _share() async {
    try {
      await documentsChannel.invokeMethod<void>(
        'share',
        widget.document.toMap(),
      );
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorText(error.message, '파일을 공유할 수 없습니다.'))),
        );
      }
    }
  }

  Future<void> _selectPage() async {
    final field = TextEditingController(text: '${_page + 1}');
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void submit() {
          final target = int.tryParse(field.text);
          if (target != null && target >= 1 && target <= _pageCount) {
            Navigator.pop(dialogContext, target - 1);
          }
        }

        return AlertDialog(
          title: Text(_text('페이지 이동')),
          content: TextField(
            controller: field,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofocus: true,
            decoration: InputDecoration(hintText: '1–$_pageCount'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(_text('취소')),
            ),
            FilledButton(onPressed: submit, child: Text(_text('이동'))),
          ],
        );
      },
    );
    // The dialog retains the field during its closing transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    field.dispose();
    if (value != null && mounted) await _invoke('page', value);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _viewer?.setMethodCallHandler(null);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Widget _searchField({bool outlined = false}) => TextField(
    controller: _search,
    focusNode: _searchFocus,
    autofocus: !_bottomSearch || _hasPageToolbar,
    onChanged: _find,
    onSubmitted: (_) => _moveMatch(1),
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: _text(outlined ? '검색...' : '문서 검색'),
      isDense: outlined,
      contentPadding: outlined
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
          : null,
      border: outlined
          ? const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            )
          : InputBorder.none,
    ),
  );

  void _moveMatch(int step) {
    if ((_matches ?? 0) > 0) unawaited(_invoke('match', step));
  }

  List<Widget> _searchActions() => [
    IconButton(
      onPressed: (_matches ?? 0) > 0 ? () => _moveMatch(-1) : null,
      tooltip: _text('이전 검색 결과'),
      icon: const Icon(Icons.expand_less),
    ),
    IconButton(
      onPressed: (_matches ?? 0) > 0 ? () => _moveMatch(1) : null,
      tooltip: _text('다음 검색 결과'),
      icon: const Icon(Icons.expand_more),
    ),
    IconButton(
      onPressed: _hasPageToolbar || !_bottomSearch
          ? _toggleSearch
          : () {
              _searchFocus.unfocus();
              _search.clear();
              _find('');
            },
      tooltip: _text('검색 닫기'),
      icon: const Icon(Icons.close),
    ),
  ];

  Widget _documentToolbar() {
    final count = _matches;
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        bottom: false,
        child: SizedBox(
          height: 56,
          child: _searching || !_hasPageToolbar
              ? Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(
                    children: [
                      Expanded(child: _searchField(outlined: true)),
                      if (_search.text.trim().isNotEmpty && count != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Semantics(
                            liveRegion: true,
                            label: count == 0
                                ? _text('검색 결과 없음')
                                : _text('검색 결과 {current} / {count}')
                                      .replaceAll('{current}', '$_currentMatch')
                                      .replaceAll('{count}', '$count'),
                            excludeSemantics: true,
                            child: Text(
                              count == 0 ? '0 / 0' : '$_currentMatch / $count',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ..._searchActions(),
                    ],
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: _text('이전 페이지'),
                      onPressed: _page > 0
                          ? () => unawaited(_invoke('page', _page - 1))
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F3F3),
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _selectPage,
                      child: Text('${_page + 1} / $_pageCount'),
                    ),
                    IconButton(
                      tooltip: _text('다음 페이지'),
                      onPressed: _page + 1 < _pageCount
                          ? () => unawaited(_invoke('page', _page + 1))
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: _text('검색'),
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _pageCount > 0 && _error == null;
    const viewType = 'kkomi/viewer';
    const creationParamsCodec = StandardMessageCodec();
    final creationParams = {
      ...widget.document.toMap(),
      'viewerStrings': jsonEncode({
        'language': languageOf(context),
        'title': _text('꼬미 문서 뷰어'),
        'document': _text('문서'),
        'image': _text('이미지'),
        'page': _text('{page}쪽'),
        'pageFailed': _text('{page}쪽을 표시할 수 없습니다.'),
        'pdfPageFailed': _text('이 페이지를 표시할 수 없어요.'),
        'tablePreview': _text('미리보기에 표의 일부만 표시돼요.'),
        'pdfPreparationFailed': _text('PDF를 준비할 수 없습니다.'),
        'slideSize': _text('슬라이드 크기'),
      }),
      if (widget.convertedPdf case final uri?) ...{
        'uri': uri,
        'extension': 'pdf',
      },
    };
    final directSave =
        ready &&
        (widget.convertedPdf != null ||
            (widget.document.isHwp && _hwpCanPrint));
    final canSave =
        ready &&
        !_preparingPdf &&
        (directSave ||
            widget.document.isOffice ||
            const {'txt', 'csv'}.contains(widget.document.extension));
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _isPdf ? Colors.white : null,
        centerTitle: _isPdf ? true : null,
        title: !_bottomSearch && _searching
            ? _searchField()
            : Text(
                widget.document.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        actions: [
          if (!_bottomSearch && _searching)
            ..._searchActions()
          else ...[
            if (ready && !_bottomSearch && !widget.document.isImage)
              IconButton(
                onPressed: _toggleSearch,
                tooltip: _text('검색'),
                icon: const Icon(Icons.search),
              ),
            if (directSave)
              IconButton(
                onPressed: _preparingPdf
                    ? null
                    : () => unawaited(
                        widget.convertedPdf != null
                            ? _saveConvertedPdf()
                            : _printPdf(),
                      ),
                tooltip: _text('PDF로 저장'),
                icon: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8),
                  child: Icon(Icons.vertical_align_bottom_rounded, size: 22),
                ),
              ),
            PopupMenuButton<String>(
              icon: directSave
                  ? Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Icon(Icons.adaptive.more),
                    )
                  : null,
              tooltip: _text('문서 메뉴'),
              onSelected: (action) {
                switch (action) {
                  case 'search':
                    _toggleSearch();
                  case 'page':
                    unawaited(_selectPage());
                  case 'imageFit':
                    setState(() => _imageFit = !_imageFit);
                    unawaited(_invoke('imageFit', _imageFit));
                  case 'print':
                    unawaited(
                      widget.convertedPdf != null
                          ? _saveConvertedPdf()
                          : _printPdf(),
                    );
                  case 'share':
                    unawaited(_share());
                }
              },
              itemBuilder: (_) => [
                if (ready && !widget.document.isImage && !_searching)
                  PopupMenuItem(value: 'search', child: Text(_text('검색'))),
                if (ready && _pageCount > 1)
                  PopupMenuItem(value: 'page', child: Text(_text('페이지 이동'))),
                if (ready && widget.document.isImage)
                  PopupMenuItem(
                    value: 'imageFit',
                    child: Text(_text(_imageFit ? '원본 크기' : '화면에 맞추기')),
                  ),
                if (canSave)
                  PopupMenuItem(value: 'print', child: Text(_text('PDF로 저장'))),
                PopupMenuItem(value: 'share', child: Text(_text('공유'))),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (!_bottomSearch &&
              _searching &&
              _search.text.trim().isNotEmpty &&
              _matches != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(switch (_matches) {
                0 => _text('검색 결과가 없어요'),
                _ => _text(
                  '검색 결과 {count}페이지',
                ).replaceAll('{count}', '$_matches'),
              }, style: Theme.of(context).textTheme.bodySmall),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (Platform.isIOS)
                  UiKitView(
                    viewType: viewType,
                    creationParams: creationParams,
                    creationParamsCodec: creationParamsCodec,
                    onPlatformViewCreated: _created,
                  )
                else
                  AndroidView(
                    viewType: viewType,
                    creationParams: creationParams,
                    creationParamsCodec: creationParamsCodec,
                    onPlatformViewCreated: _created,
                  ),
                if (!ready)
                  ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: Center(
                      child: _error == null
                          ? CircularProgressIndicator(
                              semanticsLabel: _text('문서 열기'),
                            )
                          : Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                _errorText(_error, '문서 뷰어를 열 수 없습니다.'),
                                textAlign: TextAlign.center,
                              ),
                            ),
                    ),
                  ),
                if (ready && !_hasPageToolbar && _pageCount > 1)
                  Positioned(
                    bottom: 8,
                    right: 12,
                    child: FilledButton.tonal(
                      onPressed: _selectPage,
                      child: Text('${_page + 1} / $_pageCount'),
                    ),
                  ),
              ],
            ),
          ),
          if (ready && _bottomSearch) _documentToolbar(),
        ],
      ),
      bottomNavigationBar:
          _bottomSearch && MediaQuery.viewInsetsOf(context).bottom > 0
          ? null
          : const SafeArea(top: false, child: AdBanner()),
    );
  }
}
