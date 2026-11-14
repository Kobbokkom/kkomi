"""Verify the consent-gated Office converter on a disposable Android emulator."""
import argparse
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from android_e2e import Device, PACKAGE, ROOT, export_pdf


def converter_proxy(upstream_port, requests):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(self.path)
            length = int(self.headers["Content-Length"])
            assert 0 < length <= 64 * 1024 * 1024
            upstream = HTTPConnection("127.0.0.1", upstream_port, timeout=100)
            try:
                upstream.request("POST", self.path, self.rfile.read(length), {
                    "Content-Type": self.headers["Content-Type"],
                })
                response = upstream.getresponse()
                self.send_response(response.status)
                for name in ("Content-Type", "Content-Length"):
                    self.send_header(name, response.getheader(name))
                self.end_headers()
                while chunk := response.read(65536):
                    self.wfile.write(chunk)
            finally:
                upstream.close()

        def log_message(self, *_):
            pass

    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def run(device):
    device.launch()
    device.use_builtin_viewer()

    device.picker()
    device.storage_folder()
    device.select_file("complex.docx")
    device.has("서버에서 PDF로 변환할까요?")
    device.tap("서버에서 변환")
    device.has("1 / 3")
    device.tap("다음 페이지")
    device.has("2 / 3")
    device.tap("다음 페이지")
    device.has("3 / 3")
    export_pdf(device, "kkomi-converted-e2e", direct=True)
    device.back()
    device.has("3p")

    device.shell("am", "force-stop", PACKAGE)
    device.launch()
    device.click(device.has("complex.docx"))
    device.has("1 / 3")
    device.back()
    device.has("최근 문서")
    device.tap("최근 문서에서 삭제")

    device.picker()
    device.select_file("complex.docx")
    device.has("서버에서 PDF로 변환할까요?")
    device.tap("기기에서 열기")
    device.has("FirstPageHeading")
    device.back()
    device.has("최근 문서")

    device.open("offline.hwp", "1 / 1")
    assert not any("서버에서 PDF로 변환" in value
                   for node in device.nodes() for value in device.labels(node))
    device.back()

    device.picker()
    device.select_file("locked-legacy.xls")
    device.has("서버에서 PDF로 변환할까요?")
    device.tap("서버에서 변환")
    device.has("문서 암호")
    device.tap("취소")
    device.has("최근 문서")
    print("PASS Office fidelity, cache reuse and removal, local choice, PDF save, and HWP isolation", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", type=Path, default=ROOT / "build/app/outputs/flutter-apk/app-debug.apk")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device-port", type=int, help="Port embedded in the debug APK; defaults to --port")
    args = parser.parse_args()
    device = Device(args.serial)
    device.prepare(args.apk)
    port = f"tcp:{args.device_port or args.port}"
    requests = []
    with converter_proxy(args.port, requests) as proxy:
        thread = Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        try:
            device.adb("reverse", port, f"tcp:{proxy.server_port}")
            run(device)
            assert requests == ["/convert/docx"], requests
            print("PASS only consented, unencrypted Office reached the HTTP endpoint", flush=True)
        finally:
            device.adb("reverse", "--remove", port, check=False)
            proxy.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
