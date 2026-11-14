import { viewerText } from './viewer-strings.js';
import { officeFormats } from './office-formats.js';
import { visibleOfficeSheets } from './office-sheet-visibility.js';

const tags = new Set((
  "div span x-p x-s p h1 h2 h3 h4 h5 h6 table thead tbody tfoot tr th td col colgroup " +
  "img a br wbr b i u s strong em sub sup ul ol li hr section article blockquote pre code " +
  "svg g defs path rect circle ellipse line polyline polygon text tspan linearGradient radialGradient stop clipPath"
).split(" "));
const attributes = new Set((
  "class style id dir colspan rowspan cellpadding cellspacing border width height alt viewBox preserveAspectRatio " +
  "d x y x1 y1 x2 y2 cx cy r rx ry transform points fill fill-opacity stroke stroke-width stroke-opacity " +
  "stroke-dasharray stroke-linecap stroke-linejoin opacity offset stop-color stop-opacity clip-path"
).split(" "));
const officeStyle = `
  :host { display:block; min-width:0; contain:layout paint; font:initial; }
  :host(.office-sheet) { overflow-x:auto; }
  .odr-text-flow { overflow-wrap:anywhere; }
  .odr-page-outer { margin:0 auto; zoom:var(--office-screen-scale,1); }
  .odr-sheet { margin:0; }
  .office-name { margin:0 0 8px; font:600 15px/1.5 system-ui,sans-serif; }
  .office-cut { margin:10px 0 0; font:13px/1.5 system-ui,sans-serif; color:#625f56; }
  :host(.office-pptx) { padding:0; }
  :host(.office-pptx) img { display:block; width:100%; height:auto; aspect-ratio:var(--slide-ratio); object-fit:contain; }
  @media screen {
    ::highlight(docx-matches) { background-color:#ffd50070; }
    ::highlight(docx-current-match) { background-color:#ffa000b0; }
  }
  @media print {
    :host { contain:none; overflow:visible; print-color-adjust:exact; }
    :host(.office-doc-page), :host(.office-slide), :host(.office-sheet) { break-after:page; }
    :host(:last-child) { break-after:auto; }
    .odr-page-outer { margin:0; box-shadow:none; break-after:auto; zoom:var(--office-print-scale,1); }
    :host(.office-slide) .office-content { overflow:hidden; height:calc(100vh - 1px); }
    :host(.office-slide) .odr-page-outer { margin:0 auto; }
    :host(.office-pptx) { break-inside:avoid; }
    :host(.office-pptx) .office-content {
      display:grid; place-items:center; width:var(--office-pptx-print-width); height:var(--office-pptx-print-height);
    }
    :host(.office-pptx) img { width:var(--office-pptx-image-width); height:var(--office-pptx-image-height); }
    .office-name { display:none; }
    .odr-sheet { zoom:var(--office-print-scale,1); }
    .odr-gridlines-soft { --odr-sheet-line:transparent; }
    .odr-sheet-rows tr { break-inside:avoid; }
  }
`;

const sheetPrintMargin = `@page { margin: 1in 0.75in; }`;
// Android's spreadsheet print job uses portrait A4.
const sheetPrintWidth = (210 / 25.4 - 1.5) * 96;

function renderOffice(extension, bytes, requestPassword, script = './office-worker.js') {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL(script, import.meta.url), { type: "module" });
    let timeout;
    const finish = () => {
      clearTimeout(timeout);
      worker.terminate();
      window.removeEventListener("pagehide", finish);
    };
    const startTimeout = () => {
      timeout = setTimeout(() => {
        finish();
        reject(new Error("문서를 표시하는 데 시간이 너무 오래 걸려요."));
      }, 25000);
    };
    window.addEventListener("pagehide", finish, { once: true });
    worker.onmessage = async ({ data }) => {
      if (typeof data.password === "boolean") {
        clearTimeout(timeout);
        if (!requestPassword) {
          finish();
          reject(new Error("암호가 설정된 Office 문서입니다."));
          return;
        }
        try {
          const password = await requestPassword(data.password);
          startTimeout();
          worker.postMessage({ password });
        } catch (error) {
          finish();
          reject(error);
        }
        return;
      }
      finish();
      if (typeof data.html === "string" || Array.isArray(data.images)) resolve(data);
      else if (data.error === "AbortError") reject(new DOMException("Password cancelled", "AbortError"));
      else reject(new Error(data.message || "Office 문서를 읽을 수 없어요."));
    };
    worker.onerror = () => {
      finish();
      reject(new Error("Office 문서를 읽을 수 없어요."));
    };
    startTimeout();
    worker.postMessage({ extension, bytes }, [bytes.buffer]);
  });
}

function copyOfficeElement(node) {
  if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.data);
  if (node.nodeType !== Node.ELEMENT_NODE || !tags.has(node.localName)) return null;
  const svg = node.namespaceURI === "http://www.w3.org/2000/svg";
  const copy = svg
    ? document.createElementNS(node.namespaceURI, node.localName)
    : document.createElement(node.localName === "a" ? "span" : node.localName);
  for (const { name, value } of node.attributes) {
    if (attributes.has(name)) copy.setAttribute(name, value);
  }
  if (node.localName === "img") {
    const src = node.getAttribute("src") ?? "";
    if (!/^data:image\/(?:png|jpeg|gif|webp|bmp);base64,/i.test(src)) return null;
    copy.src = src;
  }
  for (const child of node.childNodes) {
    const cloned = copyOfficeElement(child);
    if (cloned) copy.append(cloned);
  }
  return copy;
}

function officePage(kind, sheet, contents, view, resize) {
  const page = document.createElement("section");
  page.className = "other-document-page office-page office-" + kind;
  const shadow = page.attachShadow({ mode: "open" });
  shadow.adoptedStyleSheets = [sheet];
  if (kind === "sheet" && view?.name) {
    const title = document.createElement("h2");
    title.className = "office-name";
    title.textContent = view.name;
    shadow.append(title);
  }
  const root = document.createElement("div");
  root.className = kind === "sheet" ? "office-content odr-gridlines-soft" : "office-content";
  for (const node of contents) {
    const cloned = copyOfficeElement(node);
    if (cloned) root.append(cloned);
  }
  shadow.append(root);
  if (view?.sheetCut) {
    page.setAttribute("data-partial-preview", "");
    const warning = document.createElement("p");
    warning.className = "office-cut";
    warning.textContent = viewerText("tablePreview", "미리보기에 표의 일부만 표시돼요.");
    shadow.append(warning);
  }
  if (kind !== "word" && !root.firstElementChild) throw new Error("표시할 페이지가 없어요.");
  resize?.observe(root);
  return page;
}

export function docxSearch(page) {
  const root = page.shadowRoot.querySelector(".office-content");
  const textBlocks = [];
  const blockSelector = "x-p,p,li,td,th,h1,h2,h3,h4,h5,h6,pre,blockquote";
  let previousBlock;
  let block;
  let matches = [];
  let current = 0;
  let report;

  function indexText() {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const isText = node.nodeType === Node.TEXT_NODE;
      if (!isText && node.localName !== "br") continue;
      const container = node.parentElement.closest(blockSelector) ?? root;
      if (container !== previousBlock) {
        previousBlock = container;
        block = { parts: [], length: 0 };
        textBlocks.push(block);
      }
      const text = isText ? node.data : " ";
      block.parts.push({ node, text, start: block.length });
      block.length += text.length;
    }
    for (const block of textBlocks) block.text = block.parts.map(part => part.text).join("");
  }

  function createRange(match) {
    const { parts, start, end } = match;
    const first = parts.find(part => start < part.start + part.text.length);
    const last = parts.find(part => end <= part.start + part.text.length);
    const range = document.createRange();
    if (first.node.nodeType === Node.TEXT_NODE) range.setStart(first.node, start - first.start);
    else range.setStartBefore(first.node);
    if (last.node.nodeType === Node.TEXT_NODE) range.setEnd(last.node, end - last.start);
    else range.setEndAfter(last.node);
    return range;
  }

  function moveOccurrence(step) {
    if (!matches.length) return;
    current = (current + step + matches.length) % matches.length;
    const range = createRange(matches[current]);
    if (CSS.highlights) {
      const selected = new Highlight(range);
      selected.priority = 1;
      CSS.highlights.set("docx-current-match", selected);
    }
    const bounds = range.getBoundingClientRect();
    const viewport = window.visualViewport;
    const top = viewport?.offsetTop ?? 0;
    const height = viewport?.height ?? innerHeight;
    if (bounds.top < top || bounds.bottom > top + height) {
      window.scrollBy({ top: bounds.top - top - height / 2, behavior: "instant" });
    }
    report(matches.length, current + 1);
  }

  return {
    searchOccurrences(query, onUpdate) {
      report = onUpdate;
      matches = [];
      current = -1;
      CSS.highlights?.delete("docx-matches");
      CSS.highlights?.delete("docx-current-match");
      const terms = query.trim().split(/\s+/);
      if (terms[0]) {
        if (!textBlocks.length) indexText();
        const escaped = terms.map(term => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
        const pattern = new RegExp(escaped.join("\\s+"), "giu");
        for (const { text, parts } of textBlocks) {
          for (const match of text.matchAll(pattern)) {
            matches.push({ parts, start: match.index, end: match.index + match[0].length });
          }
        }
      }
      if (!matches.length) {
        report(0, 0);
        return;
      }
      if (CSS.highlights) {
        const highlight = new Highlight();
        // Keep the complete match list navigable even when rendering all ranges would be expensive.
        for (const match of matches.slice(0, 1000)) highlight.add(createRange(match));
        CSS.highlights.set("docx-matches", highlight);
      }
      moveOccurrence(1);
    },
    moveOccurrence,
  };
}

function useSlidePrintMargin() {
  const style = document.createElement("style");
  style.media = "print";
  style.textContent = "@page { margin: 0; }";
  document.head.append(style);
}

async function pptxPages(extension, bytes, reportPrintSize) {
  const { images, widthMils, heightMils } = await renderOffice(extension, bytes, null, './pptx-worker.js');
  const width = widthMils * 0.096;
  const height = heightMils * 0.096;
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(officeStyle);
  const urls = [];
  const release = () => urls.forEach(url => URL.revokeObjectURL(url));
  window.addEventListener('pagehide', release, { once: true });
  const pages = [];
  try {
    const parser = new DOMParser();
    for (const svg of images) {
      const slide = parser.parseFromString(svg, 'image/svg+xml').documentElement;
      if (slide.localName !== 'svg') throw new Error('Invalid slide image');
      const text = [...slide.querySelectorAll('text:not([aria-hidden="true"])')]
        .map(node => node.textContent.trim()).filter(Boolean).join('\n');
      const page = document.createElement('section');
      page.className = 'other-document-page office-page office-slide office-pptx';
      page.style.setProperty('--slide-ratio', `${widthMils} / ${heightMils}`);
      const shadow = page.attachShadow({ mode: 'open' });
      shadow.adoptedStyleSheets = [sheet];
      const root = document.createElement('div');
      root.className = 'office-content';
      const image = document.createElement('img');
      const label = viewerText('page', '{page}쪽', pages.length + 1);
      image.alt = text ? `${label}: ${text}` : label;
      // Keep slide XML in the browser's inert image context, and expose plain text to existing search.
      const style = parser.parseFromString('<style xmlns="http://www.w3.org/2000/svg">text{font-variant-ligatures:none}</style>', 'image/svg+xml').documentElement;
      slide.prepend(style);
      const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(slide)], { type: 'image/svg+xml' }));
      urls.push(url);
      image.src = url;
      const search = document.createElement('span');
      search.hidden = true;
      search.textContent = text;
      root.append(image, search);
      shadow.append(root);
      await image.decode();
      pages.push(page);
    }
  } catch (error) {
    window.removeEventListener('pagehide', release);
    release();
    throw error;
  }
  useSlidePrintMargin();
  globalThis.fitOfficeSlides = (printWidth, printHeight) => {
    const style = document.documentElement.style;
    const pageHeight = Math.floor(printHeight) - 1;
    const scale = Math.min(1, printWidth / width, pageHeight / height);
    style.setProperty('--office-print-width', `${Math.ceil(printWidth)}px`);
    style.setProperty('--office-pptx-print-width', `${printWidth}px`);
    style.setProperty('--office-pptx-print-height', `${pageHeight}px`);
    style.setProperty('--office-pptx-image-width', `${width * scale}px`);
    style.setProperty('--office-pptx-image-height', `${height * scale}px`);
  };
  globalThis.fitOfficeSlides(width, height);
  reportPrintSize?.(widthMils, heightMils);
  return pages;
}

export async function officePages(extension, bytes, requestPassword, reportPrintSize) {
  const { type, kind } = officeFormats.get(extension);
  // Encrypted OOXML opens through ODR's existing password flow in its compound-file container.
  if (type === 'pptx' && bytes[0] === 0x50 && bytes[1] === 0x4b) {
    return pptxPages(extension, bytes, reportPrintSize);
  }
  const { html, views, metadata } = await renderOffice(extension, bytes, requestPassword);
  // Parsing inside a template keeps embedded resources inert until individually allowed.
  const template = document.createElement("template");
  template.innerHTML = html;
  const markup = template.content;
  const css = Array.from(markup.querySelectorAll("style"), style => style.textContent).join("\n");
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(css + officeStyle);
  if (kind === "word") {
    if (type === "doc") {
      const pages = markup.querySelectorAll(".odr-pages > .odr-page-outer");
      if (pages.length > 500) throw new Error("페이지가 너무 많아 문서를 표시할 수 없어요.");
      if (pages.length) return Array.from(pages, page => officePage("doc-page", sheet, [page]));
    }
    const contents = [...markup.children].filter(node => !["meta", "title", "style", "script"].includes(node.localName));
    return [officePage(kind, sheet, contents)];
  }
  if (kind === "sheet") {
    const visible = visibleOfficeSheets(type, metadata, views);
    const sheets = [...markup.querySelectorAll(".odr-sheet")];
    if (visible && (visible.length !== sheets.length ||
        sheets.some((node, index) => node.getAttribute("data-odr-sheet") !== String(index)))) {
      throw new Error("시트 표시 상태를 확인할 수 없어요.");
    }
    const pages = sheets.flatMap((node, index) => {
      if (visible && !visible[index]) return [];
      const width = parseFloat(node.style.getPropertyValue("--odr-sheet-width"));
      const gutter = parseFloat(node.style.getPropertyValue("--odr-sheet-gutter"));
      if (width > gutter && gutter >= 0) {
        node.style.setProperty("--office-print-scale", String(Math.min(1, sheetPrintWidth / (width - gutter))));
      }
      return [officePage(kind, sheet, [node], views[index])];
    });
    if (!pages.length) throw new Error("표시할 페이지가 없어요.");
    const style = document.createElement("style");
    style.media = "print";
    style.textContent = sheetPrintMargin;
    document.head.append(style);
    return pages;
  }
  const slides = markup.querySelectorAll(".odr-pages > .odr-page-outer");
  useSlidePrintMargin();
  const sizes = new Map();
  let reportedPrintSize = false;
  globalThis.fitOfficeSlides = (width, height) => {
    // WebKit may otherwise paginate a wide slide using a narrower print layout.
    document.documentElement.style.setProperty("--office-print-width", `${Math.ceil(width)}px`);
    for (const [slide, size] of sizes) {
      slide.style.setProperty("--office-print-scale", String(Math.min(1, width / size.width, height / size.height)));
    }
  };
  const resize = new ResizeObserver(entries => {
    for (const { target, contentRect } of entries) {
      const content = target.firstElementChild;
      const { width, height } = getComputedStyle(content);
      const naturalWidth = parseFloat(width);
      const naturalHeight = parseFloat(height);
      if (naturalWidth > 0 && naturalHeight > 0 && contentRect.width > 0) {
        sizes.set(content, { width: naturalWidth, height: naturalHeight });
        content.style.setProperty("--office-screen-scale", String(Math.min(1, contentRect.width / naturalWidth)));
        if (!reportedPrintSize && target === pages[0].shadowRoot.querySelector(".office-content")) {
          const width = Math.round(naturalWidth / 96 * 1000);
          const height = Math.round(naturalHeight / 96 * 1000);
          if (width >= 1000 && height >= 1000 && width <= 40000 && height <= 40000) {
            reportedPrintSize = true;
            reportPrintSize?.(width, height);
          }
        }
      }
    }
  });
  window.addEventListener("pagehide", () => resize.disconnect(), { once: true });
  const pages = Array.from(slides, (node, index) =>
    officePage(kind, sheet, [node], views[index], resize));
  if (!pages.length) throw new Error("표시할 페이지가 없어요.");
  return pages;
}
