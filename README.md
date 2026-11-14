# 꼬미 Android

꼬미는 HWP와 HWPX를 우선 지원하는 Flutter 문서 뷰어입니다. 앱에 포함한 [rhwp](https://github.com/edwardkim/rhwp) WebAssembly를 Android WebView에서 실행합니다. 문서 바이트는 Android 파일 제공자에서 앱 내부의 WebView로 전달됩니다.

- **HWP/HWPX** · rhwp WebView로 오프라인 열람, 암호 입력, 텍스트 선택, 검색 결과 강조, 페이지 이동과 확대, PDF 저장. 배포용 HWP는 문서에 설정된 복사·인쇄 제한을 따릅니다.
- **PDF** · 암호 입력, 선택 가능한 텍스트, 하단 페이지 이동과 검색 결과 강조
- **DOC/DOCX/XLS/XLSX/PPT/PPTX** · OpenDocument Reader로 오프라인 열람, 검색, PDF 저장. Word는 화면 너비에 맞춰 문단을 재배치하고, 스프레드시트는 시트별로 일부 범위를 표시합니다.
- **TXT/CSV** · 오프라인 열람, 검색과 PDF 저장

홈에서 주간 열람, 전체 문서 페이지 수, 연속 사용, 최근 문서(최대 10개)와 상식 카드를 확인할 수 있습니다. 같은 앱으로 업데이트할 때는 기존 홈 통계, 시스템 뷰어 선호, 접근 가능한 최근 문서 기록을 이어받습니다.

## Android 빌드

Android SDK 37과 Flutter가 필요합니다.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

Android 앱의 파일 선택, 공유, 검색, 암호 및 저장 흐름은 별도 테스트에서 검증할 수 있습니다. 아래 명령은 지정한 테스트용 에뮬레이터의 꼬미 미리보기 데이터만 초기화합니다. 시스템 UI가 영어인 Google Android 이미지와 호스트의 Poppler `pdftotext`가 필요합니다.

```sh
python3 test/android_e2e.py --serial emulator-5562
python3 test/android_migration_e2e.py --serial emulator-5562
```

Office 파일은 앱에 포함된 OpenDocument Reader 엔진이 기기에서 엽니다. PDF 저장은 이 렌더링 결과를 인쇄합니다.

디버그 APK는 `com.kobbokkom.kkomi.preview`로 설치되어 Play 설치본과 함께 사용할 수 있습니다. 하단 배너에는 AdMob 테스트 광고를 사용합니다.

릴리스 빌드는 기존 꼬미의 AdMob 앱과 배너 단위를 사용합니다. 변경할 때는 Gradle 속성 `androidAdMobAppId`와 Flutter의 `--dart-define=ANDROID_ADMOB_BANNER_ID=...`를 사용합니다. Play 업로드 서명 정보는 로컬 `android/key.properties`의 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`에 설정합니다.

## iOS 빌드

iOS 18 이상에서 Files로 문서를 열 수 있습니다. HWP와 HWPX는 기기 안에서 rhwp를 실행합니다. iOS 디버그 빌드는 AdMob 테스트 ID를, 릴리스 빌드는 기존 꼬미 iOS 앱과 배너 ID를 사용합니다. 앱 ID는 `ios/Flutter/Release.xcconfig`, 배너 ID는 `IOS_ADMOB_BANNER_ID`에서 설정합니다.

서드파티 라이선스와 고지는 `assets/js/rhwp-LICENSE.txt`, `assets/js/rhwp-NOTICES.zip`, `assets/js/vendor/`, `tools/hwp-policy/THIRD_PARTY_NOTICES.txt`에 있습니다.
