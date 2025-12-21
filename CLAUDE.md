# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**kkomi** is a free, open-source document viewer for Flutter that supports HWP, HWPX, DOCX, and PDF formats. The key architectural decision is using WebView + JavaScript for document processing instead of native SDKs, which eliminates licensing costs while maintaining offline capability.

### Core Philosophy
- **Zero-cost**: No server, no licenses, all open-source
- **Offline-first**: Local JavaScript bundles (PDF.js, Mammoth.js) for offline rendering
- **Cross-platform**: Single Flutter codebase for iOS/Android

## Architecture

```
Flutter App (Dart)
└── DocumentViewer Screen
    └── WebView (HTML/JavaScript)
        ├── PDF.js (local bundle)
        ├── Mammoth.js (local bundle)
        └── hwp.js (CDN - optional)
```

### File Processing Flow
1. User selects file via `file_picker` plugin
2. File converted to Base64 (Dart)
3. Sent to WebView via `runJavascript()` message
4. JavaScript parses file (PDF.js/Mammoth.js/hwp.js)
5. Renders as HTML/Canvas in WebView
6. User views result

### Key Design Decisions

**WebView for document rendering:**
- Eliminates native SDK costs (Polaris Office API ~$100+/month)
- Leverages battle-tested JS libraries (PDF.js, Mammoth.js)
- Single codebase handles all platforms
- HWP support via MIT-licensed hwp.js (vs proprietary alternatives)

**Local JavaScript bundles:**
- `assets/js/pdf.min.js` (313 KB) - PDF.js main library
- `assets/js/pdf.worker.min.js` (1.0 MB) - PDF rendering worker
- `assets/js/mammoth.browser.min.js` (628 KB) - DOCX parser
- Total +2 MB to app bundle
- Trade-off: faster load times (~1s vs 3-5s) + offline capability

**File format support:**
- ✅ PDF: Excellent (PDF.js - Apache 2.0)
- ✅ DOCX: Excellent (Mammoth.js - MIT)
- ✅ HWPX: Good (hwp.js - MIT, XML-based format easier to parse)
- ⚠️ HWP: Partial (hwp.js - binary format, complex, 80-90% coverage)

## Development Commands

```bash
# Get dependencies
flutter pub get

# Run app (development)
flutter run                    # Auto-detect device
flutter run -d iphone         # iOS
flutter run -d android        # Android
flutter run -d chrome         # Web (debug)

# Run with verbose output (debugging)
flutter run -v

# Format code
dart format lib/

# Static analysis
dart analyze

# Run tests
flutter test

# Build release
flutter build apk --release   # Android
flutter build ios --release   # iOS
flutter build web --release   # Web
```

## Key Files

### Dart Code
- **lib/main.dart**: App entry point, MaterialApp configuration
- **lib/screens/document_viewer.dart**: Main UI screen
  - `DocumentViewer` (StatefulWidget): Screen container
  - `_DocumentViewerState`: Handles file picker, WebView controller, status updates
  - Key method: `_pickAndLoadFile()` - encodes file to Base64 and passes to JS
  - Key method: `_loadHTMLAsset()` - loads viewer.html into WebView

### JavaScript/HTML
- **assets/viewer.html**: Document processing logic
  - Message listener: `window.addEventListener('message', ...)` receives Base64 file data
  - `loadPDF()`: Renders PDF pages as canvas elements
  - `loadDOCX()`: Converts DOCX to HTML via Mammoth.js
  - `loadHWP()`: Parses HWP/HWPX via hwp.js
  - `renderHTML()`: Generic HTML rendering helper

### Configuration
- **pubspec.yaml**: Flutter dependencies
  - `webview_flutter: ^4.0.0` - WebView integration
  - `file_picker: ^6.0.0` - File selection dialog
  - Assets: `viewer.html` + `js/` directory

### Documentation
- **README.md**: User-facing features, usage instructions
- **OFFLINE_SETUP.md**: Technical details on local JS bundling and offline support

## Important Implementation Details

### JavaScript Bridge (Dart ↔ JavaScript)

**Sending data to JavaScript:**
```dart
await _webViewController.runJavascript('''
  window.postMessage({
    type: 'load-file',
    data: '$base64String',
    fileName: '$fileName'
  }, '*');
''');
```

**Receiving messages from JavaScript:**
```dart
JavascriptChannel(
  name: 'flutter_inappwebview',
  onMessageReceived: (JavascriptMessage message) {
    // Process message from JS
  },
)
```

### File Size Considerations

- **Development**: Minimal impact (~2 MB added to app size)
- **Release builds** (Android): APK ~60-100 MB total
  - Flutter framework, Dart runtime, plugins, JS bundles
  - ProGuard/R8 automatically removes unused code
- **Release builds** (iOS): IPA ~50-80 MB total

### Performance Characteristics

- **Initial load**: ~1-2 seconds (local JS bundles)
- **PDF rendering**: ~500ms-2s for 10-page documents
- **Memory usage**: ~50-150 MB depending on file size
- **Recommended max file size**: <50 MB for smooth UX

## Adding New Features

### Supporting a new document format
1. Add JS parser library to `assets/js/`
2. Update `pubspec.yaml` to include new asset
3. Add handling in `viewer.html` message listener
4. Add Flutter file extension to `file_picker` allowedExtensions

### Optimizing for offline
- Download `hwp.js` locally to `assets/js/hwp.js`
- Update `viewer.html` to use local path instead of CDN
- Testing: Use airplane mode to verify offline functionality

### Platform-specific modifications
- Android: Edit `android/app/src/main/AndroidManifest.xml` for permissions
- iOS: Edit `ios/Runner/Info.plist` for capabilities
- WebView issues: Check `WebView.platform` setting in `initState()`

## License Information

All dependencies use permissive licenses (MIT/Apache 2.0) allowing:
- ✅ Commercial distribution
- ✅ Bundling in closed-source apps
- ✅ Modifications
- ⚠️ Attribution recommended (see OFFLINE_SETUP.md for UI example)

## Common Issues & Solutions

**WebView not loading HTML:**
- Ensure `viewer.html` exists in `assets/`
- Check `pubspec.yaml` asset declarations
- Verify platform-specific WebView permissions

**HWP rendering has formatting issues:**
- hwp.js doesn't support all HWP features (80-90% coverage)
- Recommend HWPX format (Hancom 2010+, XML-based)
- Complex documents: suggest converting to PDF first

**PDF rendering slow for large files:**
- PDF.js renders entire document into canvas (memory-intensive)
- Implement page-by-page loading for files >50 MB
- Consider client-side pagination

**App size too large:**
- Remove unused document format JS libraries from `assets/js/`
- Use `flutter build --split-per-abi` for Android
- Investigate ProGuard/R8 configuration for Android

## Testing

```bash
# Test locally on device with sample files
flutter run

# Test offline (airplane mode)
# - Select file, load successfully
# - Disable WiFi/cellular
# - Navigate document - should work for PDF/DOCX

# Test HWP with different formats
# - HWPX (works well)
# - HWP (may have formatting issues, expected)
```

## Future Considerations

**High priority:**
- Implement page-by-page loading for large PDFs
- Add caching layer for converted documents
- Support multi-tab viewing

**Low priority:**
- Dark mode support
- Bookmarking/highlighting
- Document search functionality
- Performance profiling on real devices

**Architecture changes to avoid:**
- Moving away from WebView (loses offline capability, adds licensing)
- Native SDK adoption without cost justification
- Backend processing (adds operational complexity)
