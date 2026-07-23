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

// How a file's content is turned into text, derived from its MIME type / extension.
enum DocumentKind {
    // Inherently textual; decoded directly from its bytes.
    PLAIN_TEXT,
    // A PDF or Microsoft Office document whose text is extracted via Apache Tika
    // (PDFBox for PDF, Apache POI for Office).
    EXTRACTABLE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

// Builds an `ai:TextDocument` from downloaded blob content, extracting the text of PDF
// and Microsoft Office documents via Apache Tika. Returns `()` for content that cannot be
// represented as text (images, audio, unknown binary), signalling the caller to skip.
isolated function buildDocument(byte[] content, string fileName, string? mimeType, decimal? fileSize,
        string? createdDateTime, string? modifiedDateTime) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName};
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    if fileSize is decimal {
        metadata.fileSize = fileSize;
    }
    time:Utc? createdAt = toUtc(createdDateTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(modifiedDateTime);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }

    match classify(fileName, mimeType) {
        PLAIN_TEXT => {
            string|error text = string:fromBytes(content);
            if text is error {
                return error ai:Error(
                    string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        EXTRACTABLE => {
            string|error text = extractText(content, fileName, mimeType ?: "");
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
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

// Classifies a file by how its text is obtained, using MIME type then extension.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = (mimeType ?: "").toLowerAscii();
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    // PDF and Microsoft Office documents are extracted via Apache Tika (PDFBox / POI).
    if (mime != "" && EXTRACTABLE_MIME_TYPES.indexOf(mime) !is ())
            || EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACTABLE;
    }
    return UNSUPPORTED;
}

// Returns the lower-cased file extension (without the dot), or `""` if none.
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
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

// Removes duplicate strings, preserving first-appearance order (used to de-dup container
// names returned by a paginated `listContainers`).
isolated function dedupeStrings(string[] values) returns string[] {
    string[] result = [];
    map<boolean> seen = {};
    foreach string value in values {
        if !seen.hasKey(value) {
            seen[value] = true;
            result.push(value);
        }
    }
    return result;
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
isolated function isDirectChild(string blobName, string prefix) returns boolean {
    if blobName.length() < prefix.length() {
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

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// File extensions treated as text.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
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
