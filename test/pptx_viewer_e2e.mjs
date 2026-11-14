// Requires Playwright, Chrome, Python 3 and Poppler. Run with node test/pptx_viewer_e2e.mjs.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const root = fileURLToPath(new URL('../', import.meta.url));
const fixture = join(root, 'test/fixtures/android/office-slides.pptx');
const output = await mkdtemp(join(tmpdir(), 'kkomi-pptx-test-'));
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript' };
let documentBytes;
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  try {
    if (path !== '/document' && !path.startsWith('/assets/')) throw new Error();
    const bytes = path === '/document' ? documentBytes : await readFile(join(root, path));
    response.writeHead(200, { 'Content-Type': mime[extname(path)] ?? 'application/octet-stream' }).end(bytes);
  } catch {
    response.writeHead(404).end();
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromium.launch({ channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 800, height: 750 } });
  const externalRequests = [];
  page.on('request', request => {
    if (request.url().startsWith('https://example.invalid/')) externalRequests.push(request.url());
  });
  await page.addInitScript(() => {
    window.events = [];
    window.Kkomi = { postMessage: message => events.push(JSON.parse(message)) };
    window.slideBlobs = [];
    const createObjectURL = URL.createObjectURL;
    URL.createObjectURL = blob => {
      if (blob.type === 'image/svg+xml') slideBlobs.push(blob);
      return createObjectURL(blob);
    };
  });
  async function open(width, height) {
    documentBytes = execFileSync('python3', ['-c', `
import io, sys, zipfile
from xml.etree import ElementTree as ET
path, width, height = sys.argv[1:]
result = io.BytesIO()
with zipfile.ZipFile(path) as source, zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as target:
    for name in source.namelist():
        content = source.read(name)
        if name == 'ppt/presentation.xml':
            root = ET.fromstring(content)
            size = root.find('{http://schemas.openxmlformats.org/presentationml/2006/main}sldSz')
            size.set('cx', str(round(float(width) * 914400)))
            size.set('cy', str(round(float(height) * 914400)))
            size.set('type', 'custom')
            content = ET.tostring(root)
        elif name == 'ppt/slides/slide1.xml':
            content = content.replace(b'<a:rPr sz="3000" b="1">', b'<a:rPr sz="3000" b="1"><a:hlinkClick r:id="rId2"/>')
        elif name == 'ppt/slides/_rels/slide1.xml.rels':
            link = b'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.invalid/" TargetMode="External"/>'
            content = content.replace(b'</Relationships>', link + b'</Relationships>')
        target.writestr(name, content)
sys.stdout.buffer.write(result.getvalue())
`, fixture, String(width), String(height)]);
    await page.goto(`${origin}/assets/viewer.html`);
    await page.evaluate(() => { void openDocument('pptx'); });
    await page.waitForFunction(() => events.some(({ event }) => event === 'ready' || event === 'error'));
    assert.deepEqual(await page.evaluate(() => events.filter(({ event }) => event !== 'page')), [
      { event: 'viewerReady' },
      { event: 'printMedia', value: { width: width * 1000, height: height * 1000 } },
      { event: 'ready', value: 2 },
    ]);
  }
  async function print(width, height, expectedText) {
    const path = join(output, 'slides.pdf');
    await page.pdf({ path, width: `${width}in`, height: `${height}in`, printBackground: true });
    const info = execFileSync('pdfinfo', [path], { encoding: 'utf8' });
    assert.match(info, /^Pages:\s+2$/m);
    assert.match(info, new RegExp(`^Page size:\\s+${72 * width}(?:\\.0+)? x ${72 * height}(?:\\.0+)? pts`, 'm'));
    if (expectedText) {
      const text = execFileSync('pdftotext', [path, '-'], { encoding: 'utf8' });
      assert.equal(text.match(/Office slide one/g)?.length, 1, text);
      assert.equal(text.match(/Office slide two/g)?.length, 1, text);
    }
  }
  await open(10, 7.5);
  const line = page.locator('.office-slide-text text').first();
  const slide = page.locator('.office-pptx').first();
  const imageMarkup = await page.evaluate(() => slideBlobs[0].text());
  assert.match(imageMarkup, /<a href="https:\/\/example\.invalid\//);
  assert.equal(await slide.locator('.office-slide-text a, .office-slide-text [href]').count(), 0);
  const { x, y, width, height } = await line.boundingBox();
  await page.mouse.move(x + 1, y + height / 2);
  await page.mouse.down();
  await page.mouse.move(x + width - 1, y + height / 2, { steps: 12 });
  await page.mouse.up();
  assert.equal(await page.evaluate(() => getSelection().toString()), 'Office slide one');
  await print(10, 7.5, true);
  await open(48, 30);
  await print(48, 30, true);
  await open(56, 31);
  await print(56, 31, true);
  await open(1, 56);
  await print(1, 56, false);
  assert.deepEqual(externalRequests, []);
  console.log('PASS ordinary text selection and four PPTX PDF page sizes');
} finally {
  await browser?.close();
  server.closeAllConnections();
  server.close();
  await rm(output, { recursive: true, force: true });
}
