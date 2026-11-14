let labels = {};

export function setViewerStrings(serialized) {
  if (typeof serialized === 'string') labels = JSON.parse(serialized);
  document.documentElement.lang = viewerText('language', 'ko');
  document.title = viewerText('title', '꼬미 문서 뷰어');
  document.querySelector('#viewer').setAttribute('aria-label', viewerText('document', '문서'));
}

export function viewerText(key, defaultText, page) {
  const text = typeof labels[key] === 'string' ? labels[key] : defaultText;
  return page === undefined ? text : text.replaceAll('{page}', String(page));
}
