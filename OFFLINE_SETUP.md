# 문서 오프라인 처리

Flutter의 파일 열기 화면은 Android Storage Access Framework를 사용합니다. 공유로 받은 임시 접근 권한은 다시 열 수 있도록 앱의 비공개 저장소에 복사할 수 있습니다. 최근 문서에서 삭제하면 새 복사본이나 접근 권한을 정리합니다. 이전 앱의 문서 복사본은 기존 기록 이전을 위해 보존합니다.

Android WebView는 `appassets.androidplatform.net`의 앱 번들과 현재 문서 스트림만 읽을 수 있습니다. 앱에 포함된 rhwp 0.9.0, PDF.js와 OpenDocument Reader는 실행 시 다운로드가 필요 없습니다. Google Mobile Ads의 하단 배너는 별도의 SDK에서 로드됩니다.

HWP와 HWPX는 페이지를 SVG 이미지로 표시합니다. 검색어에 일치하는 위치로 이동하고 강조 표시할 수 있습니다.

Office의 문서 배치를 유지하는 PDF 변환은 선택 사항입니다. 빌드에 LibreOffice 변환 주소를 설정하면 사용자가 개별 Office 문서마다 전송을 선택할 수 있습니다. HWP/HWPX는 항상 앱의 rhwp로 처리합니다.
