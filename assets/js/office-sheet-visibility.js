const spreadsheetNamespaces = new Set([
  'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
  'http://purl.oclc.org/ooxml/spreadsheetml/main',
]);
const office = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0';
const style = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0';
const table = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0';

function visibilityError() {
  return new Error('시트 표시 상태를 확인할 수 없어요.');
}

function parseXml(bytes) {
  if (!bytes?.length) throw visibilityError();
  const encoding = bytes[0] === 0xff && bytes[1] === 0xfe || bytes[0] === 0x3c && bytes[1] === 0
    ? 'utf-16le' : bytes[0] === 0xfe && bytes[1] === 0xff || bytes[0] === 0 && bytes[1] === 0x3c
      ? 'utf-16be' : 'utf-8';
  const xml = new TextDecoder(encoding, { fatal: true }).decode(bytes);
  const document = new DOMParser().parseFromString(xml, 'application/xml');
  if (document.doctype || document.querySelector('parsererror')) throw visibilityError();
  return document.documentElement;
}

function children(node, namespace, name) {
  return Array.from(node.children).filter(child => child.namespaceURI === namespace && child.localName === name);
}

function xlsxVisibility(bytes) {
  const workbook = parseXml(bytes);
  const namespace = workbook.namespaceURI;
  const lists = children(workbook, namespace, 'sheets');
  if (workbook.localName !== 'workbook' || !spreadsheetNamespaces.has(namespace) || lists.length !== 1) {
    throw visibilityError();
  }
  return children(lists[0], namespace, 'sheet').map(sheet => {
    const state = sheet.getAttribute('state') ?? 'visible';
    if (!['visible', 'hidden', 'veryHidden'].includes(state)) throw visibilityError();
    return [sheet.getAttribute('name'), { visible: state === 'visible', printable: true }];
  });
}

function odsVisibility(content, styles) {
  const root = parseXml(content);
  const body = children(root, office, 'body')[0];
  const spreadsheet = body && children(body, office, 'spreadsheet')[0];
  if (root.namespaceURI !== office || root.localName !== 'document-content' || !spreadsheet) throw visibilityError();
  const tableStyles = new Map();
  let defaultStyle;

  function addStyles(root, containers) {
    for (const container of containers) {
      for (const group of children(root, office, container)) {
        for (const node of group.children) {
          if (node.namespaceURI !== style || node.getAttributeNS(style, 'family') !== 'table') continue;
          if (node.localName === 'default-style') defaultStyle = node;
          if (node.localName === 'style') tableStyles.set(node.getAttributeNS(style, 'name'), node);
        }
      }
    }
  }

  if (styles) addStyles(parseXml(styles), ['styles', 'automatic-styles']);
  addStyles(root, ['automatic-styles']);

  function display(node) {
    const properties = node && children(node, style, 'table-properties')[0];
    const value = properties?.getAttributeNS(table, 'display');
    if (value === 'false' || value === '0') return false;
    if (value === 'true' || value === '1') return true;
    if (value != null) throw visibilityError();
  }

  return children(spreadsheet, table, 'table').map(sheet => {
    const print = sheet.getAttributeNS(table, 'print')?.trim();
    const printable = print === undefined || print === 'true' || print === '1';
    let name = sheet.getAttributeNS(table, 'style-name');
    const seen = new Set();
    let visible;
    while (name) {
      const node = tableStyles.get(name);
      if (!node || seen.has(name)) throw visibilityError();
      seen.add(name);
      visible = display(node);
      if (visible !== undefined) break;
      name = node.getAttributeNS(style, 'parent-style-name');
    }
    return [sheet.getAttributeNS(table, 'name'), { visible: visible ?? display(defaultStyle) ?? true, printable }];
  });
}

export function officeSheetOptions(type, metadata, views) {
  let sheets;
  if (type === 'xlsx') sheets = xlsxVisibility(metadata?.[0]);
  else if (type === 'ods') sheets = odsVisibility(metadata?.[0], metadata?.[1]);
  else return null;

  const byName = new Map();
  for (const [name, options] of sheets) {
    if (!name || byName.has(name)) throw visibilityError();
    byName.set(name, options);
  }
  return views.map(({ name }) => {
    if (!byName.has(name)) throw visibilityError();
    const options = byName.get(name);
    byName.delete(name);
    return options;
  });
}
