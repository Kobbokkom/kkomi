// @rhwp/core 0.9.0, bundled with its license and notices.
import init, { HwpDocument } from './rhwp.js';
import { viewerText } from './viewer-strings.js';

const maxRenderedPages = 5;
const maxPageSvgBytes = 24 * 1024 * 1024;
const maxPrintSvgBytes = 64 * 1024 * 1024;
const maxTextLayoutLength = 2 * 1024 * 1024;
const maxTextRuns = 2000;
// shortcut: cap the source JSON and the entries sent through the bridge; paginate if longer outlines are needed.
const maxOutlineJsonLength = 2 * 1024 * 1024;
const maxOutlineItems = 2000;
const cfbSignature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
const noCopy = 1;
const noPrint = 2;

function truncateLabel(text, limit) {
    return text.slice(0, limit).replace(/[\uD800-\uDBFF]$/, '');
}

async function restrictionsFor(bytes) {
    if (!cfbSignature.every((byte, index) => bytes[index] === byte)) return 0;
    if (bytes.length > 64 * 1024 * 1024) return noCopy | noPrint;
    try {
        const { default: initPolicy, hwp_restrictions: readRestrictions } = await import('./hwp_policy.js');
        await initPolicy();
        return readRestrictions(bytes);
    } catch {
        return noCopy | noPrint;
    }
}

export async function openHwp(bytes, viewer, reportPage, requestPassword) {
    const measure = document.createElement('canvas').getContext('2d');
    globalThis.measureTextWidth = (font, text) => {
        measure.font = font;
        return measure.measureText(text).width;
    };
    await init();

    const restrictions = await restrictionsFor(bytes);
    const doc = await openDocument(bytes, requestPassword);
    const pageCount = doc.pageCount();
    const pages = [];
    const sizes = [];
    const nearby = new Set();
    const rendered = new Map();
    const failed = new Set();
    let reportedPage = -1;
    let frame = 0;
    let searchId = 0;
    let occurrences = [];
    const marksByPage = new Map();
    let selected = -1;
    let reportMatches;
    let disposed = false;
    let printSession;

    const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
            const index = Number(entry.target.dataset.pageIndex);
            if (entry.isIntersecting) nearby.add(index);
            else nearby.delete(index);
        }
        scheduleRefresh();
    }, { rootMargin: '50% 0px' });

    try {
        // shortcut: cap placeholder count on phones, virtualize the page list if larger files are needed.
        if (pageCount < 1) throw new Error('쪽을 찾을 수 없습니다.');
        if (pageCount > 2000) {
            throw new Error('Too many HWP pages', { cause: 'hwpPageLimit' });
        }
        for (let index = 0; index < pageCount; index++) {
            const { width, height } = JSON.parse(doc.getPageInfo(index));
            if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
                throw new Error('쪽 크기를 확인할 수 없습니다.');
            }
            const page = document.createElement('div');
            page.className = 'page';
            page.dataset.pageIndex = index;
            page.style.aspectRatio = `${width} / ${height}`;
            pages.push(page);
            sizes.push({ width, height });
        }
        viewer.replaceChildren(...pages);
        await renderPage(0);
        for (const page of pages) observer.observe(page);
        window.addEventListener('scroll', scheduleRefresh, { passive: true });
        window.visualViewport?.addEventListener('scroll', scheduleRefresh, { passive: true });
        window.visualViewport?.addEventListener('resize', scheduleRefresh, { passive: true });
        window.addEventListener('pagehide', onPageHide);
    } catch (error) {
        dispose();
        throw error;
    }

    return {
        pageCount,
        canPrint: (restrictions & noPrint) === 0,
        find,
        searchOccurrences,
        moveOccurrence,
        preparePrint,
        releasePrint,
        ...(restrictions & noCopy ? {} : { readOutline }),
        goToPage(index) {
            pages[index]?.scrollIntoView({ block: 'start', inline: 'nearest' });
        },
        dispose,
    };

    function readOutline() {
        if (disposed) return [];
        try {
            const json = doc.getOutlineNavigation();
            if (json.length > maxOutlineJsonLength) return [];
            const { outline } = JSON.parse(json);
            if (!Array.isArray(outline)) return [];

            const items = [];
            for (const entry of outline) {
                if (!entry) continue;
                const { level, number, title, page } = entry;
                if (!Number.isInteger(level) || level < 1 || level > 10 ||
                    !Number.isInteger(page) || page < 1 || page > pageCount ||
                    typeof number !== 'string' || typeof title !== 'string') continue;
                items.push({
                    level,
                    number: truncateLabel(number, 32),
                    title: truncateLabel(title, 160),
                    page,
                });
                if (items.length === maxOutlineItems) break;
            }
            return items;
        } catch {
            return [];
        }
    }

    function pageSvg(index) {
        const blob = new Blob([doc.renderPageSvg(index)], { type: 'image/svg+xml' });
        // shortcut: bound each page image, switch to tiles if giant pages need support.
        if (blob.size > maxPageSvgBytes) throw new Error('쪽을 표시하기에 너무 큽니다.');
        return blob;
    }

    function pageImage(index, url) {
        const image = document.createElement('img');
        image.alt = viewerText('page', '{page}쪽', index + 1);
        // SVG image mode prevents document links, script and external asset loads.
        image.src = url;
        return image;
    }

    async function renderPage(index) {
        const url = URL.createObjectURL(pageSvg(index));
        const image = pageImage(index, url);
        rendered.set(index, url);
        pages[index].replaceChildren(image);
        drawHighlights(index);
        try {
            await image.decode();
        } catch (error) {
            if (rendered.get(index) !== url) return;
            unloadPage(index);
            throw error;
        }
        if ((restrictions & noCopy) === 0 && rendered.get(index) === url) drawSelectableText(index);
    }

    function drawSelectableText(index) {
        let runs;
        try {
            const layout = doc.getPageTextLayout(index);
            if (layout.length > maxTextLayoutLength) return;
            ({ runs } = JSON.parse(layout));
        } catch {
            return;
        }
        if (!Array.isArray(runs) || runs.length > maxTextRuns) return;

        const { width, height } = sizes[index];
        const layer = document.createElement('div');
        layer.className = 'hwp-selectable-text';
        let previousRun;
        let previousParagraph;
        for (const run of runs) {
            if (!run.text || !(run.h > 0 && run.w > 0)) continue;
            const fontSize = Math.max(1, run.h * 0.86);
            measure.font = `${fontSize}px sans-serif`;
            const advance = measure.measureText(run.text).width;
            if (!(advance > 0)) continue;

            const span = document.createElement('span');
            span.dir = 'auto';
            span.textContent = run.text;
            span.style.left = `${100 * run.x / width}%`;
            span.style.top = `${100 * run.y / height}%`;
            span.style.fontSize = `${100 * fontSize / width}cqw`;
            span.style.lineHeight = `${100 * run.h / width}cqw`;
            span.style.transform = `scaleX(${run.w / advance})`;

            const paragraph = JSON.stringify([run.secIdx, run.paraIdx, run.cellPath]);
            if (previousRun && (paragraph !== previousParagraph ||
                Math.abs(run.y - previousRun.y) > Math.min(run.h, previousRun.h) / 2)) {
                layer.append('\n');
            }
            layer.append(span);
            previousRun = run;
            previousParagraph = paragraph;
        }
        if (layer.childElementCount) pages[index].append(layer);
    }

    async function rasterPrintPage(svg, index) {
        const source = URL.createObjectURL(svg);
        const image = pageImage(index, source);
        const canvas = document.createElement('canvas');
        try {
            await image.decode();
            const { width, height } = sizes[index];
            const scale = Math.min(2.5, 4096 / Math.max(width, height), Math.sqrt(8e6 / width / height));
            canvas.width = Math.max(1, Math.floor(width * scale));
            canvas.height = Math.max(1, Math.floor(height * scale));
            const context = canvas.getContext('2d', { alpha: false });
            context.fillStyle = '#fff';
            context.fillRect(0, 0, canvas.width, canvas.height);
            context.drawImage(image, 0, 0, canvas.width, canvas.height);
            const raster = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
            if (!raster) throw new Error('Cannot encode print page');
            return raster;
        } finally {
            canvas.width = canvas.height = 0;
            URL.revokeObjectURL(source);
        }
    }

    async function preparePrint() {
        if (restrictions & noPrint) throw new Error('이 문서는 PDF로 저장할 수 없습니다.');
        if (disposed) throw new Error('문서가 닫혔습니다.');
        releasePrint();
        const layer = document.createElement('div');
        layer.className = 'hwp-print-document';
        layer.setAttribute('aria-hidden', 'true');
        const session = { layer, urls: [] };
        printSession = session;
        try {
            let bytes = 0;
            for (let index = 0; index < pageCount; index++) {
                const svg = pageSvg(index);
                // The PDF may retain selectable text from an SVG image.
                const blob = (restrictions & noCopy) ? await rasterPrintPage(svg, index) : svg;
                if (printSession !== session) throw new DOMException('Print cancelled', 'AbortError');
                bytes += blob.size;
                if (bytes > maxPrintSvgBytes) throw new Error('PDF로 저장하기에 문서가 너무 큽니다.');
                const url = URL.createObjectURL(blob);
                session.urls.push(url);
                const image = pageImage(index, url);
                layer.append(image);
                await image.decode();
                if (printSession !== session) throw new DOMException('Print cancelled', 'AbortError');
            }
            viewer.after(layer);
            document.body.classList.add('hwp-print-ready');
            return sizes[0];
        } catch (error) {
            if (printSession === session) releasePrint();
            throw error;
        }
    }

    function releasePrint() {
        const session = printSession;
        printSession = undefined;
        if (!session) return;
        document.body.classList.remove('hwp-print-ready');
        session.layer.remove();
        session.layer.replaceChildren();
        for (const url of session.urls) URL.revokeObjectURL(url);
    }

    function unloadPage(index) {
        URL.revokeObjectURL(rendered.get(index));
        rendered.delete(index);
        pages[index].replaceChildren();
    }

    function scheduleRefresh() {
        if (!frame && !disposed) frame = requestAnimationFrame(refresh);
    }

    function refresh() {
        frame = 0;
        const viewport = window.visualViewport;
        const top = viewport?.offsetTop ?? 0;
        const height = viewport?.height ?? window.innerHeight;
        const anchor = top + height / 3;
        const sorted = [...nearby].map((index) => {
            const { top, bottom } = pages[index].getBoundingClientRect();
            return { index, distance: Math.max(top - anchor, anchor - bottom, 0) };
        }).sort((a, b) => a.distance - b.distance);
        const closest = sorted[0]?.index;
        if (closest === undefined) return;
        if (closest !== reportedPage) {
            reportedPage = closest;
            reportPage(closest);
        }

        const desired = sorted.slice(0, maxRenderedPages).map(({ index }) => index);
        for (const index of rendered.keys()) {
            if (!desired.includes(index)) unloadPage(index);
        }
        const next = desired.find((index) => !rendered.has(index) && !failed.has(index));
        if (next === undefined) return;
        renderPage(next).catch(() => {
            failed.add(next);
            pages[next].textContent = viewerText('pageFailed', '{page}쪽을 표시할 수 없습니다.', next + 1);
        });
        scheduleRefresh();
    }

    function onPageHide(event) {
        if (!event.persisted) dispose();
    }

    function dispose() {
        if (disposed) return;
        disposed = true;
        releasePrint();
        observer.disconnect();
        cancelAnimationFrame(frame);
        window.removeEventListener('scroll', scheduleRefresh);
        window.visualViewport?.removeEventListener('scroll', scheduleRefresh);
        window.visualViewport?.removeEventListener('resize', scheduleRefresh);
        window.removeEventListener('pagehide', onPageHide);
        for (const index of rendered.keys()) unloadPage(index);
        doc.free();
    }

    async function findHits(query) {
        const id = ++searchId;
        if (disposed || !query.trim()) return [];
        const hits = JSON.parse(doc.searchAllText(query.trim(), false, true));
        const found = [];
        for (let i = 0; i < hits.length; i++) {
            if (i > 0 && i % 24 === 0) await new Promise((resolve) => requestAnimationFrame(resolve));
            if (disposed || id !== searchId) return null;
            const hit = hits[i];
            const rects = rectsForHit(doc, hit);
            const page = rects[0]?.pageIndex ?? pageForHit(doc, hit);
            if (Number.isInteger(page) && page >= 0 && page < pageCount) found.push({ page, rects });
        }
        return found;
    }

    async function find(query) {
        const hits = await findHits(query);
        return [...new Set((hits ?? []).map(hit => hit.page))].sort((a, b) => a - b);
    }

    async function searchOccurrences(query, report) {
        occurrences = [];
        marksByPage.clear();
        selected = -1;
        reportMatches = report;
        for (const index of rendered.keys()) drawHighlights(index);
        const hits = await findHits(query);
        if (hits === null) return;
        occurrences = hits;
        hits.forEach(({ rects }, index) => {
            for (const rect of rects) {
                if (!(rect.width > 0 && rect.height > 0)) continue;
                let marks = marksByPage.get(rect.pageIndex);
                if (!marks) marksByPage.set(rect.pageIndex, marks = []);
                marks.push({ rect, index });
            }
        });
        for (const index of rendered.keys()) drawHighlights(index);
        if (hits.length) moveOccurrence(1);
        else report(0, 0);
    }

    function moveOccurrence(step) {
        if (!occurrences.length) return;
        const previous = selected;
        selected = (selected + step + occurrences.length) % occurrences.length;
        const { page, rects } = occurrences[selected];
        if (rects.length) {
            const pageTop = pages[page].getBoundingClientRect().top + window.scrollY;
            const rectY = rects[0].y * pages[page].clientHeight / sizes[page].height;
            const viewport = window.visualViewport;
            const anchor = (viewport?.offsetTop ?? 0) + (viewport?.height ?? window.innerHeight) / 3;
            window.scrollTo({ top: pageTop + rectY - anchor });
        } else {
            pages[page].scrollIntoView({ block: 'start', inline: 'nearest' });
        }
        updateSelection(previous, false);
        updateSelection(selected, true);
        reportMatches?.(occurrences.length, selected + 1);
    }

    function updateSelection(index, active) {
        const result = occurrences[index];
        if (!result) return;
        for (const page of new Set(result.rects.map(rect => rect.pageIndex))) {
            for (const mark of pages[page]?.querySelectorAll(`.hwp-matches [data-match="${index}"]`) ?? []) {
                mark.classList.toggle('selected', active);
            }
        }
    }

    function drawHighlights(page) {
        pages[page].querySelector('.hwp-matches')?.remove();
        const marks = marksByPage.get(page);
        if (!marks?.length) return;
        const layer = document.createElement('div');
        layer.className = 'hwp-matches';
        layer.setAttribute('aria-hidden', 'true');
        const { width, height } = sizes[page];
        for (const { rect, index } of marks) {
            const mark = document.createElement('span');
            mark.dataset.match = index;
            if (index === selected) mark.className = 'selected';
            mark.style.left = `${100 * rect.x / width}%`;
            mark.style.top = `${100 * rect.y / height}%`;
            mark.style.width = `${100 * rect.width / width}%`;
            mark.style.height = `${100 * rect.height / height}%`;
            layer.append(mark);
        }
        pages[page].append(layer);
    }
}

async function openDocument(bytes, requestPassword) {
    try {
        return new HwpDocument(bytes);
    } catch (error) {
        if (!requestPassword || !/비밀번호가 필요한 암호 문서/i.test(String(error))) throw error;
    }

    let incorrect = false;
    while (true) {
        const password = await requestPassword(incorrect);
        if (password === null) throw new DOMException('Password cancelled', 'AbortError');
        try {
            return HwpDocument.openWithPassword(bytes, password);
        } catch (error) {
            if (!/비밀번호가 일치하지 않|암호 오류/i.test(String(error))) throw error;
            incorrect = true;
        }
    }
}

function rectsForHit(doc, { sec, para, charOffset, length, cellContext, cellPath, equationControl }) {
    try {
        const end = charOffset + length;
        if (cellPath) {
            const cellPara = cellPath.at(-1).cellParaIndex;
            return JSON.parse(doc.getSelectionRectsInCellByPath(
                sec, para, JSON.stringify(cellPath), cellPara, charOffset, cellPara, end,
            ));
        }
        if (cellContext) {
            const { parentPara, ctrlIdx, cellIdx, cellPara } = cellContext;
            return JSON.parse(doc.getSelectionRectsInCell(
                sec, parentPara, ctrlIdx, cellIdx, cellPara, charOffset, cellPara, end,
            ));
        }
        if (equationControl === undefined) {
            return JSON.parse(doc.getSelectionRects(sec, para, charOffset, para, end));
        }
    } catch {
        // Some embedded controls can still navigate by their parent paragraph.
    }
    return [];
}

function pageForHit(doc, { sec, para, charOffset, cellContext, cellPath, equationControl }) {
    try {
        if (cellPath) return JSON.parse(doc.getCursorRectByPath(sec, para, JSON.stringify(cellPath), charOffset)).pageIndex;
        if (cellContext) {
            const { parentPara, ctrlIdx, cellIdx, cellPara } = cellContext;
            return JSON.parse(doc.getCursorRectInCell(sec, parentPara, ctrlIdx, cellIdx, cellPara, charOffset)).pageIndex;
        }
        if (equationControl === undefined) return JSON.parse(doc.getCursorRect(sec, para, charOffset)).pageIndex;
    } catch {
        // Fall back to the page of the containing paragraph if the cursor has no rectangle.
    }
    return JSON.parse(doc.getPageOfPosition(sec, para)).page;
}
