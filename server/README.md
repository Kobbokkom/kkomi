# Office-to-PDF converter

Use this service to preserve the print layout of DOC, DOCX, XLS, XLSX, PPT and
PPTX. It runs LibreOffice with a fresh profile and an isolated temporary
directory for each request. HWP and HWPX are opened in the Android app with rhwp.
Encrypted Office files use the on-device viewer.

## Run locally

Install Python 3.10 or later and LibreOffice on macOS or Linux.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r server/requirements.txt
.venv/bin/python server/office_converter.py --port 8765
```

Use `--soffice /absolute/path/to/soffice` if LibreOffice is outside `PATH`.
The default listen address is `127.0.0.1`.

Build the Android debug APK with the loopback converter URL, then run the
converter test on a disposable emulator. The test sets up the ADB reverse port.

```sh
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=KKOMI_OFFICE_CONVERTER_URL=http://127.0.0.1:8765
python3 test/android_converter_e2e.py --serial emulator-5562
```

Release builds require an HTTPS converter URL. Configure hosted authentication
at the reverse proxy. The Android app does not embed or send a shared bearer
token. A trusted proxy can authenticate requests and supply a backend token.

## Request and response

`POST /convert/{extension}` accepts a raw binary body with
`Content-Type: application/octet-stream` and a single `Content-Length`.
The limit for both input and PDF is 64 MiB. A successful request returns
`application/pdf`. Input and output files are deleted when the request ends.
Document bytes, filenames and credentials are omitted from request logs.

`KKOMI_OFFICE_TOKEN` enables bearer authentication. A non-loopback binding
requires a token. If hosting for other devices, use a trusted TLS reverse
proxy that forwards only these routes and limits header/body time and size.
Run the worker as a dedicated unprivileged identity with outbound network
access denied and a disposable writable directory. Use the same LibreOffice
build and installed fonts across workers to keep pagination consistent.

`KKOMI_TEST_SOFFICE` selects the LibreOffice binary for the service tests.
