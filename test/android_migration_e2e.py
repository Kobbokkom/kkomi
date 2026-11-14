"""Exercise an original-format preference and recent-file migration in a disposable preview."""
import argparse
from datetime import date, timedelta
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import xml.etree.ElementTree as ET

from android_e2e import Device, FIXTURES, PACKAGE, ROOT

NAME = "Old shared document.hwp"
LOCKED_NAME = "Old password protected.pdf"
MISSING_NAME = "Removed after migration.hwp"
MISSING_PATH = "files/file_cache/missing.hwp"
FIXTURE_PACKAGE = f"{PACKAGE}.migration"


class MigrationDevice(Device):
    def __init__(self, serial, package=PACKAGE):
        super().__init__(serial)
        self.package = package

    def launch(self):
        self.shell("am", "start", "-W", "-n", f"{self.package}/com.kobbokkom.kkomi.MainActivity")


def write_app_file(device, path, contents):
    command = f"run-as {device.package} sh -c {shlex.quote(f'cat > {shlex.quote(path)}')}"
    subprocess.run(
        ["adb", "-s", device.serial, "shell", "-T", command],
        input=contents, check=True, timeout=15,
    )


def seed(device):
    device.shell("run-as", device.package, "mkdir", "-p", "files/file_cache", "shared_prefs")
    base = device.shell("run-as", device.package, "pwd").strip()
    today = date.fromisoformat(device.shell("date", "+%F").strip())
    monday = today - timedelta(days=today.weekday())
    documents = {
        "file_cache/legacy sample.hwp": ("offline.hwp", NAME, "HWP"),
        "file_cache/legacy protected.pdf": ("locked.pdf", LOCKED_NAME, "PDF"),
        MISSING_PATH.removeprefix("files/"): ("offline.hwp", MISSING_NAME, "HWP"),
        "file_cache/../outside.hwp": ("offline.hwp", "Outside.hwp", "HWP"),
    }
    history = []
    for path, (fixture, name, extension) in documents.items():
        write_app_file(device, f"files/{path}", (FIXTURES / fixture).read_bytes())
        history.append({"path": f"{base}/files/{path}", "name": name, "type": extension,
                        "openedAt": f"{today}T00:00:00.000"})

    preferences = ET.Element("map")
    for key, value in {
        "week_start_date_v1": f"{monday}T00:00:00.000",
        "pages_week_start_date_v1": f"{monday}T00:00:00.000",
        "last_used_date_v1": today.isoformat(),
        "recent_documents_v1": json.dumps(history),
    }.items():
        ET.SubElement(preferences, "string", name=f"flutter.{key}").text = value
    for key, value in {"current_usage_v1": 3, "current_pages_v1": 22,
                       "current_streak_v1": 4, "weekly_limit_v1": 200}.items():
        ET.SubElement(preferences, "long", name=f"flutter.{key}", value=str(value))
    ET.SubElement(preferences, "boolean", name="flutter.prefer_native_viewer", value="false")
    write_app_file(device, "shared_prefs/FlutterSharedPreferences.xml",
                   ET.tostring(preferences, encoding="utf-8", xml_declaration=True))


def expect_home(device, *labels, absent=()):
    def matches(node, label):
        return any(label in value.splitlines() for value in device.labels(node))
    for label in labels:
        device.wait(lambda node: matches(node, label), label, timeout=75)
    if absent:
        nodes = device.nodes()
        assert nodes and all(not matches(node, label) for node in nodes for label in absent)


def run(device):
    expect_home(device, "3 / ∞", "22p", "4일", NAME, LOCKED_NAME, MISSING_NAME,
                absent=("Outside.hwp",))

    device.shell("am", "force-stop", device.package)
    device.shell("run-as", device.package, "rm", MISSING_PATH)
    device.launch()
    expect_home(device, "3 / ∞", "22p", "4일", NAME, LOCKED_NAME, absent=(MISSING_NAME,))

    device.tap("설정")
    setting = device.wait(
        lambda node: node.get("checkable") == "true" and
        any("시스템 뷰어 우선 사용" in label for label in device.labels(node)),
        "system viewer setting",
    )
    assert setting.get("checked") == "false", setting.attrib
    device.tap("닫기")
    device.tap(NAME)
    device.has("1 / 1")
    device.back()
    expect_home(device, "4 / ∞", "23p")

    device.tap(LOCKED_NAME)
    device.has("문서 암호")
    device.click(device.wait(lambda node: node.get("class") == "android.widget.EditText",
                             "password input"))
    device.text("bad")
    device.tap("열기")
    device.has("암호가 올바르지 않습니다.")
    device.tap("취소")
    expect_home(device, "4 / ∞", "23p")

    device.tap(LOCKED_NAME)
    device.has("문서 암호")
    device.click(device.wait(lambda node: node.get("class") == "android.widget.EditText",
                             "password input"))
    device.text("1234")
    device.tap("열기")
    device.has("1 / 1")
    device.back()
    expect_home(device, "5 / ∞", "24p")

    device.tap("최근 문서 목록에서 제거")
    device.tap("최근 문서 목록에서 제거")
    device.has("최근에 연 문서가 없어요")

    device.shell("am", "force-stop", device.package)
    device.launch()
    expect_home(device, "5 / ∞", "24p", "최근에 연 문서가 없어요")
    assert device.shell("run-as", device.package, "ls", "files/file_cache").splitlines() == [
        "legacy protected.pdf", "legacy sample.hwp",
    ]
    print("PASS original-format migration, missing-file pruning, reopening, removal, and restart", flush=True)


def verify_apk_package(apk, package):
    properties = ROOT / "android/local.properties"
    sdk_paths = [Path(value) for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT")
                 if (value := os.environ.get(key))]
    if properties.is_file():
        sdk_paths.extend(Path(line.partition("=")[2]) for line in properties.read_text().splitlines()
                         if line.startswith("sdk.dir="))
    executables = [str(path) for sdk in sdk_paths for path in sorted(sdk.glob("build-tools/*/aapt2"), reverse=True)]
    if command := shutil.which("aapt2"):
        executables.insert(0, command)
    if not executables:
        raise SystemExit("aapt2 is required to check the fixture APK application ID before installing.")
    manifest = subprocess.check_output([executables[0], "dump", "badging", str(apk)], text=True, timeout=15)
    match = re.search(r"^package: name='([^']+)'", manifest, re.MULTILINE)
    if match is None or match.group(1) != package:
        raise SystemExit(f"Expected APK application ID {package}; no app was installed or cleared.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, default=ROOT / "build/app/outputs/flutter-apk/app-debug.apk")
    parser.add_argument("--fixture-package", choices=(FIXTURE_PACKAGE,),
                        help="Use a separately installed and cleared migration fixture on a device.")
    args = parser.parse_args()
    device = MigrationDevice(args.serial, args.fixture_package or PACKAGE)
    if not args.fixture_package and (
        not args.serial.startswith("emulator-") or device.shell("getprop", "ro.kernel.qemu").strip() != "1"
    ):
        raise SystemExit("Use a disposable emulator or supply the isolated migration APK and --fixture-package.")
    verify_apk_package(args.apk, device.package)
    subprocess.run(["adb", "-s", args.serial, "install", "--no-streaming", "-r", str(args.apk)],
                   check=True, timeout=180)
    assert device.shell("pm", "clear", device.package).strip() == "Success"
    seed(device)
    device.launch()
    device.use_korean()
    run(device)


if __name__ == "__main__":
    main()
