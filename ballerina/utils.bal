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
import ballerina/jballerina.java;
import ballerina/time;

// How a blob's content is turned into text, derived from its MIME type / extension. The
// classification is made from LISTING metadata, before the blob is downloaded, so an
// unsupported blob costs no bandwidth at all.
enum DocumentKind {
    // Inherently textual; decoded directly from its bytes and used verbatim.
    PLAIN_TEXT,
    // HTML or XHTML: decoded like plain text, then RENDERED to plain text, so tags and
    // character references never reach the document body.
    MARKUP,
    // A PDF or Microsoft Office document whose text is extracted via Apache Tika
    // (PDFBox for PDF, Apache POI for Office).
    EXTRACTABLE,
    // Cannot be represented as text (images, audio, unknown binary); skipped in prefix
    // listings, rejected when the blob is named explicitly.
    UNSUPPORTED
}

// Reports whether a document kind can be loaded as a text document at all. The caller
// classifies first and consults this before fetching, so the decision to skip is explicit
// rather than implied by a nil document.
isolated function isSupported(DocumentKind kind) returns boolean =>
    kind == PLAIN_TEXT || kind == MARKUP || kind == EXTRACTABLE;

// Builds `ai:Metadata` from a normalized listing entry. Azure reports a blob's `Content-Type`
// and `Content-Length` in the listing, so `mimeType` and `fileSize` are populated here;
// timestamps are parsed defensively (see `toUtc`) and simply omitted when unparseable.
//
// The container is retained as an extra field: `fileName` alone is not unique across a load
// that spans several containers, so `container` + `fileName` is the durable key a caller needs
// to trace a document back to the blob it came from.
isolated function buildMetadata(BlobEntry entry, string container) returns ai:Metadata {
    ai:Metadata metadata = {fileName: entry.name};
    string? mimeType = entry.contentType;
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    decimal? fileSize = entry.contentLength;
    if fileSize is decimal {
        metadata.fileSize = fileSize;
    }
    time:Utc? createdAt = toUtc(entry.creationTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(entry.lastModified);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }
    metadata["container"] = container;
    return metadata;
}

// Builds an `ai:TextDocument` from downloaded blob content, extracting the text of PDF and
// Microsoft Office documents via Apache Tika. Only ever called for a supported kind (see
// `isSupported`), so an `UNSUPPORTED` blob reaching here is a caller bug rather than a
// silently empty result.
//
// Decoding honours a byte-order mark first, then the `charset` Azure declared on the blob's
// Content-Type, then UTF-8, and strips any BOM (see `decodeText`). HTML is rendered to plain
// text rather than stored as raw markup, so tags and character references never reach the
// document body.
isolated function buildDocument(byte[] content, DocumentKind kind, ai:Metadata metadata)
        returns ai:TextDocument|ai:Error {
    string fileName = metadata.fileName ?: "<unnamed>";
    // The raw Content-Type, parameters included: the essence selects the Tika parser, the
    // `charset` parameter decides how text bytes are decoded.
    string contentType = metadata.mimeType ?: "";
    if kind == EXTRACTABLE {
        string|error text = extractText(content, fileName, essenceOf(contentType));
        if text is error {
            return error ai:Error(
                string `Failed to extract text from '${fileName}': ${text.message()}`, text);
        }
        return {content: text, metadata};
    }
    if kind == PLAIN_TEXT || kind == MARKUP {
        string|error text = decodeText(content, charsetFromContentType(contentType));
        if text is error {
            return error ai:Error(
                string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
        }
        // An HTML blob is textually meaningful only once its markup is rendered away; leaving
        // the tags in place injects markup tokens into every embedding downstream.
        return {content: kind == MARKUP ? htmlToText(text) : text, metadata};
    }
    return error ai:Error(string `Internal error: '${fileName}' was routed to document ` +
        string `construction but is not a supported text type`);
}

// Extracts the `charset` parameter from a `Content-Type`, or `""` when it declares none.
// Azure echoes back the charset recorded on the blob at upload time.
isolated function charsetFromContentType(string contentType) returns string {
    int? charsetIndex = contentType.toLowerAscii().indexOf("charset=");
    if charsetIndex is () {
        return "";
    }
    string rest = contentType.substring(charsetIndex + "charset=".length());
    // The charset parameter may be followed by further parameters, and may be quoted.
    int? separator = rest.indexOf(";");
    string charset = separator is int ? rest.substring(0, separator) : rest;
    return re `"`.replaceAll(charset.trim(), "");
}

// Extracts plain text from a PDF or Microsoft Office document using Apache Tika, reading
// directly from the in-memory bytes (no temporary file). `fileName` is passed as a Tika
// resource-name hint and used to select the parser; `mimeType` ("" if unknown) is the
// fallback selector for extension-less blobs, since Azure Blob listings surface a real
// Content-Type and `classify` may deem a blob extractable from its MIME type alone.
// Returns an `error` if the content cannot be parsed, or if a PDF has no extractable
// text layer (a scanned/image-only file).
isolated function extractText(byte[] content, string fileName, string mimeType)
        returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.blobs.TextExtractor",
    name: "extractText"
} external;

// Decodes downloaded text bytes. The charset is resolved from a byte-order mark first (which is
// authoritative and self-describing), then from `charset`, then UTF-8; any BOM is stripped so
// it never reaches the document body. Decoding is strict, so genuinely corrupt content still
// surfaces as an error rather than as replacement characters.
//
// `string:fromBytes` is deliberately not used: it is strict UTF-8 only, which makes a
// BOM-prefixed CSV carry a stray `U+FEFF` into its first cell and makes a UTF-16 blob fail to
// load at all.
isolated function decodeText(byte[] content, string charset) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.blobs.TextDecoder",
    name: "decodeText"
} external;

// Renders HTML markup as plain text: drops script/style bodies and comments, turns block
// boundaries into line breaks, strips the remaining tags and resolves character references.
isolated function htmlToText(string html) returns string = @java:Method {
    'class: "io.ballerina.lib.ai.azure.storage.blobs.TextDecoder",
    name: "htmlToText"
} external;

// The sentinel phrase the native extractor embeds when a PDF parses successfully but yields
// no text — a scanned / image-only document, or an empty one (see TextExtractor.SCANNED_PDF_MESSAGE).
// Kept to the stable substring of that message, since the surrounding wording has been reworded
// before and nothing enforces the two staying in sync.
const string SCANNED_PDF_SENTINEL = "no extractable text";

// Reports whether an error denotes a scanned (image-only) PDF. The loader uses this to
// skip such files in prefix listings (with a warning) — like other non-text content —
// while an explicitly named scanned PDF surfaces the descriptive error to the caller.
isolated function isScannedPdfError(error err) returns boolean =>
    err.message().includes(SCANNED_PDF_SENTINEL);

// Classifies a blob by how its text is obtained. The `Content-Type` Azure reports is
// authoritative and settles the class on its own; the blob-name extension is consulted only as
// a fallback, when the Content-Type is missing or unrecognised.
//
// The ordering matters. Azure lets a blob's name and its Content-Type be set independently, so
// evaluating the extension first would let a PDF stored as `notes.txt` be UTF-8 decoded instead
// of Tika-extracted, producing a document of binary garbage rather than the PDF's text.
//
// The fallback still carries most real containers: `application/octet-stream` is what Azure
// records for a blob uploaded without an explicit Content-Type, and it is not in either table,
// so such a blob drops through to its extension exactly as before.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = essenceOf(mimeType);
    if mime != "" {
        // Checked before the generic `text/` rule, which `text/html` would otherwise satisfy.
        if MARKUP_MIME_TYPES.indexOf(mime) !is () {
            return MARKUP;
        }
        if mime.startsWith("text/") || TEXT_MIME_TYPES.indexOf(mime) !is () {
            return PLAIN_TEXT;
        }
        // PDF and Microsoft Office documents are extracted via Apache Tika (PDFBox / POI).
        if EXTRACTABLE_MIME_TYPES.indexOf(mime) !is () {
            return EXTRACTABLE;
        }
    }

    string extension = getExtension(fileName);
    if MARKUP_EXTENSIONS.indexOf(extension) !is () {
        return MARKUP;
    }
    if TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    if EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACTABLE;
    }
    return UNSUPPORTED;
}

// Reduces a `Content-Type` to its essence: the lower-cased `type/subtype`, with any parameters
// and surrounding whitespace stripped. Azure echoes back whatever Content-Type was set at
// upload — `text/plain; charset=UTF-8`, `application/pdf; version=1.7` — while the MIME tables
// below hold bare essences, so an exact match against the raw header would miss every
// parameterised value.
isolated function essenceOf(string? contentType) returns string {
    string value = (contentType ?: "").trim().toLowerAscii();
    int? separator = value.indexOf(";");
    return separator is int ? value.substring(0, separator).trim() : value;
}

// Returns the lower-cased file extension (without the dot), or `""` if none.
//
// The search is confined to the LAST path segment. Blob names are full paths, and a dot in an
// ancestor folder ("v1.2/notes") is not an extension of anything: taking the last dot over the
// whole path would answer "2/notes", which is neither empty nor a real extension. That answer
// then reaches `loadPath`, where a non-empty extension means "this path names a file", so a
// missing blob under a dotted FOLDER name would be reported as `blob not found` instead of
// being listed as the prefix it is.
isolated function getExtension(string fileName) returns string {
    string basename = fileName;
    int? lastSlashIndex = fileName.lastIndexOf("/");
    if lastSlashIndex is int {
        basename = fileName.substring(lastSlashIndex + 1);
    }
    int? lastDotIndex = basename.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return basename.substring(lastDotIndex + 1).toLowerAscii();
}

// Reports whether a file passes the extension allowlist (`()`/empty matches all).
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

// Parses an ISO 8601 timestamp into `time:Utc`, or `()` if absent/unparseable.
// Azure's List Blobs XML reports `Creation-Time`/`Last-Modified` in RFC 1123 form, which
// `time:utcFromString` does not accept, so those are dropped gracefully.
isolated function toUtc(string? dateTime) returns time:Utc? {
    if dateTime is () {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// Normalizes a configured blob path into an Azure blob-name prefix: trims it, drops a
// leading `/` (Azure blob names have no leading slash), and maps the container root
// (`""`/`"/"`) to `""`. A trailing `/` is preserved, since it distinguishes an explicit
// folder prefix (`reports/`) from an ambiguous file-or-folder path (`reports`).
isolated function normalizeBlobPath(string path) returns string {
    string trimmed = path.trim();
    if trimmed == "" || trimmed == "/" {
        return "";
    }
    return trimmed.startsWith("/") ? trimmed.substring(1) : trimmed;
}

// Reports whether a blob lies directly under a prefix (no further `/` in the remainder),
// i.e. it is not inside a virtual sub-folder. Used for non-recursive listings, where a
// prefix listing otherwise returns blobs at every depth.
//
// A name that does not start with the prefix is not under it at all. The server-side prefix
// filter means that should never happen, but a length-only check would take the remainder from
// the wrong offset and answer about a substring of an unrelated name.
isolated function isDirectChild(string blobName, string prefix) returns boolean {
    if !blobName.startsWith(prefix) {
        return false;
    }
    return !blobName.substring(prefix.length()).includes("/");
}

// Reads a `map<json>` property (from a blob's `Properties`) as a non-empty string, or `()`.
// Azure's XML-derived values arrive as JSON strings, but numeric/other JSON is tolerated.
isolated function propString(map<json> properties, string key) returns string? {
    json value = properties[key];
    if value is string {
        return value.trim() == "" ? () : value;
    }
    if value is int|float|decimal {
        return value.toString();
    }
    return ();
}

// Reads a `map<json>` property as a `decimal` (e.g. `Content-Length`), or `()`.
isolated function propDecimal(map<json> properties, string key) returns decimal? {
    json value = properties[key];
    if value is int {
        return <decimal>value;
    }
    if value is decimal {
        return value;
    }
    if value is float {
        return <decimal>value;
    }
    if value is string {
        decimal|error parsed = decimal:fromString(value.trim());
        return parsed is decimal ? parsed : ();
    }
    return ();
}

// Reports whether a blob name can be addressed through the connector at all.
//
// UPSTREAM: `ballerinax/azure_storage_service.blobs` interpolates the blob name straight
// into the request path without percent-encoding it. Characters that are legal in an Azure
// blob name therefore break:
//
// - `#` starts a URI fragment, so the path is silently TRUNCATED at it and the request either
//   404s or, worse, addresses a different blob than the one intended;
// - `?` starts the query string, truncating the path the same way — and under SAS auth the
//   token the connector appends merges into the query the name just opened;
// - `%` begins a percent-escape the server then fails to decode, giving a 400;
// - non-ASCII is sent raw, which is not valid in a request line and is rejected or mangled.
//
// The loader cannot fix this — pre-encoding the name here would be double-encoded for SAS auth
// and would break the Shared Key signature, which is computed over the decoded resource path.
// So such blobs are identified and skipped with a clear warning instead of failing with an
// opaque 400/404 from somewhere deep in the connector. See the README's "Blob name
// limitations".
isolated function isAddressableBlobName(string blobName) returns boolean {
    // `?` fails exactly as `#` does: unencoded, it starts the query string, so the path is
    // truncated at it — and under SAS auth the appended token merges into the query the name
    // just opened, corrupting both.
    if blobName.includes("#") || blobName.includes("%") || blobName.includes("?") {
        return false;
    }
    // Any code point above U+007F is non-ASCII. `blobName.toBytes()` is UTF-8, so a name that
    // is pure ASCII has exactly as many bytes as code points.
    return blobName.toBytes().length() == blobName.length();
}

// Parses a numeric header value (e.g. `Content-Length`) as a `decimal`, or `()` when the
// value is absent or not a number.
isolated function decimalFromString(string? value) returns decimal? {
    if value is () {
        return ();
    }
    decimal|error parsed = decimal:fromString(value.trim());
    return parsed is decimal ? parsed : ();
}

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// MIME types whose content is markup, decoded and then rendered to plain text. Matched before
// the generic `text/` rule, which `text/html` would otherwise satisfy.
final readonly & string[] MARKUP_MIME_TYPES = [
    "text/html",
    "application/xhtml+xml"
];

// File extensions whose content is markup, used only when the Content-Type is missing or
// unrecognised.
final readonly & string[] MARKUP_EXTENSIONS = ["html", "htm", "xhtml"];

// File extensions treated as text, used only when the Content-Type is missing or unrecognised.
//
// `ts` is deliberately absent: it is TypeScript source *and* an MPEG transport stream, and a
// video misread as text would be downloaded in full only to produce a document of binary
// garbage. TypeScript is not lost where it is typed correctly — a `.ts` blob served as
// `text/plain` (or any `text/*`) still classifies as text through the MIME branch, which
// `classify` evaluates first.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js"
];

// MIME types whose text is extracted via Apache Tika: PDF (PDFBox) and Microsoft
// Office documents (POI, via the `tika-parser-microsoft-module`).
final readonly & string[] EXTRACTABLE_MIME_TYPES = [
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
];

// File extensions whose text is extracted via Apache Tika: PDF and Microsoft Office.
final readonly & string[] EXTRACTABLE_EXTENSIONS = [
    "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"
];
