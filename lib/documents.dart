import 'package:flutter/services.dart';

const documentsChannel = MethodChannel('kkomi/documents');

class Document {
  const Document(this.uri, this.name, this.extension, {this.openedAt});

  factory Document.fromMap(Map<Object?, Object?> map) => Document(
    map['uri']! as String,
    map['name']! as String,
    map['extension']! as String,
    openedAt: DateTime.tryParse(map['openedAt'] as String? ?? ''),
  );

  final String uri;
  final String name;
  final String extension;
  final DateTime? openedAt;

  Document opened(DateTime time) =>
      Document(uri, name, extension, openedAt: time);

  bool get isHwp => extension == 'hwp' || extension == 'hwpx';

  bool get isImage => const {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'avif',
    'heic',
    'heif',
    'tif',
    'tiff',
  }.contains(extension);

  bool get isOffice =>
      const {'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'}.contains(extension);

  Map<String, String> toMap() => {
    'uri': uri,
    'name': name,
    'extension': extension,
    if (openedAt case final time?) 'openedAt': time.toIso8601String(),
  };
}
