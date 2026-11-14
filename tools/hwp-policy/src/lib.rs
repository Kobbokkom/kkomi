use cfb::CompoundFile;
use std::io::{Cursor, Read};
use wasm_bindgen::prelude::*;

const CFB_MAGIC: [u8; 8] = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
const MAX_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;
const NO_COPY: u8 = 1;
const NO_PRINT: u8 = 2;
const BOTH: u8 = NO_COPY | NO_PRINT;

#[wasm_bindgen]
pub fn hwp_restrictions(bytes: &[u8]) -> u8 {
    if !bytes.starts_with(&CFB_MAGIC) {
        return 0;
    }
    if bytes.len() > MAX_DOCUMENT_BYTES {
        return BOTH;
    }
    read_hwp_restrictions(bytes).unwrap_or(BOTH)
}

fn read_hwp_restrictions(bytes: &[u8]) -> Option<u8> {
    let mut ole = CompoundFile::open(Cursor::new(bytes)).ok()?;
    let mut header = [0; 40];
    ole.open_stream("/FileHeader")
        .ok()?
        .read_exact(&mut header)
        .ok()?;
    if !header.starts_with(b"HWP Document File") {
        return None;
    }
    if header[36] & 4 == 0 {
        return Some(0);
    }

    let mut sections = Vec::new();
    for entry in ole.read_storage("/ViewText").ok()? {
        let name = entry.name();
        if entry.is_stream()
            && name
                .get(..7)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("Section"))
            && name[7..].parse::<u32>().is_ok()
        {
            if sections.len() >= 2000 {
                return None;
            }
            sections.push(entry.path().to_owned());
        }
    }
    if sections.is_empty() {
        return None;
    }

    let mut result = 0;
    for path in sections {
        let mut record = [0; 260];
        ole.open_stream(path).ok()?.read_exact(&mut record).ok()?;
        let record_header = u32::from_le_bytes(record[..4].try_into().ok()?);
        if record_header & 0x3ff != 0x1c || record_header >> 20 != 256 {
            return None;
        }
        result |= distribution_flags(&record[4..])?;
        if result == BOTH {
            break;
        }
    }
    Some(result)
}

// The option word follows an 80-byte hash after the seed-dependent offset.
// Decode only its two bytes; the encrypted section body is never read here.
fn distribution_flags(payload: &[u8]) -> Option<u8> {
    let seed = u32::from_le_bytes(payload.get(..4)?.try_into().ok()?);
    let flags_offset = 4 + (seed & 15) as usize + 80;
    let mut state = seed;
    let mut rand = || {
        state = state.wrapping_mul(214013).wrapping_add(2531011);
        (state >> 16) & 0x7fff
    };
    let mut index = 0;
    let mut flags = [0; 2];
    while index <= flags_offset + 1 {
        let mask = rand() as u8;
        let count = ((rand() & 15) + 1) as usize;
        for (offset, flag) in flags.iter_mut().enumerate() {
            if (index..index + count).contains(&(flags_offset + offset)) {
                *flag = payload[flags_offset + offset] ^ mask;
            }
        }
        index += count;
    }
    let flags = u16::from_le_bytes(flags);
    (flags & !u16::from(BOTH) == 0).then_some(flags as u8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn reads_independent_copy_and_print_flags() {
        let cases = [
            (0_u32, [0x97, 0x97], 0),
            (1234, [0x3c, 0x3d], NO_COPY),
            (23231, [0x7f, 0x7d], NO_PRINT),
            (0xffff_fdfe, [0xf4, 0xf7], BOTH),
        ];
        for (seed, encoded, expected) in cases {
            let mut record = [0; 260];
            record[..4].copy_from_slice(&0x1000_001c_u32.to_le_bytes());
            record[4..8].copy_from_slice(&seed.to_le_bytes());
            let offset = 88 + (seed & 15) as usize;
            record[offset..offset + 2].copy_from_slice(&encoded);
            assert_eq!(hwp_restrictions(&distribution(&record)), expected);
        }
    }

    #[test]
    fn malformed_compound_or_distribution_is_restricted() {
        assert_eq!(hwp_restrictions(&CFB_MAGIC), BOTH);
        assert_eq!(hwp_restrictions(&distribution(&[0; 260])), BOTH);
        assert_eq!(hwp_restrictions(b"PK\x03\x04"), 0);
    }

    fn distribution(record: &[u8]) -> Vec<u8> {
        let mut ole = CompoundFile::create(Cursor::new(Vec::new())).unwrap();
        let mut header = [0; 256];
        header[..17].copy_from_slice(b"HWP Document File");
        header[36] = 4;
        ole.create_stream("/FileHeader")
            .unwrap()
            .write_all(&header)
            .unwrap();
        ole.create_storage("/ViewText").unwrap();
        ole.create_stream("/ViewText/Section0")
            .unwrap()
            .write_all(record)
            .unwrap();
        ole.into_inner().into_inner()
    }
}
