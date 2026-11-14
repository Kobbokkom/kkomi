// Requires Node.js 18+. Run with node --test test/odr_workbook_test.mjs.
// The locked fixture encrypts the synthetic hidden-sheet.xlsx with msoffcrypto-tool 5.4.2.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { Odr } from '../assets/js/vendor/odr-7.7.0.mjs';
import { strFromU8, strToU8, unzipSync, zipSync } from '../assets/js/vendor/fflate-0.8.3.mjs';

test('reads original workbook metadata after a password retry', async () => {
  const encrypted = await readFile(new URL('./fixtures/odr/locked-hidden.xlsx', import.meta.url));
  const original = await readFile(new URL('./fixtures/android/hidden-sheet.xlsx', import.meta.url));
  const workbook = unzipSync(original)['xl/workbook.xml'];
  assert.match(new TextDecoder().decode(workbook), /name="Other Sheet"[^>]*state="hidden"/);

  const odr = await Odr.load();
  const document = odr.open(encrypted, { name: 'locked-hidden.xlsx' });
  try {
    assert.equal(document.isPasswordEncrypted(), true);
    assert.throws(() => document.readSpreadsheetWorkbook(), { name: 'UnsupportedOperation' });
    assert.throws(() => document.decrypt('wrong-password'), { name: 'WrongPassword' });
    assert.equal(document.isPasswordEncrypted(), true);

    document.decrypt('kkomi-test');
    assert.equal(document.isPasswordEncrypted(), false);
    assert.deepEqual(document.readSpreadsheetWorkbook(), workbook);
    assert.deepEqual(document.listViews().slice(1).map(view => view.name), ['Office Sheet', 'Other Sheet']);
  } finally {
    document.close();
  }
});

test('accepts padded ODF booleans when sizing wrapped rows', async () => {
  const input = await readFile(new URL('./fixtures/android/ods-print-options.ods', import.meta.url));
  const files = unzipSync(input);
  const xml = strFromU8(files['content.xml']);
  const attribute = 'style:use-optimal-row-height="true"';
  assert.ok(xml.includes(attribute));
  const odr = await Odr.load();

  for (const [token, grows] of [[' true ', true], [' 1 ', true], [' false ', false], [' 0 ', false]]) {
    files['content.xml'] = strToU8(xml.replace(attribute, `style:use-optimal-row-height="${token}"`));
    const document = odr.open(zipSync(files, { level: 0 }), { name: 'wrapped.ods' });
    try {
      const { html } = document.render();
      const cell = html.match(/<td[^>]*>(?:\s*<x-p[^>]*>)?Office sheet one/);
      assert.ok(cell, 'Expected a wrapped fixture cell');
      assert.equal(cell[0].includes('odr-sheet-wrap-grow'), grows, token);
    } finally {
      document.close();
    }
  }
});
