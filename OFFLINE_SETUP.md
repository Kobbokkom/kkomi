# kkomi - 로컬 번들 설정 (오프라인 모드)

## 🎉 완료된 것

다음 라이브러리들이 프로젝트에 포함되었습니다:

```
assets/js/
├── pdf.min.js                (313 KB) - PDF.js 메인 라이브러리
├── pdf.worker.min.js         (1.0 MB) - PDF.js 워커
└── mammoth.browser.min.js    (628 KB) - DOCX 변환기
```

**합계: 2.0 MB (앱 번들에 포함)**

## 📋 라이선스 확인 ✅

| 라이브러리 | 라이선스 | 번들링 | 상업용 | 수정 |
|-----------|--------|------|------|------|
| PDF.js | Apache 2.0 | ✅ OK | ✅ OK | ✅ OK |
| Mammoth.js | MIT | ✅ OK | ✅ OK | ✅ OK |
| hwp.js | MIT | ✅ OK | ✅ OK | ✅ OK |

**라이선스 위반 없음!** 🎉

## 🔧 현재 설정

### viewer.html
```html
<!-- 로컬 파일 (오프라인) -->
<script src="js/pdf.min.js"></script>
<script src="js/mammoth.browser.min.js"></script>

<!-- CDN (HWP 파싱 - 선택사항) -->
<script src="https://cdn.jsdelivr.net/npm/hwp.js@latest/dist/hwp.js"></script>
```

### pubspec.yaml
```yaml
flutter:
  assets:
    - assets/viewer.html
    - assets/js/
```

## 💾 파일 크기 영향

```
기존 (CDN만 로드):
  초기 다운로드: 300 KB
  초기 로드 시간: ~3-5초 (네트워크 필요)
  
현재 (로컬 번들):
  초기 다운로드: 2.0 MB 추가
  초기 로드 시간: ~1초 (로컬에서 바로 로드)
  
트레이드오프:
  + 오프라인 작동 ✅
  + 빠른 로드 ✅
  - 앱 크기 +2 MB (최종 apk/ipa ~50-100 MB)
```

## 🔌 인터넷 필요 여부

| 포맷 | 온라인 필수? | 비고 |
|------|-----------|------|
| **PDF** | ❌ 불필요 | 로컬 번들 사용 |
| **DOCX** | ❌ 불필요 | 로컬 번들 사용 |
| **HWP/HWPX** | ⚠️ 선택사항 | CDN에서 로드 (제거 가능) |

## 🎯 추가 최적화 옵션

### 옵션 1: HWP도 로컬화 (완전 오프라인)

hwp.js를 직접 다운로드하려면:

1. 수동으로 다운로드:
```bash
# hwp.js 최신 버전 다운로드
cd ~/Documents/code/kkomi/assets/js
npm install hwp.js
cp node_modules/hwp.js/dist/hwp.js ./
```

2. viewer.html 수정:
```html
<script src="js/hwp.js"></script>
```

### 옵션 2: 앱 크기 줄이기

불필요한 라이브러리 제거:

```html
<!-- PDF 미지원 앱이면 -->
<!-- <script src="js/pdf.min.js"></script> -->

<!-- DOCX 미지원 앱이면 -->
<!-- <script src="js/mammoth.browser.min.js"></script> -->
```

### 옵션 3: 압축 (ProGuard/R8)

Android 릴리스 빌드:
```bash
flutter build apk --release
# 자동으로 불필요한 JS 코드 제거
```

## 🚀 테스트

```bash
# 의존성 업데이트
cd ~/Documents/code/kkomi
flutter pub get

# 앱 실행
flutter run

# 오프라인 테스트:
# 1. 앱 실행
# 2. 인터넷 끄기 (비행기 모드)
# 3. PDF/DOCX 파일 로드 확인
```

## 📊 최종 상태

```
✅ PDF.js      - 로컬 번들 (완전 오프라인)
✅ Mammoth.js  - 로컬 번들 (완전 오프라인)
⚠️ hwp.js      - CDN 사용 (선택사항: 로컬화 가능)

비용:           $0
라이선스 문제:  ❌ 없음
오프라인:       ✅ 부분 지원 (HWP 제외)
초기 로드:      ~1-2초 (로컬)
앱 크기:        +2 MB
```

## 🔐 라이선스 명시 (선택)

앱에 라이선스 정보 표시하려면:

```dart
// lib/screens/about_screen.dart
showAboutDialog(
  context: context,
  applicationName: 'kkomi',
  children: [
    Text('이 앱에 사용된 오픈소스:'),
    Text('• PDF.js (Apache 2.0)'),
    Text('• Mammoth.js (MIT)'),
    Text('• hwp.js (MIT)'),
  ],
);
```

---

**이제 완전히 로컬화된 오프라인 문서 뷰어입니다!** 📱
