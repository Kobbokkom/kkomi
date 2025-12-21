import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';

class DocumentViewer extends StatefulWidget {
  const DocumentViewer({Key? key}) : super(key: key);

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  late WebViewController _webViewController;
  String _statusMessage = '파일을 선택하세요';
  String _fileName = '';
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();

    if (Platform.isAndroid) {
      WebView.platform = SurfaceAndroidWebView();
    }
  }

  Future<void> _pickAndLoadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['hwp', 'hwpx', 'docx', 'pdf'],
    );

    if (result != null && result.files.isNotEmpty) {
      String filePath = result.files.single.path!;
      String fileName = result.files.single.name;

      setState(() {
        _isLoading = true;
        _fileName = fileName;
        _statusMessage = '$fileName 를 처리 중입니다...';
      });

      try {
        // 파일을 Base64로 인코딩
        File file = File(filePath);
        List<int> fileBytes = await file.readAsBytes();
        String base64String = base64Encode(fileBytes);

        // WebView에 메시지 전송
        await _webViewController.runJavascript('''
          window.postMessage({
            type: 'load-file',
            data: '$base64String',
            fileName: '$fileName'
          }, '*');
        ''');
      } catch (e) {
        setState(() {
          _statusMessage = '파일 로드 실패: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('kkomi - 문서 뷰어'),
        elevation: 0,
        backgroundColor: Colors.blue[600],
      ),
      body: Column(
        children: [
          // 상태 표시 바
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.blue[50],
            width: double.infinity,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_fileName.isNotEmpty)
                        Text(
                          '파일: $_fileName',
                          style: TextStyle(
                            color: Colors.blue[900],
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        _statusMessage,
                        style: TextStyle(
                          color: Colors.blue[700],
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // WebView
          Expanded(
            child: WebView(
              initialUrl: 'about:blank',
              onWebViewCreated: (controller) {
                _webViewController = controller;
                _loadHTMLAsset();
              },
              javascriptMode: JavascriptMode.unrestricted,
              javascriptChannels: {
                JavascriptChannel(
                  name: 'flutter_inappwebview',
                  onMessageReceived: (JavascriptMessage message) {
                    final msg = message.message;
                    print('JavaScript 메시지: $msg');

                    if (msg.startsWith('onSuccess:')) {
                      setState(() {
                        _statusMessage = msg.replaceFirst('onSuccess:', '').trim();
                        _isLoading = false;
                      });
                    } else if (msg.startsWith('onError:')) {
                      setState(() {
                        _statusMessage = '오류: ${msg.replaceFirst('onError:', '').trim()}';
                        _isLoading = false;
                      });
                    }
                  },
                ),
              },
            ),
          ),

          // 로딩 인디케이터
          if (_isLoading)
            Container(
              padding: const EdgeInsets.all(16),
              child: const Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text(
                    '파일 처리 중...',
                    style: TextStyle(fontSize: 14, color: Colors.blue),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isLoading ? null : _pickAndLoadFile,
        backgroundColor: Colors.blue[600],
        child: const Icon(Icons.folder_open),
        tooltip: '파일 선택',
      ),
    );
  }

  Future<void> _loadHTMLAsset() async {
    try {
      String htmlContent =
          await DefaultAssetBundle.of(context).loadString('assets/viewer.html');

      await _webViewController.loadUrl(
        Uri.dataFromString(
          htmlContent,
          mimeType: 'text/html',
          encoding: Encoding.getByName('utf-8'),
        ).toString(),
      );

      setState(() {
        _statusMessage = '준비 완료. 파일을 선택하세요.';
      });
    } catch (e) {
      setState(() {
        _statusMessage = '뷰어 로드 실패: ${e.toString()}';
      });
    }
  }
}
