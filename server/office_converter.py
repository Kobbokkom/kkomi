"""Run the standalone Office-to-PDF service. See README.md for isolation."""

import argparse
import hmac
import ipaddress
import math
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer

from office_formats import IMPORT_FILTERS, MAX_BYTES, is_office_document


PROFILE = """<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
  <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
    <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
    <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
  </item>
  <item oor:path="/org.openoffice.Office.Writer/Content/Update">
    <prop oor:name="Link" oor:op="fuse"><value>0</value></prop>
  </item>
  <item oor:path="/org.openoffice.Office.Calc/Content/Update">
    <prop oor:name="Link" oor:op="fuse"><value>1</value></prop>
  </item>
</oor:items>
"""
REQUEST_TIMEOUT = 20
CONVERSION_TIMEOUT = 45
MAX_CONCURRENT = 2
MAX_CONNECTIONS = 4
BUFFER_SIZE = 64 * 1024
OFFICE_PATH = re.compile(r"/convert/([a-z]{3,4})\Z")
DECIMAL_LENGTH = re.compile(r"[0-9]{1,12}\Z")


class ConversionError(Exception):
    """The requested conversion could not produce a usable PDF."""


SOFFICE_EXEC = """import os, resource, sys
size, cpu = map(int, sys.argv[1:3])
resource.setrlimit(resource.RLIMIT_FSIZE, (size, size))
resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
os.execv(sys.argv[3], sys.argv[3:])
"""


def _terminate_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def convert(source, work, extension, soffice, timeout):
    profile = work / "profile"
    (profile / "user").mkdir(parents=True)
    (profile / "user" / "registrymodifications.xcu").write_text(PROFILE, encoding="utf-8")
    env = {"PATH": "/usr/bin:/bin", "HOME": str(work), "TMPDIR": str(work), "LANG": "C.UTF-8"}
    process = subprocess.Popen(
        [
            sys.executable, "-I", "-c", SOFFICE_EXEC, str(MAX_BYTES),
            str(math.ceil(timeout) + 5), soffice, "-env:UserInstallation=" + profile.as_uri(),
            "--headless", "--nologo", "--nodefault", "--norestore", "--nolockcheck",
            "--infilter=" + IMPORT_FILTERS[extension], "--convert-to", "pdf",
            "--outdir", str(work), str(source),
        ],
        cwd=work, env=env, start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        status = process.wait(timeout=timeout)
    finally:
        _terminate_group(process)
    output = source.with_suffix(".pdf")
    if status or not output.is_file() or not 8 <= output.stat().st_size <= MAX_BYTES:
        raise ConversionError()
    with output.open("rb") as response:
        if response.read(5) != b"%PDF-":
            raise ConversionError()
    return output


class ConverterHandler(BaseHTTPRequestHandler):
    server_version = "KkomiOffice"
    sys_version = ""

    def setup(self):
        self.request.settimeout(REQUEST_TIMEOUT)
        super().setup()

    def log_message(self, *_):
        # Requests may include credentials and documents. Keep request logs off.
        return

    def do_GET(self):
        if self.path == "/healthz":
            self._reply(HTTPStatus.OK, b"ready\n")
        else:
            self._reply(HTTPStatus.NOT_FOUND, b"not found\n")

    def do_POST(self):
        route = OFFICE_PATH.fullmatch(self.path)
        if not route or route[1] not in IMPORT_FILTERS:
            self._reply(HTTPStatus.NOT_FOUND, b"unsupported format\n")
            return
        if not self._authorized():
            self._reply(HTTPStatus.UNAUTHORIZED, b"unauthorized\n")
            return
        types = self.headers.get_all("Content-Type") or []
        if types != ["application/octet-stream"]:
            self._reply(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, b"expected application/octet-stream\n")
            return
        lengths = self.headers.get_all("Content-Length") or []
        if self.headers.get("Transfer-Encoding") is not None or len(lengths) != 1 or not DECIMAL_LENGTH.fullmatch(lengths[0]):
            self._reply(HTTPStatus.LENGTH_REQUIRED, b"expected one Content-Length\n")
            return
        length = int(lengths[0])
        if not 0 < length <= MAX_BYTES:
            self._reply(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, b"invalid document size\n")
            return
        with tempfile.TemporaryDirectory(prefix="kkomi-office-") as directory:
            work = Path(directory).resolve()
            source = work / f"input.{route[1]}"
            try:
                self._read_body(source, length)
            except TimeoutError:
                self._reply(HTTPStatus.REQUEST_TIMEOUT, b"upload timed out\n")
                return
            except (EOFError, ConnectionError):
                self._reply(HTTPStatus.BAD_REQUEST, b"incomplete upload\n")
                return
            if not is_office_document(source, route[1]):
                self._reply(HTTPStatus.UNPROCESSABLE_ENTITY, b"document format rejected\n")
                return
            if not self.server.slots.acquire(blocking=False):
                self._reply(HTTPStatus.SERVICE_UNAVAILABLE, b"converter busy\n")
                return
            try:
                output = convert(source, work, route[1], self.server.soffice, self.server.timeout)
            except subprocess.TimeoutExpired:
                self._reply(HTTPStatus.GATEWAY_TIMEOUT, b"conversion timed out\n")
                return
            except (ConversionError, OSError):
                self._reply(HTTPStatus.UNPROCESSABLE_ENTITY, b"conversion failed\n")
                return
            finally:
                self.server.slots.release()
            with output.open("rb") as response:
                self._headers(HTTPStatus.OK, "application/pdf", output.stat().st_size)
                shutil.copyfileobj(response, self.wfile, BUFFER_SIZE)

    def _authorized(self):
        if not self.server.token:
            return True
        auth = self.headers.get_all("Authorization") or []
        return len(auth) == 1 and hmac.compare_digest(
            auth[0].encode("utf-8"), b"Bearer " + self.server.token
        )

    def _read_body(self, source, remaining):
        deadline = time.monotonic() + REQUEST_TIMEOUT
        with source.open("wb") as file:
            while remaining:
                time_left = deadline - time.monotonic()
                if time_left <= 0:
                    raise TimeoutError()
                self.request.settimeout(time_left)
                chunk = self.rfile.read1(min(remaining, BUFFER_SIZE))
                if not chunk:
                    raise EOFError()
                file.write(chunk)
                remaining -= len(chunk)
        self.request.settimeout(REQUEST_TIMEOUT)

    def _headers(self, status, content_type, size):
        self.request.settimeout(REQUEST_TIMEOUT)
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def _reply(self, status, message):
        self._headers(status, "text/plain; charset=utf-8", len(message))
        self.wfile.write(message)


class ConverterServer(socketserver.ThreadingMixIn, HTTPServer):
    def __init__(self, address, soffice, token=b"", timeout=CONVERSION_TIMEOUT):
        if ipaddress.ip_address(address[0]).version == 6:
            self.address_family = socket.AF_INET6
        self.soffice = soffice
        self.token = token
        self.timeout = timeout
        self.slots = threading.BoundedSemaphore(MAX_CONCURRENT)
        self._connections = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(address, ConverterHandler)

    def process_request(self, request, address):
        if not self._connections.acquire(blocking=False):
            request.settimeout(1)
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self._connections.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self._connections.release()

    def handle_error(self, request, client_address):
        # Never print tracebacks that can contain request data.
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1", type=ipaddress.ip_address)
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--soffice", default="soffice")
    args = parser.parse_args()
    token = os.environ.get("KKOMI_OFFICE_TOKEN", "").encode("utf-8")
    if not args.bind.is_loopback and not token:
        parser.error("non-loopback binding requires KKOMI_OFFICE_TOKEN and a trusted TLS reverse proxy")
    soffice = shutil.which(args.soffice)
    if not soffice:
        parser.error("LibreOffice executable not found")
    with ConverterServer((str(args.bind), args.port), os.path.abspath(soffice), token) as server:
        print(f"Office converter ready on {args.bind}:{server.server_port}", file=sys.stderr, flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
