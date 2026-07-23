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
@display {
    label: "Azure Blob Storage Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final blobs:BlobClient blobClient;
    private final readonly & Source[] sources;

    # Initializes the Azure Blob Storage data loader.
    #
    # + connection - The authentication and service configuration shared by all sources, or an
    #                existing `blobs:BlobClient` to reuse. A supplied client is not owned by the
    #                loader: the caller remains responsible for its lifecycle.
    # + sources - One or more Azure Blob containers to load documents from
    # + return - An `ai:Error` if the loader could not be initialized
    public isolated function init(
            @display {label: "Connection"} blobs:ConnectionConfig|blobs:BlobClient connection,
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the Azure Blob Storage data loader");
        }
        self.sources = sources.cloneReadOnly();
        self.blobClient = connection is blobs:BlobClient ? connection : check newBlobClient(connection);
    }

    # Loads the configured Azure Blob Storage documents.
    #
    # + return - The loaded document when a single blob is resolved, an array of documents
    #            otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            string[] containers = check self.resolveContainers(src.container);
            // A `"*"` container applies the paths to every container, where a path need
            // not exist in all of them, so a missing path is tolerated rather than an error.
            boolean tolerateMissing = src.container == "*";
            foreach string container in containers {
                foreach string rawPath in src.paths {
                    ai:Document[] loaded = check self.loadPrefix(container, rawPath,
                            src.recursive, src.includeExtensions, tolerateMissing);
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
        while true {
            blobs:ListContainerResult|error result = self.blobClient->listContainers((), marker, ());
            if result is error {
                return error ai:Error(string `Failed to list containers: ${result.message()}`, result);
            }
            foreach blobs:Container resolved in result.containerList {
                names.push(resolved.Name);
            }
            if result.nextMarker == "" {
                break;
            }
            marker = result.nextMarker;
        }
        return dedupeStrings(names);
    }

    // Loads a single configured path. A path with a trailing `/` (or the container root) is
    // treated as a folder prefix. A path without one is first tried as an explicitly named
    // blob; if no such blob exists it is treated as a folder prefix, unless it looks like a
    // file (has an extension), in which case a missing blob is an error (typo detection) —
    // except under `tolerateMissing` (the `"*"` case), where it is skipped.
    private isolated function loadPrefix(string container, string rawPath, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing) returns ai:Document[]|ai:Error {
        string normalized = normalizeBlobPath(rawPath);
        if normalized == "" || normalized.endsWith("/") {
            return self.listPrefix(container, normalized, recursive, includeExtensions, tolerateMissing);
        }

        // Ambiguous file-or-folder path: probe for an exact blob first.
        blobs:BlobResult|error blob = self.blobClient->getBlob(container, normalized, ());
        if blob is blobs:BlobResult {
            // An explicitly named blob is always loaded, regardless of the extension filter.
            // A deliberately named non-text blob is an error, unlike folder contents; a named
            // scanned (image-only) PDF surfaces the descriptive error from `buildDocument`.
            string? contentType = blob.properties?.blobContentType;
            ai:TextDocument? document = check buildDocument(blob.blobContent, normalized, contentType,
                    <decimal>blob.blobContent.length(), (), ());
            if document is () {
                return error ai:Error(string `Unsupported (non-text) file type for path '${rawPath}'`);
            }
            return [document];
        }
        if !isNotFoundError(blob) {
            return error ai:Error(
                string `Failed to load path '${rawPath}' from container '${container}': ${blob.message()}`, blob);
        }
        // No exact blob. If the path looks like a file, a missing blob is an error (unless
        // tolerated); otherwise treat it as a folder prefix and list it.
        if getExtension(normalized) != "" {
            if tolerateMissing {
                return [];
            }
            return error ai:Error(
                string `Failed to load path '${rawPath}' from container '${container}': blob not found`);
        }
        return self.listPrefix(container, normalized + "/", recursive, includeExtensions, tolerateMissing);
    }

    // Lists every blob under a prefix and converts the text/PDF/Office ones into documents.
    // Under `recursive`, blobs at any depth are included; otherwise only those directly under
    // the prefix. Unsupported blobs (and scanned image-only PDFs) are skipped with a warning
    // (never an error inside a listing).
    private isolated function listPrefix(string container, string prefix, boolean recursive,
            string[]? includeExtensions, boolean tolerateMissing) returns ai:Document[]|ai:Error {
        blobs:Blob[]|error blobList = self.listAllBlobs(container, prefix);
        if blobList is error {
            if tolerateMissing && isNotFoundError(blobList) {
                return [];
            }
            return error ai:Error(string `Failed to list blobs under prefix '${prefix}' in ` +
                string `container '${container}': ${blobList.message()}`, blobList);
        }

        ai:Document[] documents = [];
        foreach blobs:Blob blob in blobList {
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
            ai:TextDocument?|ai:Error document = self.toDocument(container, entry);
            if document is ai:Error {
                // A scanned (image-only) PDF has no text to extract; inside a listing it is
                // skipped like other non-text content rather than aborting the whole walk.
                // (An explicitly named scanned PDF still surfaces this error to the caller.)
                if isScannedPdfError(document) {
                    log:printWarn("Skipping a scanned (image-only) PDF: it has no extractable " +
                            "text layer, and OCR is not supported", fileName = name, container = container);
                    continue;
                }
                return document;
            }
            if document is ai:TextDocument {
                documents.push(document);
            } else {
                log:printWarn("Skipping a non-text Azure Blob Storage file",
                        fileName = name, container = container);
            }
        }
        return documents;
    }

    // Lists all blobs under a prefix, following the `NextMarker` pagination cursor. An empty
    // `prefix` lists the whole container.
    private isolated function listAllBlobs(string container, string prefix) returns blobs:Blob[]|error {
        blobs:Blob[] all = [];
        string? marker = ();
        while true {
            string? prefixArg = prefix == "" ? () : prefix;
            blobs:ListBlobResult result = check self.blobClient->listBlobs(container, (), marker, prefixArg);
            all.push(...result.blobList);
            if result.nextMarker == "" {
                break;
            }
            marker = result.nextMarker;
        }
        return all;
    }

    // Downloads a blob's content and converts it into an `ai:TextDocument`, returning `()`
    // when the blob cannot be represented as text (the caller skips it). Metadata from the
    // listing entry is preferred; content type and size fall back to the download response.
    private isolated function toDocument(string container, BlobEntry entry)
            returns ai:TextDocument?|ai:Error {
        blobs:BlobResult|error blob = self.blobClient->getBlob(container, entry.name, ());
        if blob is error {
            return error ai:Error(
                string `Failed to download blob '${entry.name}' from container '${container}': ${blob.message()}`,
                blob);
        }
        string? contentType = entry.contentType ?: blob.properties?.blobContentType;
        decimal? contentLength = entry.contentLength ?: <decimal>blob.blobContent.length();
        return buildDocument(blob.blobContent, entry.name, contentType, contentLength,
                entry.creationTime, entry.lastModified);
    }
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

// Reports whether a connector error represents a 404 (blob or container not found), used to
// disambiguate file-vs-folder paths and to honour `tolerateMissing`.
isolated function isNotFoundError(error e) returns boolean {
    if e is blobs:ServerError {
        blobs:ServerErrorDetail detail = e.detail();
        if detail.httpStatus == 404 {
            return true;
        }
        if detail.errorCode.toLowerAscii().includes("notfound") {
            return true;
        }
    }
    string message = e.message().toLowerAscii();
    return message.includes("not found") || message.includes("status code '404'")
            || message.includes("status: 404") || message.includes("notfound");
}
