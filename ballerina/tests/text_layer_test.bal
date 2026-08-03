// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;
import ballerina/time;

// ---- getExtension ------------------------------------------------------------

@test:Config {}
isolated function testGetExtensionBasic() {
    test:assertEquals(getExtension("report.pdf"), "pdf");
    test:assertEquals(getExtension("notes.TXT"), "txt", "Extension is lower-cased");
    test:assertEquals(getExtension("archive.tar.gz"), "gz", "Only the last extension is used");
}

@test:Config {}
isolated function testGetExtensionNoDot() {
    test:assertEquals(getExtension("README"), "", "No dot yields an empty extension");
    test:assertEquals(getExtension("reports/2026/q1"), "", "A path with no dot yields empty");
}

// ---- classify ----------------------------------------------------------------

@test:Config {}
isolated function testClassifyPlainTextByExtension() {
    test:assertEquals(classify("a.txt", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.md", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.json", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.csv", ()), PLAIN_TEXT);
    test:assertEquals(classify("a.xml", ()), PLAIN_TEXT);
}

@test:Config {}
isolated function testClassifyPlainTextByMimeType() {
    test:assertEquals(classify("noext", "text/plain"), PLAIN_TEXT, "Any text/* MIME is plain text");
    test:assertEquals(classify("data", "application/json"), PLAIN_TEXT);
    // MIME wins even when the extension is unknown.
    test:assertEquals(classify("weird.bin", "text/markdown"), PLAIN_TEXT);
}

@test:Config {}
isolated function testClassifyExtractablePdf() {
    test:assertEquals(classify("doc.pdf", ()), EXTRACTABLE);
    test:assertEquals(classify("noext", "application/pdf"), EXTRACTABLE);
}

@test:Config {}
isolated function testClassifyExtractableOfficeByExtension() {
    // Microsoft Office documents are extracted via Apache Tika (POI), same as PDFs.
    test:assertEquals(classify("a.docx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.pptx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.xlsx", ()), EXTRACTABLE);
    test:assertEquals(classify("a.doc", ()), EXTRACTABLE);
    test:assertEquals(classify("a.ppt", ()), EXTRACTABLE);
    test:assertEquals(classify("a.xls", ()), EXTRACTABLE);
}

@test:Config {}
isolated function testClassifyExtractableOfficeByMimeType() {
    // Azure Blob listings surface a real Content-Type, so the MIME branch of `classify`
    // fires for blobs — an Office MIME type classifies as EXTRACTABLE even when the
    // extension is missing or unknown.
    test:assertEquals(classify("noext", "application/msword"), EXTRACTABLE);
    test:assertEquals(classify("noext",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"), EXTRACTABLE);
    test:assertEquals(classify("noext", "application/vnd.ms-powerpoint"), EXTRACTABLE);
    test:assertEquals(classify("noext",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"), EXTRACTABLE);
    test:assertEquals(classify("noext", "application/vnd.ms-excel"), EXTRACTABLE);
    test:assertEquals(classify("noext",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), EXTRACTABLE);
    // MIME wins over an unrelated extension.
    test:assertEquals(classify("data.bin", "application/msword"), EXTRACTABLE);
}

@test:Config {}
isolated function testClassifyUnsupportedBinary() {
    test:assertEquals(classify("photo.png", ()), UNSUPPORTED);
    test:assertEquals(classify("clip.mp3", ()), UNSUPPORTED);
    test:assertEquals(classify("noextension", ()), UNSUPPORTED);
    test:assertEquals(classify("blob", "application/octet-stream"), UNSUPPORTED);
}

// ---- classify: the Content-Type wins over the extension ----------------------
// REGRESSION: the extension check used to be OR-ed into the same condition as the text-MIME
// check, so whichever matched first won. A blob's name and its Content-Type are set
// independently in Azure, and reading a PDF as UTF-8 text yields binary garbage, not text.

@test:Config {}
isolated function testClassifyPrefersMimeOverAMisleadingExtension() {
    test:assertEquals(classify("notes.txt", "application/pdf"), EXTRACTABLE,
            "A PDF stored under a .txt name must still be Tika-extracted");
    test:assertEquals(classify("data.json", "application/vnd.ms-excel"), EXTRACTABLE,
            "A legacy Excel blob stored under a .json name must still be Tika-extracted");
    test:assertEquals(classify("report.pdf", "text/plain"), PLAIN_TEXT,
            "Conversely, a text blob named .pdf is decoded, not sent to PDFBox");
}

@test:Config {}
isolated function testClassifyFallsBackToExtensionForUninformativeMime() {
    // `application/octet-stream` is what Azure records for a blob uploaded without an explicit
    // Content-Type, so it must not block the extension fallback.
    test:assertEquals(classify("report.pdf", "application/octet-stream"), EXTRACTABLE);
    test:assertEquals(classify("notes.md", "application/octet-stream"), PLAIN_TEXT);
    test:assertEquals(classify("sheet.xlsx", ()), EXTRACTABLE);
}

// ---- classify: parameterised MIME types --------------------------------------
// Azure echoes back the Content-Type set at upload, parameters included, while the MIME tables
// hold bare essences — an exact match on the raw header would miss every parameterised value.

@test:Config {}
isolated function testClassifyStripsMimeParameters() {
    test:assertEquals(classify("noext", "text/plain; charset=UTF-8"), PLAIN_TEXT);
    test:assertEquals(classify("noext", "application/json;charset=utf-8"), PLAIN_TEXT);
    test:assertEquals(classify("noext", "application/pdf; version=1.7"), EXTRACTABLE);
    test:assertEquals(classify("noext",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document; charset=binary"),
            EXTRACTABLE);
}

@test:Config {}
isolated function testEssenceOfNormalizesContentType() {
    test:assertEquals(essenceOf("Text/Plain; charset=UTF-8"), "text/plain", "Lower-cased, parameters cut");
    test:assertEquals(essenceOf("  application/pdf  "), "application/pdf", "Trimmed");
    test:assertEquals(essenceOf("application/pdf ; version=1.7"), "application/pdf",
            "Whitespace before the separator is trimmed too");
    test:assertEquals(essenceOf(()), "", "A missing Content-Type is the empty essence");
    test:assertEquals(essenceOf(""), "");
}

// ---- classify: markup --------------------------------------------------------

@test:Config {}
isolated function testClassifyMarkup() {
    test:assertEquals(classify("page.html", ()), MARKUP);
    test:assertEquals(classify("page.htm", ()), MARKUP);
    test:assertEquals(classify("page.xhtml", ()), MARKUP);
    // `text/html` starts with `text/`, so the markup check must run before the generic rule.
    test:assertEquals(classify("noext", "text/html"), MARKUP,
            "text/html must not fall through to the generic text/ rule");
    test:assertEquals(classify("noext", "text/html; charset=UTF-8"), MARKUP);
    test:assertEquals(classify("noext", "application/xhtml+xml"), MARKUP);
    test:assertTrue(isSupported(MARKUP), "Markup is a loadable kind");
}

// ---- decodeText: BOMs, charsets, corruption ----------------------------------
// REGRESSION: decoding was `string:fromBytes`, strict UTF-8 only. A BOM-prefixed file carried a
// stray U+FEFF into its first cell/heading and into every embedding built from it, and a UTF-16
// blob failed to load at all (silently skipped, in a prefix listing).

@test:Config {}
isolated function testDecodeTextStripsUtf8Bom() returns error? {
    byte[] withBom = [0xEF, 0xBB, 0xBF];
    withBom.push(..."name,amount".toBytes());
    string decoded = check decodeText(withBom, "");
    test:assertEquals(decoded, "name,amount", "The BOM must not reach the document body");
    test:assertTrue(decoded.startsWith("name"), "A downstream startsWith must still match");
}

@test:Config {}
isolated function testDecodeTextHandlesUtf16WithBom() returns error? {
    // "hi" in UTF-16LE, BOM first. The BOM is authoritative, so no charset need be declared.
    byte[] utf16le = [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00];
    test:assertEquals(check decodeText(utf16le, ""), "hi");
    byte[] utf16be = [0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69];
    test:assertEquals(check decodeText(utf16be, ""), "hi");
}

@test:Config {}
isolated function testDecodeTextHonoursADeclaredCharset() returns error? {
    // 0xE9 is `é` in windows-1252 / latin-1, and invalid as standalone UTF-8.
    byte[] latin1 = [0x63, 0x61, 0x66, 0xE9];
    test:assertEquals(check decodeText(latin1, "windows-1252"), "café");
    test:assertTrue(decodeText(latin1, "") is error,
            "Without a declared charset the same bytes are invalid UTF-8");
}

@test:Config {}
isolated function testDecodeTextFallsBackToUtf8ForAnUnknownCharset() returns error? {
    test:assertEquals(check decodeText("plain".toBytes(), "no-such-charset-9000"), "plain",
            "An unusable charset name falls back to UTF-8 rather than failing");
    test:assertEquals(check decodeText("plain".toBytes(), ""), "plain");
}

@test:Config {}
isolated function testDecodeTextStillRejectsCorruptContent() {
    // Decoding stays strict: once the charset is right, undecodable bytes are real corruption.
    test:assertTrue(decodeText([0xC3, 0x28], "utf-8") is error,
            "An invalid UTF-8 sequence is an error, not replacement characters");
}

@test:Config {}
isolated function testCharsetFromContentType() {
    test:assertEquals(charsetFromContentType("text/plain; charset=UTF-16LE"), "UTF-16LE");
    test:assertEquals(charsetFromContentType("text/plain;charset=utf-8"), "utf-8");
    test:assertEquals(charsetFromContentType("text/html; charset=\"iso-8859-1\"; boundary=x"),
            "iso-8859-1", "A quoted charset followed by another parameter");
    test:assertEquals(charsetFromContentType("application/pdf"), "", "No charset declared");
    test:assertEquals(charsetFromContentType(""), "");
}

// ---- htmlToText --------------------------------------------------------------

@test:Config {}
isolated function testHtmlToTextStripsTagsAndResolvesEntities() {
    string rendered = htmlToText(
            "<html><body><h1>Title</h1><p>Caf&eacute; &amp; bar &#8212; open</p></body></html>");
    test:assertTrue(rendered.includes("Title"), rendered);
    test:assertTrue(rendered.includes("&"), "Named entities are resolved");
    test:assertTrue(rendered.includes("—"), "Numeric entities are resolved");
    test:assertFalse(rendered.includes("<"), "No tags survive");
    test:assertFalse(rendered.includes("&amp;"), "No undecoded entity survives");
}

@test:Config {}
isolated function testHtmlToTextDropsScriptAndStyleBodies() {
    string rendered = htmlToText(
            "<style>.a{color:red}</style><p>Visible</p><script>var x = 1;</script><!-- note -->");
    test:assertTrue(rendered.includes("Visible"), rendered);
    test:assertFalse(rendered.includes("color:red"), "Stylesheet source is not document text");
    test:assertFalse(rendered.includes("var x"), "Script source is not document text");
    test:assertFalse(rendered.includes("note"), "Comments are dropped");
}

@test:Config {}
isolated function testHtmlToTextKeepsBlockBoundariesApart() {
    // Without a break, "one" and "two" would run together into "onetwo".
    string rendered = htmlToText("<p>one</p><p>two</p>");
    test:assertFalse(rendered.includes("onetwo"), rendered);
    test:assertTrue(rendered.includes("one"), rendered);
    test:assertTrue(rendered.includes("two"), rendered);
}

@test:Config {}
isolated function testHtmlToTextResolvesAmpersandLast() {
    // Resolving &amp; first would turn "&amp;lt;" into "<".
    test:assertEquals(htmlToText("<p>&amp;lt;</p>"), "&lt;");
}

@test:Config {}
isolated function testBuildDocumentRendersMarkup() returns error? {
    ai:TextDocument? doc = check classifyAndBuild(
            "<html><body><p>Hello <b>world</b></p></body></html>".toBytes(),
            "page.html", "text/html");
    if doc is ai:TextDocument {
        test:assertFalse(doc.content.includes("<"), "Raw markup must not reach the document body");
        test:assertTrue(doc.content.includes("Hello"), doc.content);
        test:assertTrue(doc.content.includes("world"), doc.content);
    } else {
        test:assertFail("An HTML blob should build a TextDocument");
    }
}

// ---- classify: the .ts collision ---------------------------------------------

@test:Config {}
isolated function testClassifyDoesNotTreatBareTsAsText() {
    // `.ts` is TypeScript source and an MPEG transport stream. Guessing text would download a
    // whole video only to produce binary garbage.
    test:assertEquals(classify("stream.ts", ()), UNSUPPORTED);
    test:assertEquals(classify("stream.ts", "video/mp2t"), UNSUPPORTED);
    // Correctly typed TypeScript still loads, through the MIME branch.
    test:assertEquals(classify("module.ts", "text/plain"), PLAIN_TEXT);
}

// ---- matchesExtensionFilter --------------------------------------------------

@test:Config {}
isolated function testExtensionFilterEmptyMatchesAll() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ()));
    test:assertTrue(matchesExtensionFilter("a.png", []));
}

@test:Config {}
isolated function testExtensionFilterAllowlist() {
    test:assertTrue(matchesExtensionFilter("a.pdf", ["pdf"]));
    test:assertFalse(matchesExtensionFilter("a.txt", ["pdf"]));
}

@test:Config {}
isolated function testExtensionFilterCaseInsensitiveAndDotTolerant() {
    test:assertTrue(matchesExtensionFilter("A.PDF", ["pdf"]), "File extension compared case-insensitively");
    test:assertTrue(matchesExtensionFilter("a.pdf", [".PDF"]), "Leading dot and case tolerated in the allowlist");
    test:assertTrue(matchesExtensionFilter("a.md", ["pdf", ".md", "TXT"]));
}

// ---- toUtc -------------------------------------------------------------------

@test:Config {}
isolated function testToUtcParsesIso8601() {
    time:Utc? utc = toUtc("2024-01-15T10:30:00Z");
    test:assertTrue(utc is time:Utc, "A valid ISO 8601 timestamp parses");
}

@test:Config {}
isolated function testToUtcNilForNilOrUnparseable() {
    test:assertTrue(toUtc(()) is (), "() input yields ()");
    test:assertTrue(toUtc("not-a-timestamp") is (), "Unparseable input yields ()");
}

// ---- extractText (native Apache Tika) ----------------------------------------

@test:Config {}
isolated function testExtractTextFromPdfBytes() returns error? {
    string text = check extractText(PDF_BYTES, "sample.pdf", "");
    test:assertTrue(text.includes(PDF_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromDocxBytes() returns error? {
    // The .docx path exercises the POI-backed OOXML parser (tika-parser-microsoft-module).
    string text = check extractText(DOCX_BYTES, "sample.docx", "");
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsxBytes() returns error? {
    // .xlsx exercises the OOXML parser for a spreadsheet.
    string text = check extractText(XLSX_BYTES, "sample.xlsx", "");
    test:assertTrue(text.includes(XLSX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptxBytes() returns error? {
    // .pptx exercises the OOXML parser for a presentation (and the embedded-object skip).
    string text = check extractText(PPTX_BYTES, "sample.pptx", "");
    test:assertTrue(text.includes(PPTX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromDocBytes() returns error? {
    // Legacy .doc exercises the OLE2 OfficeParser for a Word document.
    string text = check extractText(DOC_BYTES, "sample.doc", "");
    test:assertTrue(text.includes(DOC_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromXlsBytes() returns error? {
    // Legacy .xls exercises the OLE2 OfficeParser for a spreadsheet.
    string text = check extractText(XLS_BYTES, "sample.xls", "");
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testExtractTextFromPptBytes() returns error? {
    // Legacy .ppt exercises the OLE2 OfficeParser for a presentation.
    string text = check extractText(PPT_BYTES, "sample.ppt", "");
    test:assertTrue(text.includes(PPT_TEXT), text);
}

@test:Config {}
isolated function testExtractTextOfficeByMimeTypeOnly() returns error? {
    // Azure Blob listings surface a real Content-Type, so `classify` can deem an
    // extension-less blob extractable from its MIME type alone — parser selection must
    // honour the same signal (an OOXML blob must not be misrouted to the PDF parser).
    string text = check extractText(DOCX_BYTES, "noext-word-doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
    test:assertTrue(text.includes(DOCX_TEXT), text);
}

@test:Config {}
isolated function testExtractTextLegacyOfficeByMimeTypeOnly() returns error? {
    // Same as above for the legacy OLE2 MIME family (OfficeParser).
    string text = check extractText(XLS_BYTES, "noext-spreadsheet", "application/vnd.ms-excel");
    test:assertTrue(text.includes(XLS_TEXT), text);
}

@test:Config {}
isolated function testBuildDocumentOfficeByMimeTypeOnly() returns error? {
    // End-to-end: MIME-only classification AND MIME-based parser selection agree, so an
    // extension-less Office blob builds a TextDocument instead of erroring as a bad PDF.
    ai:TextDocument? doc = check classifyAndBuild(DOCX_BYTES, "noext-word-doc",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(DOCX_TEXT), doc.content);
    } else {
        test:assertFail("A MIME-classified Office blob should extract to a TextDocument");
    }
}

// ---- scanned (image-only) PDF detection ---------------------------------------

@test:Config {}
isolated function testExtractTextFromScannedPdfErrors() {
    // The scanned fixture parses fine but has no text layer; the extractor must surface
    // a descriptive error rather than silently returning an empty string.
    string|error text = extractText(SCANNED_PDF_BYTES, "scan.pdf", "");
    if text is error {
        test:assertTrue(text.message().includes(SCANNED_PDF_SENTINEL), text.message());
    } else {
        test:assertFail("A scanned (image-only) PDF should surface a descriptive error");
    }
}

@test:Config {}
isolated function testBuildDocumentScannedPdfErrors() {
    ai:TextDocument?|ai:Error result = classifyAndBuild(SCANNED_PDF_BYTES, "scan.pdf", "application/pdf");
    if result is ai:Error {
        test:assertTrue(result.message().includes(SCANNED_PDF_SENTINEL), result.message());
        test:assertTrue(isScannedPdfError(result), "The error must be recognisable as scanned-PDF");
    } else {
        test:assertFail("Building a document from a scanned PDF should error, not skip or succeed");
    }
}

@test:Config {}
isolated function testIsScannedPdfErrorRejectsOtherErrors() {
    test:assertFalse(isScannedPdfError(error("some unrelated extraction failure")));
    test:assertFalse(isScannedPdfError(error("Failed to decode text content")));
}

// ---- buildDocument: plain-text path ------------------------------------------

@test:Config {}
isolated function testBuildDocumentPlainText() returns error? {
    byte[] bytes = "hello world".toBytes();
    ai:TextDocument? doc = check classifyAndBuild(bytes, "greeting.txt", "text/plain", 11);
    if doc is ai:TextDocument {
        test:assertEquals(doc.content, "hello world");
        test:assertEquals(doc.metadata?.fileName, "greeting.txt");
        test:assertEquals(doc.metadata?.mimeType, "text/plain");
        test:assertEquals(doc.metadata?.fileSize, <decimal>11);
        ai:Metadata metadata = doc.metadata ?: {};
        test:assertEquals(metadata["container"], TEST_CONTAINER,
                "The container is carried as an extra metadata field");
    } else {
        test:assertFail("A .txt file should build a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentPopulatesTimestamps() returns error? {
    ai:TextDocument? doc = check classifyAndBuild(
        "x".toBytes(), "a.txt", (), (), "2024-01-15T10:30:00Z", "2024-02-20T08:00:00Z");
    if doc is ai:TextDocument {
        test:assertTrue(doc.metadata?.createdAt !is (), "createdAt is populated from a valid timestamp");
        test:assertTrue(doc.metadata?.modifiedAt !is (), "modifiedAt is populated from a valid timestamp");
    } else {
        test:assertFail("Expected a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentDropsUnparseableTimestamp() returns error? {
    ai:TextDocument? doc = check classifyAndBuild("x".toBytes(), "a.txt", (), (), "bad-date");
    if doc is ai:TextDocument {
        test:assertTrue(doc.metadata?.createdAt is (), "An unparseable timestamp is dropped, not fatal");
    } else {
        test:assertFail("Expected a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentInvalidUtf8Errors() {
    // 0xFF is not a valid UTF-8 start byte, so decoding a "text" blob fails.
    byte[] invalid = [255, 254, 253];
    ai:TextDocument?|ai:Error result = classifyAndBuild(invalid, "broken.txt", "text/plain");
    if result is ai:Error {
        test:assertTrue(result.message().includes("Failed to decode text"), result.message());
    } else {
        test:assertFail("Invalid UTF-8 text content should surface as an error");
    }
}

// ---- buildDocument: PDF (extractable) path -----------------------------------

@test:Config {}
isolated function testBuildDocumentPdfExtractsText() returns error? {
    ai:TextDocument? doc = check classifyAndBuild(PDF_BYTES, "report.pdf", "application/pdf", 123);
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(PDF_TEXT), doc.content);
        test:assertEquals(doc.metadata?.fileName, "report.pdf");
        test:assertEquals(doc.metadata?.mimeType, "application/pdf");
    } else {
        test:assertFail("A .pdf file should extract to a TextDocument");
    }
}

// ---- buildDocument: skipped (unsupported) paths ------------------------------

@test:Config {}
isolated function testUnsupportedBinaryIsNotBuilt() returns error? {
    // An image cannot be represented as text, so `classify` puts it outside `isSupported` and
    // the loader skips it — crucially, before spending a download on it.
    test:assertEquals(classify("photo.png", "image/png"), UNSUPPORTED);
    test:assertFalse(isSupported(classify("photo.png", "image/png")));
    ai:TextDocument? doc = check classifyAndBuild([137, 80, 78, 71], "photo.png", "image/png");
    test:assertTrue(doc is (), "A non-text binary is skipped, never built");
}

@test:Config {}
isolated function testBuildDocumentRejectsUnsupportedKind() {
    // `buildDocument` is only ever reached for a supported kind. Passing UNSUPPORTED is a
    // caller bug, and must surface as an error rather than an empty document.
    ai:TextDocument|ai:Error result = buildDocument([137, 80, 78, 71], UNSUPPORTED, {fileName: "photo.png"});
    if result is ai:Error {
        test:assertTrue(result.message().includes("not a supported text type"), result.message());
    } else {
        test:assertFail("Building a document from an unsupported kind should error");
    }
}

// ---- buildDocument: Office (extractable) path --------------------------------

@test:Config {}
isolated function testBuildDocumentDocxExtractsText() returns error? {
    ai:TextDocument? doc = check classifyAndBuild(DOCX_BYTES, "summary.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document", 3518);
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(DOCX_TEXT), doc.content);
        test:assertEquals(doc.metadata?.fileName, "summary.docx");
    } else {
        test:assertFail("A .docx file should extract to a TextDocument");
    }
}

@test:Config {}
isolated function testBuildDocumentXlsxExtractsText() returns error? {
    ai:TextDocument? doc = check classifyAndBuild(XLSX_BYTES, "report.xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    if doc is ai:TextDocument {
        test:assertTrue(doc.content.includes(XLSX_TEXT), doc.content);
    } else {
        test:assertFail("A .xlsx file should extract to a TextDocument");
    }
}
