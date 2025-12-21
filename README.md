# kkomi - 무료 문서 뷰어 🆓

**HWP, DOCX, PDF를 WebView + JavaScript로 처리하는 완전 무료 Flutter 앱**

## 🎯 특징

- ✅ **완전 무료** - 서버 비용 0, 모든 라이브러리 오픈소스
- ✅ **오프라인 작동** - 인터넷 없어도 작동
- ✅ **개인정보 보안** - 파일이 로컬에만 존재
- ✅ **빠른 응답** - WebView 내 로컬 처리
- ✅ **교차 플랫폼** - iOS/Android 동시 지원

## 📋 지원 포맷

| 포맷 | 상태 | 품질 |
|------|------|------|
| **PDF** | ✅ 지원 | 우수 |
| **DOCX** | ✅ 지원 | 우수 |
| **HWPX** | ✅ 지원 | 우수 |
| **HWP** | ⚠️ 부분 지원 | 중간 |

## 🛠️ 구조

```
kkomi/
├─ lib/
│  ├─ main.dart (앱 진입점)
│  └─ screens/
│     └─ document_viewer.dart (뷰어 UI)
├─ assets/
│  └─ viewer.html (JavaScript 처리 로직)
└─ pubspec.yaml (의존성)
```

## 📦 사용 라이브러리

### Flutter
- `webview_flutter` - WebView 통합
- `file_picker` - 파일 선택

### JavaScript (CDN)
- `PDF.js` - PDF 렌더링
- `hwp.js` - HWP/HWPX 파싱
- `Mammoth.js` - DOCX 변환

**모두 무료 오픈소스!**

## 🚀 설치 & 실행

### 1단계: 의존성 설치
```bash
cd ~/Documents/code/kkomi
flutter pub get
```

### 2단계: 앱 실행

#### iOS
```bash
flutter run -d iphone
```

#### Android
```bash
flutter run -d android
```

#### 웹 (테스트용)
```bash
flutter run -d chrome
```

## 📱 사용 방법

1. 앱 실행
2. **파일 선택** 버튼 터치
3. HWP/HWPX/DOCX/PDF 파일 선택
4. WebView에서 자동으로 렌더링됨
5. 스크롤/확대로 문서 보기

## ⚙️ 개발 정보

### 파일 처리 흐름

```
사용자 선택
    ↓
flutter (file_picker)
    ↓
Base64 인코딩
    ↓
WebView 전달
    ↓
JavaScript (hwp.js/PDF.js/Mammoth.js)
    ↓
HTML/Canvas 렌더링
    ↓
사용자 보기
```

## ⚠️ 제한사항

1. **HWP 복잡도**
   - hwp.js는 완벽하지 않음
   - 복잡한 서식/표 일부 미지원
   - HWPX는 거의 완벽 지원

2. **파일 크기**
   - 50MB 이상 파일은 성능 저하
   - 메모리 사용량 증가

3. **오프라인**
   - JavaScript 라이브러리는 CDN에서 로드
   - 초기 로드 후 오프라인 가능

## 🐛 문제 해결

### PDF가 로드 안 됨
- 파일 포맷 확인
- 파일 크기 확인 (<50MB 추천)
- 콘솔 확인: `flutter run -v`

### HWP 렌더링이 이상함
- HWPX 사용 (Hancom 2010+)
- hwp.js는 모든 서식 미지원
- 복잡한 서식은 PDF로 변환 후 사용

### 메모리 부족
- 파일 크기 줄이기
- 페이지 분할 로드 구현
- 앱 재시작

---

**Made with ❤️ - 완전 무료로 만든 문서 뷰어**
