from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.client import HTTPConnection
import os
from pathlib import Path
import re
import shutil
import struct
import sys
from tempfile import TemporaryDirectory
import threading
import unittest
import zipfile
from unittest.mock import patch

from office_converter import ConverterServer
from office_formats import IMPORT_FILTERS, MAX_BYTES, is_office_document


FIXTURES = Path(__file__).resolve().parents[1] / "test/fixtures/android"
OFFICE_FILES = {
    "doc": "word.doc", "docx": "word.docx",
    "xls": "office-sheets.xls", "xlsx": "office-sheets.xlsx",
    "ppt": "office-slides.ppt", "pptx": "office-slides.pptx",
}
HEADERS = {"Content-Type": "application/octet-stream"}


@contextmanager
def serve(soffice, token=b"", timeout=45):
    with ConverterServer(("127.0.0.1", 0), soffice, token, timeout) as server:
        worker = threading.Thread(target=server.serve_forever, args=(0.02,))
        worker.start()
        try:
            yield server.server_port
        finally:
            server.shutdown()
            worker.join()


def request(port, path, data=None, headers=None):
    connection = HTTPConnection("127.0.0.1", port, timeout=55)
    try:
        connection.request("GET" if data is None else "POST", path, data, headers or {})
        response = connection.getresponse()
        return response.status, response.getheader("Content-Type"), response.read()
    finally:
        connection.close()


class OfficeConverterTest(unittest.TestCase):
    def test_each_supported_format_and_cross_format_renames(self):
        self.assertEqual(set(OFFICE_FILES), set(IMPORT_FILTERS))
        for extension, name in OFFICE_FILES.items():
            source = FIXTURES / name
            for claimed in OFFICE_FILES:
                with self.subTest(file=name, claimed=claimed):
                    self.assertEqual(is_office_document(source, claimed), claimed == extension)

    def test_hwp_and_locked_office_never_enter_converter(self):
        for name in ("offline.hwp", "offline.hwpx", "locked-office.docx"):
            for extension in OFFICE_FILES:
                with self.subTest(file=name, extension=extension):
                    self.assertFalse(is_office_document(FIXTURES / name, extension))

    def test_hybrid_hwpx_and_ooxml_is_rejected(self):
        with TemporaryDirectory() as directory:
            hybrid = Path(directory) / "hybrid.docx"
            shutil.copy(FIXTURES / "word.docx", hybrid)
            with zipfile.ZipFile(hybrid, "a") as output:
                output.writestr("mimetype", "application/hwp+zip")
                output.writestr("Contents/content.hpf", "")
            self.assertFalse(is_office_document(hybrid, "docx"))

    def test_malformed_content_types_or_dtd_are_rejected(self):
        with TemporaryDirectory() as directory:
            for mode in ("wrong-root", "dtd", "bad-zip", "bad-part", "bad-deflate"):
                path = Path(directory) / f"{mode}.docx"
                original = FIXTURES / "word.docx"
                if mode == "bad-zip":
                    path.write_bytes(original.read_bytes()[:128])
                elif mode == "bad-deflate":
                    data = bytearray(original.read_bytes())
                    with zipfile.ZipFile(original) as source:
                        entry = source.getinfo("[Content_Types].xml")
                        self.assertEqual(entry.compress_type, zipfile.ZIP_DEFLATED)
                    name_size, extra_size = struct.unpack_from("<HH", data, entry.header_offset + 26)
                    body = entry.header_offset + 30 + name_size + extra_size
                    data[body] |= 0b111  # Invalid DEFLATE block type.
                    path.write_bytes(data)
                else:
                    with zipfile.ZipFile(original) as source, zipfile.ZipFile(path, "w") as copy:
                        for name in source.namelist():
                            data = source.read(name)
                            if name == "[Content_Types].xml" and mode == "wrong-root":
                                data = b"<wrong/>"
                            elif name == "[Content_Types].xml" and mode == "dtd":
                                data = b'<!DOCTYPE Types [<!ENTITY test "bad">]>' + data.split(b"?>", 1)[-1]
                            elif name == "word/document.xml" and mode == "bad-part":
                                data = b""
                            copy.writestr(name, data)
                with self.subTest(mode=mode):
                    self.assertFalse(is_office_document(path, "docx"))

    def test_http_bounds_and_auth_are_checked_before_conversion(self):
        data = (FIXTURES / "word.docx").read_bytes()
        hwpx = (FIXTURES / "offline.hwpx").read_bytes()
        auth = {**HEADERS, "Authorization": "Bearer test-token"}
        with serve(sys.executable, b"test-token") as port, patch("office_converter.convert") as convert:
            self.assertEqual(request(port, "/healthz"), (200, "text/plain; charset=utf-8", b"ready\n"))
            self.assertEqual(request(port, "/convert/docx", data, HEADERS)[0], 401)
            self.assertEqual(request(port, "/convert/hwp", data, auth)[0], 404)
            self.assertEqual(request(port, "/convert/hwpx", hwpx, auth)[0], 404)
            self.assertEqual(request(port, "/convert/docx", data, {"Authorization": "Bearer test-token"})[0], 415)
            self.assertEqual(request(port, "/convert/docx", b"", auth)[0], 413)
            self.assertEqual(request(port, "/convert/docx", b"", {**auth, "Content-Length": str(MAX_BYTES + 1)})[0], 413)
            self.assertEqual(request(port, "/convert/docx", hwpx, auth)[0], 422)
            self.assertEqual(request(port, "/convert/docx", data, {**auth, "Transfer-Encoding": "chunked"})[0], 411)
            convert.assert_not_called()

    def test_timeout_and_cleanup(self):
        with TemporaryDirectory() as directory:
            marker = Path(directory) / "process.cwd"
            fake = Path(directory) / "slow-converter"
            fake.write_text(f'#!/bin/sh\nprintf "%s" "$PWD" > "{marker}"\n/bin/sleep 60\n', encoding="utf-8")
            fake.chmod(0o700)
            data = (FIXTURES / "word.docx").read_bytes()
            with serve(str(fake), timeout=1.5) as port:
                self.assertEqual(request(port, "/convert/docx", data, HEADERS)[0], 504)
            work = Path(marker.read_text(encoding="utf-8"))
            self.assertFalse(work.exists())

    def test_real_libreoffice_all_formats(self):
        soffice = shutil.which(os.environ.get("KKOMI_TEST_SOFFICE", "soffice"))
        if not soffice:
            self.skipTest("set KKOMI_TEST_SOFFICE to run the LibreOffice integration")
        with serve(soffice) as port, ThreadPoolExecutor(2) as executor:
            files = {**OFFICE_FILES, "complex": "complex.docx"}
            for extension, name in files.items():
                with self.subTest(extension=extension):
                    data = (FIXTURES / name).read_bytes()
                    route = Path(name).suffix[1:]
                    responses = [
                        executor.submit(request, port, f"/convert/{route}", data, HEADERS)
                        for _ in range(2)
                    ]
                    for response in responses:
                        status, content_type, pdf = response.result()
                        self.assertEqual((status, content_type), (200, "application/pdf"))
                        self.assertTrue(pdf.startswith(b"%PDF-"))
                        if extension == "complex":
                            self.assertEqual(len(re.findall(rb"/Type\s*/Page\b", pdf)), 3)
                            self.assertRegex(pdf, rb"/MediaBox\s*\[\s*0\s+0\s+792\s+612\s*\]")


if __name__ == "__main__":
    unittest.main()
