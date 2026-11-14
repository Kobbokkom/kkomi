# Synthetic Android E2E documents

The HWP/HWPX files were generated with bundled rhwp. The Office 97 and OOXML files were exported from LibreOffice using synthetic text, tables and slides. The small PDF has four pages and five instances of “Proof,” two of them on the first page. The protected HWP uses the test password `kkomi-test` and the protected PDF uses `1234`. The protected DOCX uses OOXML Agile Encryption and the password `kkomi-test`. All documents are synthetic.

The complex DOCX contains a header, footer, merged table and landscape section. The text and CSV fixtures include multi-page examples.

`locked-legacy.xls` is a copy of `office-sheets.xls` with a BIFF record marker in a later workbook mini sector replaced by `FILEPASS`. The converter test uses it to verify rejection before HTTP upload.

`distribution-restricted.hwp` uses the synthetic content of `offline.hwp` in a distribution `ViewText` stream. Both copy and printing restriction flags are set.
