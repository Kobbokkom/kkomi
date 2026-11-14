import 'package:flutter/widgets.dart';

const supportedLanguages = <String, String>{
  'ko': '한국어',
  'en': 'English',
  'ja': '日本語',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁體中文',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'pt-BR': 'Português (Brasil)',
  'id': 'Bahasa Indonesia',
};

const supportedLocales = <Locale>[
  Locale('ko'),
  Locale('en'),
  Locale('ja'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  Locale('es'),
  Locale('fr'),
  Locale('de'),
  Locale('pt', 'BR'),
  Locale('id'),
];

final _languageIndexes = {
  for (final (index, code) in supportedLanguages.keys.indexed) code: index,
};

String languageOf(BuildContext context) =>
    Localizations.localeOf(context).toLanguageTag();

Locale resolveLocale(List<Locale>? preferences, Iterable<Locale> supported) {
  final resolved = preferences?.map((preferred) {
    if (preferred.languageCode != 'zh' || preferred.scriptCode != null) {
      return preferred;
    }
    final traditional = const {
      'HK',
      'MO',
      'TW',
    }.contains(preferred.countryCode);
    return Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: traditional ? 'Hant' : 'Hans',
      countryCode: preferred.countryCode,
    );
  });
  return basicLocaleListResolution(resolved?.toList(), supported);
}

String translate(
  BuildContext context,
  String korean,
  Map<String, List<String>> strings,
) {
  final index = _languageIndexes[languageOf(context)] ?? 0;
  return index == 0 ? korean : strings[korean]?[index - 1] ?? korean;
}

String nativeMessage(BuildContext context, String? message, String fallback) {
  final key = _nativeStrings.containsKey(message) ? message! : fallback;
  if (languageOf(context) == 'ko') return message ?? fallback;
  return translate(context, key, _nativeStrings);
}

const _nativeStrings = <String, List<String>>{
  '파일을 열 수 없습니다.': [
    'Couldn’t open the file.',
    'ファイルを開けません。',
    '无法打开文件。',
    '無法開啟檔案。',
    'No se pudo abrir el archivo.',
    'Impossible d’ouvrir le fichier.',
    'Die Datei konnte nicht geöffnet werden.',
    'Não foi possível abrir o arquivo.',
    'File tidak dapat dibuka.',
  ],
  '파일 선택기를 열 수 없습니다.': [
    'Couldn’t open the file picker.',
    'ファイル選択画面を開けません。',
    '无法打开文件选择器。',
    '無法開啟檔案選擇器。',
    'No se pudo abrir el selector de archivos.',
    'Impossible d’ouvrir le sélecteur de fichiers.',
    'Die Dateiauswahl konnte nicht geöffnet werden.',
    'Não foi possível abrir o seletor de arquivos.',
    'Pemilih file tidak dapat dibuka.',
  ],
  '사진 선택기를 열 수 없습니다.': [
    'Couldn’t open the photo picker.',
    '写真選択画面を開けません。',
    '无法打开照片选择器。',
    '無法開啟照片選擇器。',
    'No se pudo abrir el selector de fotos.',
    'Impossible d’ouvrir le sélecteur de photos.',
    'Die Fotoauswahl konnte nicht geöffnet werden.',
    'Não foi possível abrir o seletor de fotos.',
    'Pemilih foto tidak dapat dibuka.',
  ],
  '이 파일 위치를 열 수 없습니다.': [
    'This file location is unavailable.',
    'このファイルの場所にアクセスできません。',
    '无法访问此文件位置。',
    '無法存取此檔案位置。',
    'Esta ubicación no está disponible.',
    'Cet emplacement est inaccessible.',
    'Dieser Dateispeicherort ist nicht verfügbar.',
    'Este local não está disponível.',
    'Lokasi file ini tidak tersedia.',
  ],
  '지원하지 않는 파일 형식입니다.': [
    'This file format isn’t supported.',
    'このファイル形式には対応していません。',
    '不支持此文件格式。',
    '不支援此檔案格式。',
    'Este formato de archivo no es compatible.',
    'Ce format de fichier n’est pas pris en charge.',
    'Dieses Dateiformat wird nicht unterstützt.',
    'Este formato de arquivo não é compatível.',
    'Format file ini tidak didukung.',
  ],
  '64MB 이하의 문서를 열 수 있습니다.': [
    'Files must be 64 MB or smaller.',
    '64 MB 以下のファイルを開けます。',
    '只能打开不超过 64 MB 的文件。',
    '只能開啟不超過 64 MB 的檔案。',
    'El archivo no debe superar los 64 MB.',
    'Le fichier ne doit pas dépasser 64 Mo.',
    'Die Datei darf höchstens 64 MB groß sein.',
    'O arquivo deve ter até 64 MB.',
    'Ukuran file maksimal 64 MB.',
  ],
  '파일을 읽을 수 없습니다.': [
    'Couldn’t read the file.',
    'ファイルを読み込めません。',
    '无法读取文件。',
    '無法讀取檔案。',
    'No se pudo leer el archivo.',
    'Impossible de lire le fichier.',
    'Die Datei konnte nicht gelesen werden.',
    'Não foi possível ler o arquivo.',
    'File tidak dapat dibaca.',
  ],
  '문서를 공유할 수 없습니다.': [
    'Couldn’t share the document.',
    '文書を共有できません。',
    '无法分享文档。',
    '無法分享文件。',
    'No se pudo compartir el documento.',
    'Impossible de partager le document.',
    'Das Dokument konnte nicht geteilt werden.',
    'Não foi possível compartilhar o documento.',
    'Dokumen tidak dapat dibagikan.',
  ],
  'PDF를 저장할 수 없습니다.': [
    'Couldn’t save the PDF.',
    'PDFを保存できません。',
    '无法保存 PDF。',
    '無法儲存 PDF。',
    'No se pudo guardar el PDF.',
    'Impossible d’enregistrer le PDF.',
    'Die PDF-Datei konnte nicht gespeichert werden.',
    'Não foi possível salvar o PDF.',
    'PDF tidak dapat disimpan.',
  ],
  'PDF 저장 위치를 선택할 수 없습니다.': [
    'Couldn’t select a location for the PDF.',
    'PDFの保存先を選べません。',
    '无法选择 PDF 保存位置。',
    '無法選擇 PDF 的儲存位置。',
    'No se pudo elegir dónde guardar el PDF.',
    'Impossible de choisir un emplacement pour le PDF.',
    'Der Speicherort für die PDF-Datei konnte nicht ausgewählt werden.',
    'Não foi possível escolher onde salvar o PDF.',
    'Lokasi penyimpanan PDF tidak dapat dipilih.',
  ],
  '문서 정보가 올바르지 않습니다.': [
    'The document information is invalid.',
    '文書情報が正しくありません。',
    '文档信息有误。',
    '文件資訊有誤。',
    'La información del documento es incorrecta.',
    'Les informations du document sont incorrectes.',
    'Die Dokumentinformationen sind ungültig.',
    'As informações do documento são inválidas.',
    'Informasi dokumen tidak valid.',
  ],
  '문서를 다른 앱으로 열 수 없습니다.': [
    'Couldn’t open the document in another app.',
    '別のアプリで文書を開けません。',
    '无法在其他应用中打开文档。',
    '無法在其他 App 中開啟文件。',
    'No se pudo abrir el documento en otra app.',
    'Impossible d’ouvrir le document dans une autre app.',
    'Das Dokument konnte in keiner anderen App geöffnet werden.',
    'Não foi possível abrir o documento em outro app.',
    'Dokumen tidak dapat dibuka di aplikasi lain.',
  ],
};
