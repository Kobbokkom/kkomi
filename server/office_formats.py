"""Validate the six accepted Microsoft Office file formats before LibreOffice."""

import struct
import zipfile
import zlib

import olefile
from defusedxml import ElementTree
from defusedxml.common import DefusedXmlException


MAX_BYTES = 64 * 1024 * 1024
MAX_ZIP_EXPANDED_BYTES = 192 * 1024 * 1024
MAX_ZIP_MEMBERS = 10000

IMPORT_FILTERS = {
    "doc": "MS Word 97",
    "docx": "Office Open XML Text",
    "xls": "MS Excel 97",
    "xlsx": "Calc MS Excel 2007 XML",
    "ppt": "MS PowerPoint 97",
    "pptx": "Impress MS PowerPoint 2007 XML",
}

OOXML = {
    "docx": ("word/document.xml", "wordprocessingml.document", "wordprocessingml", "document"),
    "xlsx": ("xl/workbook.xml", "spreadsheetml.sheet", "spreadsheetml", "workbook"),
    "pptx": ("ppt/presentation.xml", "presentationml.presentation", "presentationml", "presentation"),
}
OFFICE_NS = "http://schemas.openxmlformats.org"
REL_NS = OFFICE_NS + "/package/2006/relationships"
CONTENT_TYPE_NS = OFFICE_NS + "/package/2006/content-types"
OFFICE_REL_TYPES = {
    OFFICE_NS + "/officeDocument/2006/relationships/officeDocument",
    "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument",
}
HWPX_MIME = b"application/hwp+zip"


def is_office_document(source, extension):
    try:
        if extension in OOXML:
            return _valid_ooxml(source, extension)
        if extension in IMPORT_FILTERS:
            return _valid_legacy(source, extension)
    except (
        DefusedXmlException, ElementTree.ParseError, EOFError, OSError, ValueError, StopIteration,
        RuntimeError, OverflowError, struct.error, zipfile.BadZipFile, zlib.error,
    ):
        pass
    return False


def _valid_ooxml(source, extension):
    part, type_name, family, root_name = OOXML[extension]
    with zipfile.ZipFile(source) as archive:
        members = archive.infolist()
        if len(members) > MAX_ZIP_MEMBERS:
            return False
        names = set()
        expanded = 0
        for member in members:
            name = member.filename.casefold()
            expanded += member.file_size
            if (
                name in names or name.startswith("/") or "\\" in name or
                any(piece in (".", "..") for piece in name.split("/")) or
                member.flag_bits & 1 or expanded > MAX_ZIP_EXPANDED_BYTES
            ):
                return False
            names.add(name)
        # The package-wide type, relationship and payload must describe the same
        # Office document. Explicitly reject HWPX even in a mixed-format archive.
        if {"contents/content.hpf", "contents/header.xml"} & names:
            return False
        if "mimetype" in names:
            with archive.open(next(m for m in members if m.filename.casefold() == "mimetype")) as stream:
                if stream.read(128).strip().lower() == HWPX_MIME:
                    return False
        if not {"[content_types].xml", "_rels/.rels", part}.issubset(names):
            return False
        types = _parse_package_xml(archive, "[Content_Types].xml", f"{{{CONTENT_TYPE_NS}}}Types")
        relationships = _parse_package_xml(archive, "_rels/.rels", f"{{{REL_NS}}}Relationships")
        if types is None or relationships is None:
            return False
        content_type = f"application/vnd.openxmlformats-officedocument.{type_name}.main+xml"
        if sum(
            node.get("PartName") == "/" + part and node.get("ContentType") == content_type
            for node in types.findall(f"{{{CONTENT_TYPE_NS}}}Override")
        ) != 1:
            return False
        main_parts = [
            node for node in relationships.findall(f"{{{REL_NS}}}Relationship")
            if node.get("Type") in OFFICE_REL_TYPES
        ]
        if (
            len(main_parts) != 1 or main_parts[0].get("TargetMode", "Internal") != "Internal" or
            main_parts[0].get("Target", "").lstrip("/") != part
        ):
            return False
        with archive.open(part) as stream:
            # Inspect the root without building the potentially large document tree.
            root = next(ElementTree.iterparse(stream, events=("start",), forbid_dtd=True))[1]
        return root.tag in {
            f"{{{OFFICE_NS}/{family}/2006/main}}{root_name}",
            f"{{http://purl.oclc.org/ooxml/{family}/main}}{root_name}",
        }


def _parse_package_xml(archive, name, expected_root):
    try:
        info = archive.getinfo(name)
    except KeyError:
        return None
    if info.file_size > 2 * 1024 * 1024:
        return None
    root = ElementTree.fromstring(archive.read(info), forbid_dtd=True)
    return root if root.tag == expected_root else None


def _valid_legacy(source, extension):
    with source.open("rb") as stream:
        magic = stream.read(8)
        if extension == "xls" and magic[:2] in (b"\x09\x00", b"\x09\x02", b"\x09\x04", b"\x09\x08"):
            stream.seek(0)
            return _valid_biff(stream)
        if magic != olefile.MAGIC:
            return False
    with olefile.OleFileIO(source, raise_defects=olefile.DEFECT_INCORRECT) as document:
        streams = {path[0].casefold() for path in document.listdir() if len(path) == 1}
        if streams & {"fileheader", "encryptedpackage", "encryptioninfo"}:
            return False
        if extension == "doc":
            return _valid_word(document, streams)
        if extension == "ppt":
            return _valid_powerpoint(document, streams)
        if extension == "xls":
            for name in ("Workbook", "Book"):
                if name.casefold() in streams:
                    with document.openstream(name) as workbook:
                        return _valid_biff(workbook)
    return False


def _valid_word(document, streams):
    if "worddocument" not in streams:
        return False
    with document.openstream("WordDocument") as word:
        fib = word.read(12)
    if len(fib) != 12 or fib[:2] != b"\xec\xa5":
        return False
    version = int.from_bytes(fib[2:4], "little")
    flags = int.from_bytes(fib[10:12], "little")
    if flags & 0x8100:
        return False
    return version < 0x00C1 or ("1table" if flags & 0x0200 else "0table") in streams


def _valid_powerpoint(document, streams):
    if not {"current user", "powerpoint document"}.issubset(streams):
        return False
    with document.openstream("Current User") as current_user:
        user = current_user.read(16)
    with document.openstream("PowerPoint Document") as slides:
        presentation = slides.read(8)
    return (
        len(user) == 16 and user[2:4] == b"\xf6\x0f" and user[12:16] == b"\x5f\xc0\x91\xe3" and
        len(presentation) == 8 and presentation[2:4] == b"\xe8\x03"
    )


def _valid_biff(workbook):
    header = workbook.read(4)
    if len(header) != 4:
        return False
    record_type, size = struct.unpack("<HH", header)
    bof = workbook.read(size)
    if record_type not in (0x0009, 0x0209, 0x0409, 0x0809) or len(bof) < 4 or bof[2:4] not in (b"\x05\x00", b"\x10\x00"):
        return False
    # Encryption is announced in the workbook globals with a FILEPASS record.
    while header := workbook.read(4):
        if len(header) != 4:
            return False
        record_type, size = struct.unpack("<HH", header)
        if record_type == 0x002F:
            return False
        if record_type == 0x000A:
            return True
        if len(workbook.read(size)) != size:
            return False
    return False
