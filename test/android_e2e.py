"""Run the built Android APK through the native picker, viewer and share UI.

Use a disposable Android emulator with the Google Files picker and English
system UI, and install Poppler's pdftotext on the host. This suite installs the
debug preview APK and clears its app data.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

PACKAGE = "com.kobbokkom.kkomi.preview"
ACTIVITY = f"{PACKAGE}/com.kobbokkom.kkomi.MainActivity"
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "test/fixtures/android"
REMOTE = "/sdcard/Download/kkomi-e2e"
DUMP = "/data/local/tmp/kkomi-e2e.xml"


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *args, check=True, timeout=45):
        return subprocess.run(
            ["adb", "-s", self.serial, *args], check=check,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout,
        ).stdout

    def shell(self, *args):
        return self.adb("shell", *args)

    def nodes(self):
        for _ in range(3):
            try:
                result = self.adb("shell", "uiautomator", "dump", "--compressed", DUMP, timeout=16)
                if "dumped to" in result:
                    return list(ET.fromstring(self.adb("exec-out", "cat", DUMP)).iter("node"))
            except (ET.ParseError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
                continue
        return []

    def wait(self, predicate, description, timeout=90):
        deadline = time.monotonic() + timeout
        nodes = []
        while time.monotonic() < deadline:
            try:
                nodes = self.nodes()
            except (ET.ParseError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
                continue
            for node in nodes:
                if predicate(node):
                    return node
        labels = [n.get("text") or n.get("content-desc") for n in nodes]
        raise AssertionError(f"{description} missing: {[x for x in labels if x][:35]}")

    @staticmethod
    def labels(node):
        return node.get("text", ""), node.get("content-desc", "")

    def has(self, label):
        return self.wait(
            lambda node: any(label in value for value in self.labels(node)), label,
        )

    def scroll_to(self, label):
        for _ in range(8):
            nodes = self.nodes()
            for node in nodes:
                if any(label == value or label in value.splitlines() for value in self.labels(node)):
                    return node
            scroller = next((node for node in nodes if node.get("scrollable") == "true"
                             and node.get("package") == PACKAGE), None)
            if scroller is None:
                break
            left, top, right, bottom = map(int, re.findall(r"\d+", scroller.get("bounds")))
            x = str((left + right) // 2)
            self.shell("input", "swipe", x, str(bottom - 90), x, str(top + 90), "380")
        return self.has(label)

    def tap(self, label):
        self.click(self.wait(
            lambda node: node.get("enabled") != "false" and
            any(label == value or label in value.splitlines() for value in self.labels(node)),
            label,
        ))

    def click(self, node):
        left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds")))
        assert right > left and bottom > top, node.attrib
        self.shell("input", "tap", str((left + right) // 2), str((top + bottom) // 2))

    def id_tap(self, suffix):
        self.click(self.wait(
            lambda node: node.get("resource-id", "").endswith(suffix), suffix,
        ))

    def text(self, value):
        self.shell("input", "text", value)

    def back(self):
        self.shell("input", "keyevent", "KEYCODE_BACK")

    def private_copies(self):
        listing = self.adb("shell", "run-as", PACKAGE, "find", "files", "-path", "files/documents/*")
        return set(listing.split())

    def launch(self):
        self.shell("am", "start", "-W", "-n", ACTIVITY)

    def use_korean(self):
        settings = self.wait(
            lambda node: any(value in ("설정", "Settings") for value in self.labels(node)),
            "app settings",
        )
        if "설정" in self.labels(settings):
            return
        self.click(settings)
        self.tap("System default")
        self.tap("한국어")
        self.tap("닫기")

    def picker(self):
        self.click(self.scroll_to("파일 열기"))
        self.wait(lambda node: "documentsui" in node.get("package", ""), "Android picker")

    def use_builtin_viewer(self):
        self.tap("설정")
        switch = self.wait(
            lambda node: node.get("checkable") == "true" and any(
                "시스템 뷰어 우선 사용" in value for value in self.labels(node)),
            "system viewer setting",
        )
        if switch.get("checked") == "true":
            self.click(switch)
        self.tap("닫기")

    def storage_folder(self):
        nodes = self.nodes()
        for _ in range(2):
            if not any(n.get("content-desc") in ("Clear query", "검색어 지우기") or
                       n.get("resource-id", "").endswith(":id/action_mode_close_button") for n in nodes):
                break
            self.back()
            nodes = self.nodes()
        if not any(any(label in ("kkomi-e2e", "Files in kkomi-e2e") for label in self.labels(n))
                   and not n.get("resource-id", "").endswith(":id/title") for n in nodes):
            self.tap("Show roots")
            model = self.shell("getprop", "ro.product.model").strip()
            self.tap(model)
            self.click(self.wait(lambda n: n.get("text") in ("Download", "다운로드"), "Download folder"))
            self.tap("kkomi-e2e")
        if any("List view" in self.labels(n) for n in self.nodes()):
            self.tap("List view")

    def select_file(self, name):
        node = self.file_node(name)
        if node.get("selected") == "true":
            confirm = next((n for n in self.nodes() if n.get("resource-id", "").endswith(
                ":id/action_menu_select")), None)
            if confirm is not None:
                self.click(confirm)
                return
            self.id_tap(":id/action_mode_close_button")
            node = self.file_node(name)
        self.click(node)

    def file_node(self, name):
        direction = 1
        previous = None
        search = None
        for _ in range(8):
            nodes = self.nodes()
            search = next((n for n in nodes if any(value in ("Search", "검색")
                                                    for value in self.labels(n))), None)
            toolbar = next((n for n in nodes
                            if n.get("resource-id", "").endswith(":id/action_mode_bar")
                            or any(value in ("Show roots", "루트 표시") for value in self.labels(n))), None)
            toolbar_bottom = int(re.findall(r"\d+", toolbar.get("bounds"))[-1]) if toolbar is not None else 0
            for node in nodes:
                if node.get("text") == name and node.get("resource-id") == "android:id/title":
                    _, top, _, bottom = map(int, re.findall(r"\d+", node.get("bounds")))
                    if (top + bottom) // 2 >= toolbar_bottom:
                        return node
                    direction = -1
                    break
            files = next((node for node in reversed(nodes) if node.get("scrollable") == "true"
                          and "documentsui" in node.get("package", "")), None)
            if files is None:
                break
            titles = tuple(n.get("text") for n in nodes if n.get("resource-id") == "android:id/title")
            if titles == previous:
                if direction < 0:
                    break
                direction = -1
            previous = titles
            left, top, right, bottom = map(int, re.findall(r"\d+", files.get("bounds")))
            x = str((left + right) // 2)
            inset = min(90, (bottom - top) // 4)
            start, end = (bottom - inset, top + inset) if direction > 0 else (top + inset, bottom - inset)
            self.shell("input", "swipe", x, str(start), x, str(end), "200")
        if search is not None:
            self.click(search)
            self.text(name)
            self.shell("input", "keyevent", "KEYCODE_ENTER")
        return self.wait(lambda n: n.get("text") == name and
                         n.get("resource-id") == "android:id/title", f"{name} in Android Files")

    def open(self, name, visible):
        self.picker()
        self.select_file(name)
        if visible != "문서 암호":
            self.has(name)
        return self.has(visible)

    def prepare(self, apk):
        if not self.serial.startswith("emulator-") or self.shell("getprop", "ro.kernel.qemu").strip() != "1":
            raise SystemExit("This test clears preview data and requires a disposable emulator.")
        assert self.adb("install", "--no-streaming", "-r", str(apk), timeout=180).strip().endswith("Success")
        assert self.shell("pm", "clear", PACKAGE).strip() == "Success"
        self.shell("mkdir", "-p", REMOTE)
        for path in sorted(FIXTURES.iterdir()):
            if path.is_file() and path.suffix != ".md":
                self.adb("push", str(path), REMOTE + "/")


def check_resolver(device, mime, uri, *, browsable=False):
    category = ("-c", "android.intent.category.BROWSABLE") if browsable else ()
    result = device.shell(
        "cmd", "package", "query-activities", "--brief", "-a", "android.intent.action.VIEW",
        *category, "-d", uri, "-t", mime,
    )
    assert ACTIVITY in result, result


def launch_files(device):
    device.shell("am", "start", "-W", "-n",
                 "com.google.android.documentsui/com.android.documentsui.LauncherActivity")
    device.wait(lambda node: "documentsui" in node.get("package", ""), "Android Files")


def export_pdf(device, filename, *, direct=False, local_copy=None):
    device.tap("PDF로 저장")
    if not direct:
        device.wait(lambda n: "printspooler" in n.get("package", ""), "Android print preview")
        nodes = device.nodes()
        if not any(value in ("Save to PDF", "PDF에 저장") for n in nodes for value in device.labels(n)):
            device.click(device.wait(lambda n: any(value in ("Select a printer", "프린터 선택")
                                                    for value in device.labels(n)), "printer chooser"))
            device.click(device.wait(lambda n: any(value in ("Save as PDF", "PDF로 저장")
                                                    for value in device.labels(n)), "Save as PDF destination"))
        device.click(device.wait(lambda n: any(value in ("Save to PDF", "PDF에 저장")
                                                for value in device.labels(n)), "save print output"))
    field = device.wait(
        lambda n: n.get("class") == "android.widget.EditText",
        "save filename",
    )
    device.click(field)
    device.shell("input", "keyevent", "KEYCODE_MOVE_END")
    if name_length := len(field.get("text", "")):
        device.shell("input", "keyevent", *(["KEYCODE_DEL"] * name_length))
    device.text(filename)
    device.click(device.wait(
        lambda n: n.get("resource-id") == "android:id/button1" and
        n.get("text") in ("SAVE", "Save", "저장"),
        "save PDF",
    ))
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        # Files exposes the destination while the print spooler is still writing.
        result = device.adb("shell", "find", "/sdcard/Download", "-maxdepth", "3",
                            "-name", filename + ".pdf", "-size", "+0c", check=False)
        if result.strip():
            path = result.strip()
            header = device.adb("exec-out", "head", "-c", "8", path)
            assert header.startswith("%PDF-"), header
            tail = subprocess.check_output(
                ["adb", "-s", device.serial, "exec-out", "tail", "-c", "64", path],
                timeout=16,
            )
            if not tail.rstrip().endswith(b"%%EOF"):
                time.sleep(0.5)
                continue
            if local_copy is not None:
                device.adb("pull", path, str(local_copy))
            device.shell("rm", path)
            return
        time.sleep(0.5)
    raise AssertionError("Android did not create the exported PDF")


def run(device):
    base = "content://com.android.externalstorage.documents/document/"
    check_resolver(device, "application/octet-stream", base + "primary%3ADownload%2Fsample.hwp")
    check_resolver(device, "application/octet-stream", base + "123")
    check_resolver(device, "application/csv", base + "123")
    check_resolver(device, "text/tab-separated-values", base + "123")
    check_resolver(device, "application/vnd.openxmlformats-officedocument.presentationml.slideshow", base + "123")
    check_resolver(device, "application/x-hwp", base + "123", browsable=True)
    legacy = f"file://{REMOTE}/many.hwp"
    check_resolver(device, "application/x-hwp", legacy, browsable=True)
    device.launch()
    device.use_korean()
    for label in ("주간 열람", "연속 사용", "이번 주 페이지", "최근 문서", "0 / ∞"):
        device.has(label)

    # Keep Office/PDF in the app for rendering checks even if the emulator has an external handler.
    device.use_builtin_viewer()

    device.picker()
    device.storage_folder()
    device.select_file("offline.hwp")
    device.has("1 / 1")
    device.back()
    device.has("1 / ∞")
    device.has("1p")

    for name, marker in (
        ("offline.hwpx", "1 / 1"),
        ("many.hwp", "1 / 11"),
        ("four-pages.pdf", "1 / 4"),
        ("word.doc", "Document"),
        ("word.docx", "Document"),
        ("office-sheets.xls", "1 / 2"),
        ("office-sheets.xlsx", "1 / 2"),
        ("hidden-sheet.xlsx", "Office sheet one"),
        ("ods-print-options.ods", "1 / 2"),
        ("office-slides.ppt", "1 / 2"),
        ("office-slides.pptx", "1 / 2"),
        ("complex-slides.pptx", "1 / 4"),
        ("test.txt", "1 / 1"),
        ("test.csv", "1 / 1"),
        ("test.tsv", "1 / 1"),
        ("long.txt", "1 / 2"),
        ("long.csv", "1 / 4"),
    ):
        device.open(name, marker)
        print(f"PASS {name}", flush=True)
        if name == "four-pages.pdf":
            device.tap("검색")
            device.text("Proof")
            device.back()
            device.has("1 / 5")
            device.tap("다음 검색 결과")
            device.has("2 / 5")
            device.tap("검색 닫기")
        if name == "word.docx":
            device.click(device.wait(lambda n: n.get("class") == "android.widget.EditText",
                                     "DOCX bottom search"))
            device.text("Cell")
            device.back()
            device.has("검색 결과 1 / 2")
            device.tap("다음 검색 결과")
            device.has("검색 결과 2 / 2")
            device.tap("검색 닫기")
        if name in ("office-sheets.xls", "office-sheets.xlsx",
                    "office-slides.ppt", "office-slides.pptx"):
            device.tap("검색")
            device.text("Office%ssheet%sone" if "sheets" in name else "Office%sslide%sone")
            device.back()
            device.has("검색 결과가 있는 페이지 1개")
            device.tap("검색 닫기")
        if name == "test.csv":
            export_pdf(device, "kkomi-e2e-export", direct=True)
            device.has("test.csv")
        if name == "test.tsv":
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "table.pdf"
                export_pdf(device, "kkomi-e2e-tsv-export", direct=True, local_copy=pdf)
                table = subprocess.check_output(["pdftotext", "-layout", str(pdf), "-"], encoding="utf-8")
                assert "Seoul, Korea" in table and "0012" in table and "Second line" in table, table
            device.has("test.tsv")
        if name == "many.hwp":
            device.tap("다음 페이지")
            device.has("2 / 11")
            device.tap("이전 페이지")
            device.has("1 / 11")
            device.tap("검색")
            device.text("NoSuchHwpText")
            device.back()
            device.has("검색 결과 없음")
            device.tap("검색 닫기")
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "hwp.pdf"
                export_pdf(device, "kkomi-e2e-hwp-export", local_copy=pdf)
                text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
                pages = text.removesuffix("\f").split("\f")
                assert len(pages) == 11 and all(page.strip() for page in pages), len(pages)
                assert "찾아야 할 구절" in pages[6], pages[6]
                print("PASS 11-page HWP PDF with searchable Korean text", flush=True)
            device.has("1 / 11")
        if name == "office-sheets.xlsx":
            device.tap("문서 메뉴")
            export_pdf(device, "kkomi-e2e-sheets-export")
            device.has("1 / 2")
        if name == "hidden-sheet.xlsx":
            device.tap("검색")
            device.wait(lambda node: node.get("class") == "android.widget.EditText" and
                        node.get("focused") == "true", "sheet search field")
            device.text("two")
            device.has("two")
            device.back()
            device.has("검색 결과가 없어요")
            device.tap("검색 닫기")
            device.tap("문서 메뉴")
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "hidden-sheet.pdf"
                export_pdf(device, "kkomi-e2e-hidden-sheet", local_copy=pdf)
                text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
                words = " ".join(text.split())
                assert "Office sheet one" in words and "Office sheet two" not in words, text
        if name == "ods-print-options.ods":
            device.tap("검색")
            device.wait(lambda node: node.get("class") == "android.widget.EditText" and
                        node.get("focused") == "true", "sheet search field")
            device.text("two")
            device.has("검색 결과가 있는 페이지 1개")
            device.back()
            device.tap("검색 닫기")
            device.tap("문서 메뉴")
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "sheet.pdf"
                export_pdf(device, "kkomi-e2e-ods-print", local_copy=pdf)
                text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
                assert text.count("\f") == 1 and "two" not in text, text
                assert {"Office", "sheet", "one"}.issubset(text.split()), text
        if name == "office-slides.pptx":
            device.tap("문서 메뉴")
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "slides.pdf"
                export_pdf(device, "kkomi-e2e-slides-export", local_copy=pdf)
                text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
                pages = text.removesuffix("\f").split("\f")
                assert len(pages) == 2, len(pages)
                assert "Office slide one" in pages[0] and "Office slide two" in pages[1], text
            device.has("1 / 2")
        if name == "complex-slides.pptx":
            device.tap("문서 메뉴")
            with tempfile.TemporaryDirectory() as directory:
                pdf = Path(directory) / "complex-slides.pdf"
                export_pdf(device, "kkomi-e2e-complex-slides", local_copy=pdf)
                text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
                pages = text.removesuffix("\f").split("\f")
                assert len(pages) == 4 and "Quarterly results" in " ".join(pages[2].split()), text
                images = subprocess.check_output(["pdfimages", "-list", str(pdf)], encoding="utf-8")
                photo_pages = {
                    int(page) for page in re.findall(r"^\s*(\d+)\s+\d+\s+image\s+1200\s+760\b", images, re.M)
                }
                assert photo_pages == {1, 4}, images
            device.has("1 / 4")
        if name in ("long.txt", "long.csv"):
            device.tap("검색")
            device.text("TXTEndMarker" if name == "long.txt" else "CSVEndMarker")
            device.back()
            device.has("검색 결과 1 / 1")
            device.tap("검색 닫기")
            device.has("2 / 2" if name == "long.txt" else "4 / 4")
        device.back()
        device.has("최근 문서")
        if name == "many.hwp":
            device.has("13p")
        if name == "four-pages.pdf":
            device.has("17p")
            before = [value for node in device.nodes() for value in device.labels(node)
                      if value.startswith(("HWP\n", "HWPX\n", "PDF\n"))]
            device.tap("many.hwp")
            device.has("1 / 11")
            device.back()
            device.has("28p")
            after = [value.splitlines()[:2] for node in device.nodes() for value in device.labels(node)
                     if value.startswith(("HWP\n", "HWPX\n", "PDF\n"))]
            assert after == [value.splitlines()[:2] for value in before], (before, after)

    device.open("damaged.hwp", "문서를 읽을 수 없습니다.")
    device.back()
    device.has("damaged.hwp")
    device.open("distribution-restricted.hwp", "1 / 1")
    assert all("PDF로 저장" not in value and "꼬미 오프라인 열기" not in value
               for node in device.nodes() for value in device.labels(node))
    device.back()
    device.has("최근 문서")
    device.open("distribution-copy-restricted.hwp", "1 / 1")
    with tempfile.TemporaryDirectory() as directory:
        pdf = Path(directory) / "restricted.pdf"
        export_pdf(device, "kkomi-e2e-copy-restricted", local_copy=pdf)
        text = subprocess.check_output(["pdftotext", str(pdf), "-"], encoding="utf-8")
        assert not text.strip(), text
        images = subprocess.check_output(["pdfimages", "-list", str(pdf)], encoding="utf-8")
        assert len(images.splitlines()) > 2, images
    device.back()
    device.has("최근 문서")
    device.open("locked.hwp", "문서 암호")
    device.click(device.wait(lambda node: node.get("class") == "android.widget.EditText",
                             "password field"))
    device.text("bad")
    device.tap("열기")
    device.has("암호가 올바르지 않습니다.")
    device.click(device.wait(lambda node: node.get("class") == "android.widget.EditText",
                             "password field"))
    device.text("kkomi-test")
    device.tap("열기")
    device.has("1 / 1")
    device.back()
    device.has("최근 문서")
    device.open("locked.pdf", "문서 암호")
    device.text("1234")
    device.tap("열기")
    device.has("1 / 1")
    device.back()
    device.has("최근 문서")
    device.open("locked-office.docx", "문서 암호")
    device.text("kkomi-test")
    device.tap("열기")
    device.has("Document")
    device.back()
    device.has("최근 문서")

    # An actual Android DocumentsUI VIEW intent and an actual SEND chooser grant.
    copies_before = device.private_copies()
    launch_files(device)
    device.storage_folder()
    device.select_file("many.hwp")
    destination = device.wait(
        lambda n: any("1 / 11" in value or value == "꼬미 미리보기" for value in device.labels(n)),
        "HWP viewer or Android app chooser",
    )
    if "꼬미 미리보기" in device.labels(destination):
        device.click(destination)
        device.tap("Just once")
        device.has("1 / 11")
    launch_files(device)
    device.storage_folder()
    node = device.file_node("many.hwp")
    left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds")))
    x, y = str((left + right) // 2), str((top + bottom) // 2)
    device.shell("input", "swipe", x, y, x, y, "850")
    device.tap("Share")
    device.tap("꼬미 미리보기")
    device.has("1 / 11")
    device.back()
    device.has("최근 문서")
    # DocumentsUI grants may be persistable, so copies are optional; one name and its bytes keep one copy.
    assert len(device.private_copies() - copies_before) <= 1, device.private_copies() - copies_before
    # A file URI with no grant opens SAF; a subsequent launch can reuse that grant.
    legacy = f"file://{REMOTE}/legacy-intent.hwp"
    device.adb("push", str(FIXTURES / "offline.hwp"), f"{REMOTE}/legacy-intent.hwp")
    intent = ("am", "start", "-W", "-a", "android.intent.action.VIEW", "-c",
              "android.intent.category.BROWSABLE", "-d", legacy, "-t", "application/x-hwp", "-p", PACKAGE)
    device.shell(*intent)
    device.wait(lambda node: "documentsui" in node.get("package", ""), "legacy file picker")
    device.storage_folder()
    device.select_file("legacy-intent.hwp")
    device.has("PDF로 저장")
    device.back()
    device.has("최근 문서")
    device.shell("am", "force-stop", PACKAGE)
    device.shell(*intent)
    device.has("PDF로 저장")
    device.back()
    device.has("legacy-intent.hwp")
    # Reopening a finished task from Recents must not replay its original document intent.
    device.shell("am", "force-stop", PACKAGE)
    device.shell(*intent[:-2], "-f", "0x00100000", "-p", PACKAGE)
    device.has("최근 문서")
    time.sleep(3)
    assert not any("PDF로 저장" in value for n in device.nodes() for value in device.labels(n))
    # Shared text and links are not documents.
    device.shell("am", "start", "-W", "-a", "android.intent.action.SEND", "-t", "text/plain",
                 "--es", "android.intent.extra.TEXT", "https://example.invalid/", "-p", PACKAGE)
    device.has("지원하지 않는 파일 형식입니다.")
    # A picker result reaches a recreated activity.
    device.shell("settings", "put", "global", "always_finish_activities", "1")
    try:
        device.open("offline.hwpx", "PDF로 저장")
    finally:
        device.shell("settings", "put", "global", "always_finish_activities", "0")
    device.back()
    device.has("최근 문서")
    print("PASS launch, statistics, file associations, sharing, export and persistence", flush=True)


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--serial", required=True)
    args.add_argument("--apk", type=Path, default=ROOT / "build/app/outputs/flutter-apk/app-debug.apk")
    opts = args.parse_args()
    device = Device(opts.serial)
    device.prepare(opts.apk)
    run(device)


if __name__ == "__main__":
    main()
