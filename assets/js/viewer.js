import { setViewerStrings, viewerText } from './viewer-strings.js';

const viewer = document.querySelector('#viewer');
const report = (event, value) => globalThis.Kkomi?.postMessage(JSON.stringify({ event, value }));
let documentView;
let matches = [];
let matchIndex = 0;
let searchRequest = 0;
let opening = false;
let passwordReply;
let printRequest = 0;

const imageTypes = new Map([
  ['jpg', 'image/jpeg'], ['jpeg', 'image/jpeg'], ['png', 'image/png'],
  ['gif', 'image/gif'], ['webp', 'image/webp'], ['bmp', 'image/bmp'],
  ['avif', 'image/avif'], ['heic', 'image/heic'], ['heif', 'image/heif'],
  ['tif', 'image/tiff'], ['tiff', 'image/tiff'],
]);
const rasterTypes = new Set(imageTypes.values());

async function openImage(response, extension) {
  const reportedType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
  const type = rasterTypes.has(reportedType) ? reportedType : imageTypes.get(extension);
  const bytes = await response.arrayBuffer();
  const source = URL.createObjectURL(new Blob([bytes], { type }));
  const image = new Image();
  image.alt = viewerText('image', '이미지');
  image.draggable = false;
  image.src = source;
  try {
    await image.decode();
  } catch {
    URL.revokeObjectURL(source);
    throw new Error('이미지를 열 수 없습니다.');
  }
  window.addEventListener('pagehide', () => URL.revokeObjectURL(source), { once: true });
  viewer.classList.add('image-viewer');
  viewer.replaceChildren(image);
  report('ready', 1);
}

globalThis.setImageFit = (fit) => {
  if (!viewer.classList.contains('image-viewer')) return;
  viewer.classList.toggle('image-original', !fit);
};

function requestPassword(incorrect = false) {
  return new Promise(resolve => {
    passwordReply = resolve;
    report('password', incorrect);
  });
}

globalThis.submitPassword = (password) => {
  const reply = passwordReply;
  passwordReply = null;
  reply?.(password);
};

globalThis.openDocument = async (extension, localizedStrings) => {
  if (opening) return;
  opening = true;
  try {
    setViewerStrings(localizedStrings);
    const response = await fetch('/document');
    if (!response.ok) {
      report('error', '파일을 읽을 수 없습니다. 다시 선택해 주세요.');
      return;
    }
    if (imageTypes.has(extension)) {
      await openImage(response, extension);
      return;
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    const onPage = (page) => report('page', page);
    if (extension === 'hwp' || extension === 'hwpx') {
      const { openHwp } = await import('./hwp-viewer.js');
      documentView = await openHwp(bytes, viewer, onPage, requestPassword);
      report('canPrint', documentView.canPrint === true);
    } else {
      const { openOther } = await import('./other-viewer.js');
      documentView = await openOther(extension, bytes, viewer, onPage, requestPassword,
        (width, height) => report('printMedia', { width, height }));
    }
    report('ready', documentView.pageCount);
    if (documentView.readOutline) {
      setTimeout(() => {
        const items = documentView.readOutline();
        if (items.length) report('outline', JSON.stringify(items));
      }, 0);
    }
  } catch (error) {
    if (error.name === 'AbortError') return;
    if (imageTypes.has(extension)) {
      report('error', '이미지를 열 수 없습니다. 손상되었거나 지원하지 않는 형식일 수 있습니다.');
    } else if (/password|encrypted|암호/i.test(String(error))) {
      report('error', '암호가 설정된 문서입니다. 암호를 해제한 뒤 열어 주세요.');
    } else {
      report('error', '문서를 읽을 수 없습니다. 손상되었거나 지원하지 않는 형식일 수 있습니다.');
    }
  }
};

globalThis.goToPage = (page) => documentView?.goToPage(page);
globalThis.prepareHwpPrint = async () => {
  const request = ++printRequest;
  try {
    if (documentView?.canPrint !== true) {
      report('printError', '이 문서는 PDF로 저장할 수 없습니다.');
      return;
    }
    const size = await documentView.preparePrint();
    if (request === printRequest) report('printReady', size);
  } catch {
    if (request === printRequest) report('printError', 'PDF를 준비할 수 없습니다.');
  }
};
globalThis.releaseHwpPrint = () => {
  ++printRequest;
  documentView?.releasePrint?.();
};
globalThis.moveToMatch = (step) => {
  if (documentView?.moveOccurrence) {
    documentView.moveOccurrence(step);
    return;
  }
  if (!matches.length) return;
  matchIndex = (matchIndex + step + matches.length) % matches.length;
  documentView?.goToPage(matches[matchIndex]);
  report('matches', { request: searchRequest, count: matches.length, current: matchIndex + 1 });
};
globalThis.findInDocument = async (query, request) => {
  searchRequest = request;
  matches = [];
  matchIndex = 0;
  try {
    const text = query.trim();
    if (documentView?.searchOccurrences) {
      await documentView.searchOccurrences(text, (count, current) => {
        if (request === searchRequest) report('matches', { request, count, current });
      });
      return;
    }
    const pages = text ? await documentView?.find(text) ?? [] : [];
    if (request !== searchRequest) return;
    matches = pages;
    if (matches.length) documentView.goToPage(matches[0]);
    report('matches', { request, count: matches.length, current: matches.length ? 1 : 0 });
  } catch {
    if (request === searchRequest) report('matches', { request, count: 0 });
  }
};

report('viewerReady');
