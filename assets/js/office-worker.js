import { Odr } from "./vendor/odr-7.7.0.mjs";

const maxOfficeBytes = 64 * 1024 * 1024;
const maxMarkupLength = 32 * 1024 * 1024;
const maxViews = 500;

async function boundedZip(bytes) {
  const { unzipSync, zipSync } = await import("./vendor/fflate-0.8.3.mjs");
  let expanded = 0;
  const names = new Set();
  const files = unzipSync(bytes, { filter({ name, size, originalSize }) {
    expanded += Math.max(size, originalSize);
    if (names.size >= 10000 || expanded > maxOfficeBytes) {
      throw new Error("압축을 푼 문서의 크기가 너무 커요.");
    }
    if (names.has(name) || name.includes("\\") || name.split("/").some(part => part === ".." || part === ".") ||
        name.startsWith("/") || name in Object.prototype) {
      throw new Error("문서 내 파일 경로가 올바르지 않아요.");
    }
    names.add(name);
    return !name.endsWith("/");
  } });
  return zipSync(files, { level: 0 });
}

let passwordReply;

function requestPassword(incorrect) {
  return new Promise(resolve => {
    passwordReply = resolve;
    self.postMessage({ password: incorrect });
  });
}

self.onmessage = async ({ data: { extension, bytes, password } }) => {
  if (!bytes) {
    const reply = passwordReply;
    passwordReply = undefined;
    reply?.(password);
    return;
  }
  let doc;
  try {
    const odr = await Odr.load();
    const format = odr.enums.FileType[extension];
    const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b;
    doc = odr.open(isZip ? await boundedZip(bytes) : bytes, {
      name: "document." + extension,
      allowExternalContent: false,
      editable: false,
      keyboardNavigation: false,
      keyboardShortcuts: false,
      lazyLayout: false,
      spreadsheetLimit: { rows: 1000, columns: 128 },
      spreadsheetCellLimit: 48000,
      textDocumentMargin: extension === "doc",
      viewportMode: odr.enums.HtmlViewportMode.none,
    });
    let incorrect = false;
    while (doc.isPasswordEncrypted()) {
      const password = await requestPassword(incorrect);
      if (password === null) {
        self.postMessage({ error: "AbortError" });
        return;
      }
      try {
        doc.decrypt(password);
      } catch (error) {
        if (error.name !== "WrongPassword") throw error;
        incorrect = true;
      }
    }
    if (doc.fileType !== format) throw new Error("문서 형식과 확장자가 일치하지 않아요.");
    const views = doc.listViews().slice(1);
    if (views.length > maxViews) throw new Error("페이지가 너무 많아 문서를 표시할 수 없어요.");
    const { html } = doc.render();
    if (html.length > maxMarkupLength) throw new Error("문서가 너무 커서 표시할 수 없어요.");
    self.postMessage({ html, views });
  } catch (error) {
    self.postMessage({ error: error.name ?? "Error", message: error.message ?? "" });
  } finally {
    doc?.close();
  }
};
