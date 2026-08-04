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
import ballerina/log;
import ballerinax/azure_storage_service.blobs;

# A data loader that retrieves documents from Azure Blob Storage containers as text.
#
# Inherently textual blobs (`txt`, `md`, `json`, `csv`, …) are decoded from their bytes; PDFs
# and Microsoft Office documents have their text extracted via Apache Tika. See the module
# documentation for the container/prefix model and the supported and unsupported blob types.
@display {
    label: "Azure Blob Storage Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    // The public class is a thin shell over `BlobLoader`, which holds every piece of load logic
    // and talks to a `BlobStore` rather than to `blobs:BlobClient` directly. That split is what
    // makes the load path testable: a test constructs a `BlobLoader` over a fake store, while
    // this class's public surface — and the connector types in it — stay exactly as documented.
    private final BlobLoader loader;

    # Initializes the Azure Blob Storage data loader.
    #
    # The connection may be given in either of two forms:
    #
    # - a `blobs:ConnectionConfig` (Shared Key or SAS) — the loader constructs and owns its own
    #   connector client, filling in a retry policy and a response-size cap when the caller set
    #   neither; or
    # - an already-constructed `blobs:BlobClient` — the loader reuses it, so a caller that
    #   already talks to the storage account does not pay for a second HTTP connection pool.
    #
    # A caller-supplied client is **not owned** by the loader: the loader never closes or
    # reconfigures it, and the caller remains responsible for its lifecycle — including the
    # retry and response-limit settings, which are left exactly as the caller configured them.
    #
    # Every source is fully validated and normalized here rather than at load time, so a
    # misconfigured source fails immediately instead of part-way through a long load, after
    # documents have already been fetched and then discarded.
    #
    # + azureConnection - The Azure Blob Storage connector configuration shared by all sources, or
    #                     an existing `blobs:BlobClient` to reuse (not owned by the loader)
    # + sources - One or more Azure Blob containers to load documents from
    # + return - An `ai:Error` if the loader could not be initialized or a source is invalid
    public isolated function init(
            @display {label: "Azure Connection"} blobs:ConnectionConfig|blobs:BlobClient azureConnection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        // Sources are validated before the connection is resolved, so a misconfigured source
        // fails identically for both connection forms.
        ResolvedSource[] resolved = check resolveSources(sources);
        blobs:BlobClient blobClient = azureConnection is blobs:BlobClient
            ? azureConnection
            : check newBlobClient(azureConnection);
        self.loader = new (new ConnectorBlobStore(blobClient), resolved);
    }

    # Loads the configured Azure Blob Storage documents.
    #
    # + return - The loaded document when a single blob is resolved, an array of documents
    #            otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error => self.loader.load();
}

// Validates and normalizes the configured sources up front, so a misconfigured source fails at
// `init` rather than part-way through a long load, after documents have already been fetched
// and then discarded.
isolated function resolveSources(Source[] sources) returns ResolvedSource[]|ai:Error {
    if sources.length() == 0 {
        return error ai:Error("At least one source must be provided to the Azure Blob Storage data loader");
    }
    ResolvedSource[] resolved = [];
    foreach Source src in sources {
        string container = src.container.trim();
        if container == "" {
            return error ai:Error("A source container name must not be empty");
        }
        // A source that names no path loads nothing. Silently returning zero documents here
        // while an empty `sources` array is a hard error would give the caller the same
        // outcome from a clear failure in one case and total silence in the other.
        if src.paths.length() == 0 {
            log:printWarn("An Azure Blob Storage source selects no paths and will load no " +
                    "documents; set 'paths' (it defaults to [\"/\"], the whole container)",
                    container = container);
        }
        string[] paths = [];
        foreach string rawPath in src.paths {
            string path = normalizeBlobPath(rawPath);
            // UPSTREAM (see `isAddressableBlobName`): the connector percent-encodes neither
            // the request path nor the `prefix` query parameter, so such a path cannot be
            // requested at all. Rejected here rather than at load time, because a configured
            // path is a deliberate choice and the resulting 400 would name nothing useful.
            if !isAddressableBlobName(path) {
                return error ai:Error(string `The path '${rawPath}' cannot be used: the Azure ` +
                    string `Storage connector does not percent-encode request paths, so blob ` +
                    string `names and prefixes containing '#', '?', '%' or non-ASCII characters ` +
                    string `are not addressable`);
            }
            paths.push(path);
        }
        resolved.push({
            container,
            paths,
            recursive: src.recursive,
            includeExtensions: src?.includeExtensions,
            // The `"*"` container applies the same paths to every container in the account,
            // where a path need not exist in all of them.
            tolerateMissing: container == "*"
        });
    }
    return resolved;
}

// The loader's whole load path, expressed against the `BlobStore` seam rather than the
// connector client. `TextDataLoader` wraps this with the production store; tests wrap it with a
// fake one.
isolated class BlobLoader {
    private final BlobStore store;
    private final readonly & ResolvedSource[] sources;

    isolated function init(BlobStore store, ResolvedSource[] sources) {
        self.store = store;
        self.sources = sources.cloneReadOnly();
    }

    isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        // Sources may overlap — `paths: ["/", "/reports"]`, the same container named twice, or
        // a container reached both directly and through `"*"`. Without this, the same blob
        // becomes two documents and is duplicated in whatever index the caller builds, having
        // been downloaded twice to get there. Shared across the whole load, so it de-duplicates
        // between sources, not just within one.
        map<boolean> seen = {};
        // Sources arrive already normalized and validated (see `init`), so the load path cannot
        // fail on a configuration mistake half-way through.
        foreach ResolvedSource src in self.sources {
            string[] containers = check self.resolveContainers(src.container);
            foreach string container in containers {
                foreach string path in src.paths {
                    ai:Document[] loaded = check self.loadPath(container, path, src.recursive,
                            src.includeExtensions, src.tolerateMissing, seen);
                    documents.push(...loaded);
                }
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Resolves the container names to read from: the single named container, or every
    // container in the account (paginated) when `"*"`.
    private isolated function resolveContainers(string container) returns string[]|ai:Error {
        if container != "*" {
            return [container];
        }
        string[] names = [];
        string? marker = ();
        int pages = 0;
        while true {
            blobs:ListContainerResult|error result = self.store->listContainers(marker);
            if result is error {
                return error ai:Error(string `Failed to list containers: ${result.message()}`, result);
            }
            foreach blobs:Container resolved in result.containerList {
                names.push(resolved.Name);
            }
            pages += 1;
            check guardPagination(result.nextMarker, marker, pages, "the container listing");
            if result.nextMarker == "" {
                break;
            }
            marker = result.nextMarker;
        }
        return dedupeStrings(names);
    }

    // Loads a single normalized path. An empty path (the container root) or one ending in `/`
    // is a folder prefix. Any other path is first probed as an explicitly named blob; if no
    // such blob exists it is treated as a folder prefix, unless it looks like a file (has an
    // extension), in which case a missing blob is an error (typo detection) — except under
    // `tolerateMissing` (the `"*"` case), where it is skipped.
    private isolated function loadPath(string container, string path, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing, map<boolean> seen)
            returns ai:Document[]|ai:Error {
        if path == "" || path.endsWith("/") {
            return self.listPrefix(container, path, recursive, includeExtensions, tolerateMissing, seen);
        }

        // Ambiguous file-or-folder path. The probe is a HEAD (`getBlobProperties`), not a GET:
        // it settles existence and yields the metadata needed to classify the blob without
        // downloading a single byte of a blob that may turn out to be an unsupported type.
        blobs:ResponseHeaders|error properties = self.store->getBlobProperties(container, path);
        if properties is blobs:ResponseHeaders {
            // Already loaded through another source or path: skip before downloading it again.
            if !markSeen(seen, container, path) {
                return [];
            }
            ai:TextDocument document = check self.loadNamedBlob(container, entryFromHeaders(path, properties));
            return [document];
        }
        if !isNotFoundError(properties) {
            return error ai:Error(string `Failed to load path '${path}' from container ` +
                string `'${container}': ${properties.message()}`, properties);
        }
        // No exact blob. If the path looks like a file, a missing blob is an error (unless
        // tolerated); otherwise treat it as a folder prefix and list it.
        if getExtension(path) != "" {
            if tolerateMissing {
                return [];
            }
            return error ai:Error(
                string `Failed to load path '${path}' from container '${container}': blob not found`);
        }
        return self.listPrefix(container, path + "/", recursive, includeExtensions, tolerateMissing, seen);
    }

    // Loads a single explicitly named blob. Unlike a blob discovered in a prefix listing, a
    // deliberately named non-text blob is an ERROR (typo/intent detection), not a silent skip —
    // and so is a named scanned (image-only) PDF, whose descriptive extraction error is
    // surfaced to the caller.
    //
    // The extension filter is deliberately not applied: naming a blob expresses intent.
    private isolated function loadNamedBlob(string container, BlobEntry entry)
            returns ai:TextDocument|ai:Error {
        DocumentKind kind = classify(entry.name, entry.contentType);
        if !isSupported(kind) {
            return error ai:Error(string `Unsupported (non-text) file type for path '${entry.name}' ` +
                string `in container '${container}' (content type '${entry.contentType ?: "unknown"}')`);
        }
        return self.fetchAndBuild(container, entry, kind);
    }

    // Lists every blob under a prefix and converts the supported ones into documents. Under
    // `recursive`, blobs at any depth are included; otherwise only those directly under the
    // prefix.
    //
    // Every per-blob failure inside a listing is skipped with a logged warning, never
    // propagated: one unreadable blob must not discard the documents already collected, nor
    // abandon the rest of the container. A single non-UTF-8 `.txt`, one corrupt PDF, or one
    // 403 on one blob would otherwise throw away an entire bulk ingestion.
    //
    // An explicitly named blob (`loadNamedBlob`) still errors — naming a blob expresses intent,
    // so failing to load it is a mistake worth reporting rather than a silent skip.
    //
    // Each listing page is filtered and converted as it arrives, rather than the whole listing
    // being accumulated first: `MAX_LISTING_PAGES` allows 10 000 pages, which at Azure's page
    // size is 50 million entries, and most of them are typically discarded by the filters below.
    // Only one page of listing metadata is ever resident.
    private isolated function listPrefix(string container, string prefix, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing, map<boolean> seen)
            returns ai:Document[]|ai:Error {
        ai:Document[] documents = [];
        int skipped = 0;
        string? prefixArg = prefix == "" ? () : prefix;
        string? marker = ();
        int pages = 0;
        while true {
            blobs:ListBlobResult|error result = self.store->listBlobs(container, marker, prefixArg);
            if result is error {
                if tolerateMissing && isNotFoundError(result) {
                    return documents;
                }
                return error ai:Error(string `Failed to list blobs under prefix '${prefix}' in ` +
                    string `container '${container}': ${result.message()}`, result);
            }
            skipped += self.collectPage(container, prefix, recursive, includeExtensions, seen,
                    result.blobList, documents);
            pages += 1;
            check guardPagination(result.nextMarker, marker,
                    pages, string `the listing of prefix '${prefix}' in container '${container}'`);
            if result.nextMarker == "" {
                break;
            }
            marker = result.nextMarker;
        }

        // A prefix where everything was skipped otherwise looks identical to an empty one: the
        // caller gets an empty array and would have to read the logs line by line to tell the
        // difference. Summarise it once instead.
        if skipped > 0 {
            log:printWarn("Some Azure Blob Storage files under this prefix were skipped",
                    container = container, prefix = prefix, loaded = documents.length(), skipped = skipped);
        }
        return documents;
    }

    // Filters one listing page and appends the documents it yields to `documents`, returning
    // how many of its entries were skipped. Split out of `listPrefix` so that the page walk
    // stays readable and no page is retained beyond this call.
    private isolated function collectPage(string container, string prefix, boolean recursive,
            string[]? includeExtensions, map<boolean> seen, blobs:Blob[] page,
            ai:Document[] documents) returns int {
        int skipped = 0;
        foreach blobs:Blob blob in page {
            BlobEntry entry = toBlobEntry(blob);
            string name = entry.name;
            // Some tools create zero-length "folder marker" blobs whose name ends with `/`.
            if name.endsWith("/") {
                continue;
            }
            // Non-recursive: keep only blobs directly under the prefix (no further `/`).
            if !recursive && !isDirectChild(name, prefix) {
                continue;
            }
            if !matchesExtensionFilter(name, includeExtensions) {
                continue;
            }
            // UPSTREAM (see `isAddressableBlobName`): the connector cannot build a valid
            // request path for a name containing `#`, `?`, `%`, or non-ASCII. Naming the real
            // problem here beats letting it surface as an opaque 400, or — for `#` and `?` — as
            // a successful download of the WRONG blob, which no error would ever reveal.
            if !isAddressableBlobName(name) {
                log:printWarn("Skipping an Azure Blob Storage file whose name cannot be addressed " +
                        "by the connector: names containing '#', '?', '%' or non-ASCII characters " +
                        "are not percent-encoded in the request path",
                        fileName = name, container = container);
                skipped += 1;
                continue;
            }
            // Already loaded through an overlapping source or path. Checked before the download,
            // so a duplicate costs nothing rather than being fetched and then discarded.
            if !markSeen(seen, container, name) {
                continue;
            }
            // Classified from the LISTING metadata, before any download: Azure reports a real
            // `Content-Type` per blob, so an image or an archive is skipped without spending
            // the bandwidth to fetch it first.
            DocumentKind kind = classify(name, entry.contentType);
            if !isSupported(kind) {
                log:printWarn("Skipping a non-text Azure Blob Storage file", fileName = name,
                        container = container, contentType = entry.contentType ?: "unknown");
                skipped += 1;
                continue;
            }
            ai:TextDocument|ai:Error document = self.fetchAndBuild(container, entry, kind);
            if document is ai:Error {
                if isScannedPdfError(document) {
                    log:printWarn("Skipping a scanned (image-only) PDF: it has no extractable " +
                            "text layer, and OCR is not supported", fileName = name, container = container);
                } else {
                    // Any reason at all: content that will not decode, a corrupt Office file, a
                    // blob above the response-size cap, a 403 on this one blob. The walk
                    // continues either way.
                    log:printWarn("Skipping an Azure Blob Storage file that could not be loaded",
                            fileName = name, container = container, reason = document.message());
                }
                skipped += 1;
                continue;
            }
            documents.push(document);
        }
        return skipped;
    }

    // Downloads a blob's content and converts it into an `ai:TextDocument`. Only ever called
    // for a supported kind (see `isSupported`), so the download is never wasted on a blob that
    // cannot become text. Metadata from the listing (or HEAD) entry is preferred; content type
    // and size fall back to the download response.
    private isolated function fetchAndBuild(string container, BlobEntry entry, DocumentKind kind)
            returns ai:TextDocument|ai:Error {
        blobs:BlobResult|error blob = self.store->getBlob(container, entry.name);
        if blob is error {
            return error ai:Error(string `Failed to download blob '${entry.name}' from container ` +
                string `'${container}': ${blob.message()}`, blob);
        }
        BlobEntry enriched = {
            name: entry.name,
            contentType: entry.contentType ?: blob.properties?.blobContentType,
            contentLength: entry.contentLength ?: <decimal>blob.blobContent.length(),
            creationTime: entry.creationTime,
            lastModified: entry.lastModified
        };
        return buildDocument(blob.blobContent, kind, buildMetadata(enriched, container));
    }
}

// The hard ceiling on how many pages a single listing may walk. At Azure's default of 5000
// blobs per page this is 50 million blobs — far beyond any load that would finish anyway, so
// reaching it means the cursor is not advancing rather than that the container is genuinely
// that large.
const int MAX_LISTING_PAGES = 10000;

// Guards a `NextMarker` walk against never terminating.
//
// Azure ends a listing with an empty `NextMarker`. A service or proxy that echoed the previous
// marker back instead would spin `while true` forever, holding every page fetched so far in
// memory. Both conditions are reported as errors rather than quietly breaking out: a truncated
// listing that looks like a successful load is worse than a failed one, because the missing
// blobs silently never reach the caller's index.
isolated function guardPagination(string nextMarker, string? previousMarker, int pages,
        string description) returns ai:Error? {
    if nextMarker != "" && previousMarker is string && nextMarker == previousMarker {
        return error ai:Error(string `Pagination of ${description} is not advancing: the ` +
            string `service returned the same marker twice ('${nextMarker}')`);
    }
    if pages >= MAX_LISTING_PAGES {
        return error ai:Error(string `Pagination of ${description} exceeded ` +
            string `${MAX_LISTING_PAGES} pages and was abandoned`);
    }
    return ();
}

// Records a blob as loaded, returning `false` when it had already been seen.
//
// The key is `container + "/" + blobName`, which is unique across a storage account. Sources
// overlap easily — `paths: ["/", "/reports"]`, the same container listed twice, or a container
// reached both directly and through `"*"` — and without this the same blob becomes two
// identical documents, duplicating it in whatever index the caller builds.
isolated function markSeen(map<boolean> seen, string container, string blobName) returns boolean {
    string key = container + "/" + blobName;
    if seen.hasKey(key) {
        return false;
    }
    seen[key] = true;
    return true;
}

// Builds a normalized `BlobEntry` from a connector `Blob`, reading the metadata this loader
// uses out of the blob's untyped `Properties` map.
isolated function toBlobEntry(blobs:Blob blob) returns BlobEntry {
    map<json> properties = blob.Properties;
    return {
        name: blob.Name,
        contentType: propString(properties, "Content-Type"),
        contentLength: propDecimal(properties, "Content-Length"),
        creationTime: propString(properties, "Creation-Time"),
        lastModified: propString(properties, "Last-Modified")
    };
}

// Builds a `BlobEntry` from the response headers of a `getBlobProperties` (HEAD) probe, so an
// explicitly named blob is classified from the same shape as a listed one. Azure returns the
// creation time as the `x-ms-creation-time` header rather than the `Creation-Time` name used
// in the List Blobs XML.
isolated function entryFromHeaders(string blobName, blobs:ResponseHeaders headers) returns BlobEntry => {
    name: blobName,
    contentType: headerValue(headers, "Content-Type"),
    contentLength: decimalFromString(headerValue(headers, "Content-Length")),
    creationTime: headerValue(headers, "x-ms-creation-time"),
    lastModified: headerValue(headers, "Last-Modified")
};

// Reads a header case-insensitively out of the connector's open `ResponseHeaders` record,
// returning `()` for a missing or blank value. HTTP header names are case-insensitive and
// nothing in the connector normalizes their casing, so an exact-key lookup is not safe.
isolated function headerValue(blobs:ResponseHeaders headers, string name) returns string? {
    map<anydata> entries = headers;
    string wanted = name.toLowerAscii();
    foreach var [key, value] in entries.entries() {
        if key.toLowerAscii() == wanted && value is string {
            // The trimmed value is what is returned, not just what is tested: `classify` and
            // `decimalFromString` must see the same string the blankness check judged.
            string trimmed = value.trim();
            if trimmed != "" {
                return trimmed;
            }
        }
    }
    return ();
}

// Reports whether a connector error represents a 404 (blob or container not found), used to
// disambiguate file-vs-folder paths and to honour `tolerateMissing`.
isolated function isNotFoundError(error e) returns boolean {
    // A `blobs:ServerError` carries the status and the Azure error code as typed fields, so it
    // ANSWERS THE QUESTION on its own — no message heuristic runs against it. Falling through
    // to the text match would let a 500 whose body happens to say "not found" be treated as a
    // missing blob, which under `tolerateMissing` silently drops a container that was really
    // erroring. The heuristics below exist only for errors that carry no status at all.
    if e is blobs:ServerError {
        blobs:ServerErrorDetail detail = e.detail();
        return detail.httpStatus == 404 || detail.errorCode.toLowerAscii().includes("notfound");
    }
    // A 404 also arrives as an untyped error, whose own message is only the fixed wrapper
    // "(ballerinax/azure-storage-service)BlobError" — the status text ("Status Code: 404 The
    // specified blob does not exist.") sits in the `message` field of its detail, so both that
    // and the cause chain have to be inspected.
    if isNotFoundText(e.message()) {
        return true;
    }
    anydata|readonly detailMessage = e.detail()["message"];
    if detailMessage is string && isNotFoundText(detailMessage) {
        return true;
    }
    error? cause = e.cause();
    return cause is error && isNotFoundError(cause);
}

// Reports whether connector error text denotes a 404, across the wordings the connector and
// the Azure REST API use. Deliberately avoids matching a bare "404", which would misfire on
// a blob whose own name contains it.
isolated function isNotFoundText(string text) returns boolean {
    string message = text.toLowerAscii();
    return message.includes("not found") || message.includes("notfound")
            || message.includes("does not exist")
            || message.includes("status code: 404") || message.includes("status code '404'")
            || message.includes("status: 404");
}
