const maxSheetRows = 1000;
const maxSheetColumns = 64;
const vendor = new URL("./vendor/", import.meta.url);

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function normalize(text) {
  return text.normalize("NFKC").toLocaleLowerCase().replace(/\s+/g, " ").trim();
}

function loadScript(file, globalName) {
  if (globalThis[globalName]) return Promise.resolve(globalThis[globalName]);
  return new Promise((resolve, reject) => {
    const script = element("script");
    script.src = new URL(file, vendor).href;
    script.onload = () => resolve(globalThis[globalName]);
    script.onerror = () => reject(new Error("문서 도구를 불러올 수 없어요."));
    document.head.append(script);
  });
}

function pagination(pages, reportPage, readText = index => pages[index].textContent) {
  const visible = new Set();
  const indices = new Map(pages.map((page, index) => [page, index]));
  let frame = 0;
  let current = -1;
  let searchId = 0;
  let requestedPage = null;
  function updatePage() {
    frame = 0;
    const viewport = window.visualViewport;
    const top = viewport?.offsetTop ?? 0;
    const height = viewport?.height ?? innerHeight;
    const pageTop = window.scrollY + top;
    let next;
    if (requestedPage !== null) {
      next = requestedPage;
    } else {
      const end = document.scrollingElement.scrollHeight - height;
      if (pageTop <= 1) {
        next = 0;
      } else if (pageTop >= end - 1) {
        next = pages.length - 1;
      } else {
        let largestOverlap = 0;
        for (const page of visible) {
          const bounds = page.getBoundingClientRect();
          const overlap = Math.min(bounds.bottom, top + height) - Math.max(bounds.top, top);
          if (overlap > largestOverlap) {
            largestOverlap = overlap;
            next = indices.get(page);
          }
        }
      }
    }
    if (next !== undefined && next !== current) {
      current = next;
      reportPage(current);
    }
  }
  function schedulePage() {
    if (!frame) frame = requestAnimationFrame(updatePage);
  }
  function keepPage(index) {
    // Keyboard and layout changes can move the viewport without a page gesture.
    requestedPage = index;
    schedulePage();
  }
  const input = new AbortController();
  const inputOptions = { passive: true, signal: input.signal };
  function releasePage(event) {
    if (event.isTrusted) requestedPage = null;
  }
  window.addEventListener("touchmove", releasePage, inputOptions);
  window.addEventListener("wheel", event => {
    if (event.deltaY && !event.ctrlKey) releasePage(event);
  }, inputOptions);
  window.addEventListener("keydown", event => {
    if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].includes(event.key) &&
        !event.target?.closest?.("input, textarea, select, button, [contenteditable]")) {
      releasePage(event);
    }
  }, inputOptions);
  window.addEventListener("pointerdown", event => {
    if (event.pointerType === "mouse" && event.clientX >= document.documentElement.clientWidth) {
      releasePage(event);
    }
  }, inputOptions);
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) visible.add(entry.target);
      else visible.delete(entry.target);
    }
    schedulePage();
  });
  for (const page of pages) observer.observe(page);
  window.addEventListener("scroll", schedulePage, { capture: true, passive: true });
  window.visualViewport?.addEventListener("scroll", schedulePage, { passive: true });
  window.visualViewport?.addEventListener("resize", schedulePage, { passive: true });
  window.addEventListener("pagehide", () => {
    input.abort();
    observer.disconnect();
    cancelAnimationFrame(frame);
    window.removeEventListener("scroll", schedulePage, true);
    window.visualViewport?.removeEventListener("scroll", schedulePage);
    window.visualViewport?.removeEventListener("resize", schedulePage);
    searchId++;
  }, { once: true });

  return {
    pageCount: pages.length,
    keepPage,
    async find(query) {
      const request = ++searchId;
      const needle = normalize(query);
      if (!needle) return [];
      const matches = [];
      for (let index = 0; index < pages.length; index++) {
        const text = await readText(index);
        if (request !== searchId) return [];
        if (normalize(text).includes(needle)) matches.push(index);
      }
      return matches;
    },
    goToPage(index) {
      const target = pages[index];
      if (!target) return;
      target.scrollIntoView({ block: "start", behavior: "instant" });
      keepPage(index);
    },
  };
}

async function pdfDocument(bytes, viewer, reportPage, requestPassword) {
  const pdf = await import(new URL("pdf/pdf.min.mjs", vendor).href);
  const pdfAssets = new URL("pdf/", vendor);
  const { EventBus, FindState, PDFFindController, TextHighlighter } =
    await import(new URL("pdf_viewer.mjs", pdfAssets).href);
  pdf.GlobalWorkerOptions.workerSrc = new URL("pdf.worker.min.mjs", pdfAssets).href;
  const loading = pdf.getDocument({
    data: bytes,
    cMapUrl: new URL("cmaps/", pdfAssets).href,
    standardFontDataUrl: new URL("standard_fonts/", pdfAssets).href,
    wasmUrl: new URL("wasm/", pdfAssets).href,
    iccUrl: new URL("iccs/", pdfAssets).href,
    isEvalSupported: false,
    maxImageSize: 24 * 1024 * 1024,
    canvasMaxAreaInBytes: 16 * 1024 * 1024,
  });
  let passwordCancelled = false;
  if (requestPassword) {
    loading.onPassword = async (updatePassword, reason) => {
      const password = await requestPassword(reason === pdf.PasswordResponses.INCORRECT_PASSWORD);
      if (password === null) {
        passwordCancelled = true;
        updatePassword(new Error("Password cancelled"));
      } else {
        updatePassword(password);
      }
    };
  }
  let doc;
  try {
    doc = await loading.promise;
  } catch (error) {
    await loading.destroy();
    if (passwordCancelled) throw new DOMException("Password cancelled", "AbortError");
    throw error;
  }
  if (!doc.numPages || doc.numPages > 5000) {
    await loading.destroy();
    throw new Error("PDF 페이지 수가 지원 범위를 벗어났어요.");
  }
  const permissions = await doc.getPermissions().catch(() => null);
  const copyDisabled = permissions !== null && !permissions.has(pdf.PermissionFlag.COPY);
  function blockCopy(event) {
    event.preventDefault();
  }
  if (copyDisabled) document.addEventListener("copy", blockCopy, true);

  const firstPage = await doc.getPage(1);
  const firstView = firstPage.getViewport({ scale: 1 });
  const pages = Array.from({ length: doc.numPages }, (_, index) => {
    const page = element("section", "other-pdf-page");
    page.setAttribute("aria-label", `${index + 1} 페이지`);
    page.style.aspectRatio = `${firstView.width} / ${firstView.height}`;
    return page;
  });
  viewer.replaceChildren(...pages);

  let currentPage = 1;
  const navigation = pagination(pages, index => {
    currentPage = index + 1;
    reportPage(index);
  });
  const eventBus = new EventBus();
  class FindController extends PDFFindController {
    scrollMatchIntoView({ element, pageIndex, matchIndex }) {
      if (!element) return;
      super.scrollMatchIntoView({
        pageIndex,
        matchIndex,
        element: {
          scrollIntoView(options) {
            // PDF.js positions the highlight after navigating to its page.
            element.scrollIntoView({ ...options, behavior: "instant" });
            navigation.keepPage(pageIndex);
          },
        },
      });
    }
  }
  let startAtFirstPage = false;
  const findController = new FindController({
    eventBus,
    linkService: {
      get page() {
        if (!startAtFirstPage) return currentPage;
        // Start a new query in document order without moving the viewport.
        startAtFirstPage = false;
        return 1;
      },
      set page(number) {
        if (number !== currentPage) navigation.goToPage(number - 1);
      },
      pagesCount: doc.numPages,
    },
    delay: 0,
  });
  findController.setDocument(doc);

  let searchQuery = "";
  let reportMatches;
  function updateMatches({ matchesCount, rawQuery }) {
    if (searchQuery && (rawQuery ?? findController.state?.query) === searchQuery) {
      reportMatches?.(matchesCount.total, matchesCount.current);
    }
  }
  eventBus.on("updatefindmatchescount", updateMatches);
  eventBus.on("updatefindcontrolstate", event => {
    if (event.state !== FindState.PENDING) updateMatches(event);
  });
  function find(type, findPrevious = false) {
    eventBus.dispatch("find", {
      type,
      query: searchQuery,
      caseSensitive: false,
      entireWord: false,
      matchDiacritics: false,
      highlightAll: true,
      findPrevious,
    });
  }

  const wanted = new Set();
  const nearby = new Set();
  const renders = new Map();
  const layers = new Map();
  const resize = new ResizeObserver(() => {
    for (const layer of layers.values()) layer.resize();
  });
  resize.observe(viewer);

  async function renderText(page, base, target, index, state) {
    const div = element("div", "pdf-text-layer");
    if (copyDisabled) div.classList.add("pdf-copy-disabled");
    const { pageWidth, pageHeight } = base.rawDims;
    const resize = () => {
      div.style.setProperty("--total-scale-factor", target.clientWidth / base.width * base.userUnit);
    };
    const textLayer = new pdf.TextLayer({
      container: div,
      textContentSource: page.streamTextContent({ disableNormalization: true }),
      viewport: base,
    });
    div.style.width = `calc(var(--total-scale-factor) * ${pageWidth}px)`;
    div.style.height = `calc(var(--total-scale-factor) * ${pageHeight}px)`;
    resize();
    state.textLayer = textLayer;
    try {
      await textLayer.render();
      if (!wanted.has(index)) return;
      const highlighter = new TextHighlighter({ findController, eventBus, pageIndex: index });
      highlighter.setTextMapping(textLayer.textDivs, textLayer.textContentItemsStr);
      target.append(div);
      layers.set(index, { highlighter, resize });
      highlighter.enable();
    } catch (error) {
      if (error.name !== "AbortException") console.warn("PDF text layer unavailable", error);
    }
  }

  async function render(index) {
    if (renders.has(index)) return;
    const state = {};
    renders.set(index, state);
    const target = pages[index];
    try {
      const page = await doc.getPage(index + 1);
      if (!wanted.has(index)) return;
      const base = page.getViewport({ scale: 1 });
      if (!(base.width > 0 && base.height > 0)) throw new Error("Invalid page size");
      target.style.aspectRatio = `${base.width} / ${base.height}`;
      const scale = Math.min(2.5 * Math.max(1, target.clientWidth) / base.width, 2400 / Math.max(base.width, base.height));
      const viewport = page.getViewport({ scale });
      const canvas = element("canvas");
      canvas.width = Math.max(1, Math.ceil(viewport.width));
      canvas.height = Math.max(1, Math.ceil(viewport.height));
      canvas.setAttribute("aria-hidden", "true");
      state.task = page.render({ canvas, viewport });
      await state.task.promise;
      if (wanted.has(index)) {
        target.replaceChildren(canvas);
        await renderText(page, base, target, index, state);
      }
      page.cleanup();
    } catch (error) {
      if (wanted.has(index) && error.name !== "RenderingCancelledException") {
        target.replaceChildren(element("p", "other-note", "이 페이지를 표시할 수 없어요."));
      }
    } finally {
      renders.delete(index);
      if (wanted.has(index) && !target.firstChild) render(index);
    }
  }

  let frame = 0;
  function scheduleRender() {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      const center = (window.visualViewport?.offsetTop ?? 0) + (window.visualViewport?.height ?? innerHeight) / 2;
      const nearest = [...nearby].map(index => {
        const { top, bottom } = pages[index].getBoundingClientRect();
        return { index, distance: Math.max(top - center, center - bottom, 0) };
      }).sort((a, b) => a.distance - b.distance);
      // shortcut: keep five neighboring canvases; use tiled rendering for dense page grids.
      const next = new Set(nearest.slice(0, 5).map(({ index }) => index));
      for (const index of wanted) {
        if (next.has(index)) continue;
        wanted.delete(index);
        renders.get(index)?.task?.cancel();
        renders.get(index)?.textLayer?.cancel();
        layers.get(index)?.highlighter.disable();
        layers.delete(index);
        pages[index].replaceChildren();
      }
      for (const index of next) {
        wanted.add(index);
        if (!pages[index].firstChild) render(index);
      }
    });
  }
  const indexes = new Map(pages.map((page, index) => [page, index]));
  const nearViewport = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const index = indexes.get(entry.target);
      if (entry.isIntersecting) nearby.add(index);
      else nearby.delete(index);
    }
    scheduleRender();
  }, { rootMargin: "540px 0px" });
  for (const page of pages) nearViewport.observe(page);
  window.addEventListener("scroll", scheduleRender, { capture: true, passive: true });
  window.visualViewport?.addEventListener("scroll", scheduleRender, { passive: true });
  window.visualViewport?.addEventListener("resize", scheduleRender, { passive: true });
  window.addEventListener("pagehide", () => {
    document.removeEventListener("copy", blockCopy, true);
    wanted.clear();
    nearViewport.disconnect();
    resize.disconnect();
    cancelAnimationFrame(frame);
    window.removeEventListener("scroll", scheduleRender, true);
    window.visualViewport?.removeEventListener("scroll", scheduleRender);
    window.visualViewport?.removeEventListener("resize", scheduleRender);
    for (const state of renders.values()) state.textLayer?.cancel();
    for (const layer of layers.values()) layer.highlighter.disable();
    layers.clear();
    findController.setDocument(null);
    void loading.destroy().catch(() => {});
  }, { once: true });
  return {
    pageCount: navigation.pageCount,
    goToPage: navigation.goToPage,
    searchOccurrences(query, onUpdate) {
      searchQuery = query;
      reportMatches = onUpdate;
      startAtFirstPage = Boolean(query);
      if (query) {
        find("");
      } else {
        eventBus.dispatch("findbarclose", {});
        onUpdate(0, 0);
      }
    },
    moveOccurrence(step) {
      if (searchQuery) find("again", step < 0);
    },
  };
}

function decodeText(bytes) {
  if (bytes[0] === 255 && bytes[1] === 254) return new TextDecoder("utf-16le").decode(bytes);
  if (bytes[0] === 254 && bytes[1] === 255) return new TextDecoder("utf-16be").decode(bytes);
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return new TextDecoder("euc-kr").decode(bytes);
  }
}

function appendTable(page, rows, truncated) {
  const table = element("table");
  const body = table.createTBody();
  for (const row of rows) {
    const tr = body.insertRow();
    for (const value of row) tr.insertCell().textContent = value;
  }
  const scroller = element("div", "other-table");
  scroller.append(table);
  page.append(scroller);
  if (truncated) page.append(element("p", "other-note", "미리보기에 표의 일부만 표시돼요."));
}

async function commaSeparated(bytes) {
  const csv = await loadScript("papaparse-5.7.1.js", "Papa");
  const page = element("section", "other-document-page other-sheet");
  const { data, meta } = csv.parse(decodeText(bytes), { preview: maxSheetRows });
  appendTable(page, data.map(row => row.slice(0, maxSheetColumns)),
    meta.truncated || data.some(row => row.length > maxSheetColumns));
  return [page];
}

export async function openOther(extension, bytes, viewer, reportPage, requestPassword, reportPrintSize) {
  if (extension === "pdf") return pdfDocument(bytes, viewer, reportPage, requestPassword);
  let pages;
  let occurrenceSearch;
  switch (extension) {
    case "doc":
    case "docx":
    case "xls":
    case "xlsx":
    case "ppt":
    case "pptx": {
      const { officePages, docxSearch } = await import("./office-viewer.js");
      pages = await officePages(extension, bytes, requestPassword, reportPrintSize);
      if (extension === "docx") occurrenceSearch = docxSearch(pages[0]);
      break;
    }
    case "csv": pages = await commaSeparated(bytes); break;
    case "txt": pages = [element("pre", "other-document-page other-text", decodeText(bytes))]; break;
    default: throw new Error("이 파일 형식을 표시할 수 없어요.");
  }
  viewer.replaceChildren(...pages);
  const navigation = pagination(pages, reportPage, index => {
    const page = pages[index];
    return (page.shadowRoot?.querySelector(".office-content") ?? page).textContent;
  });
  return Object.assign(navigation, occurrenceSearch);
}
