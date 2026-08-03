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

// An in-memory Azure Blob Storage account standing in for the connector, so the loader's whole
// load path can be exercised offline. It is a fake, not a stub: it models the behaviours the
// loader actually depends on, and each is a behaviour the loader would get wrong if the fake
// simply returned canned data.
//
// - **Flat namespace.** Containers hold a flat set of blobs; "folders" exist only as `/` in
//   blob names. A prefix listing returns matches at EVERY depth, because Azure's List Blobs is
//   called here without a delimiter — which is exactly why the loader needs `isDirectChild`.
// - **`NextMarker` pagination.** Both listings page at `pageSize`, so a walk that stops after
//   the first page is visibly wrong rather than accidentally correct on small fixtures.
// - **404s.** A missing container or blob raises a `blobs:ServerError` with `httpStatus: 404`,
//   the shape `isNotFoundError` reads.
// - **Per-blob download failures**, so the skip-don't-abort walk can be driven.
//
// It also counts downloads, which is how "an unsupported blob is never fetched" is asserted:
// no assertion on the returned documents can distinguish skipping-before-fetch from
// fetching-then-discarding.

import ballerina/ai;
import ballerina/test;
import ballerinax/azure_storage_service.blobs;

// One blob in the fake account.
type MockBlob record {|
    string container;
    # The full blob name, `/`-separated for virtual folders (e.g. `reports/2026/q1.pdf`).
    string name;
    # The `Content-Type` Azure reports in listings; `()` models a blob stored without one.
    string? contentType = ();
    byte[] content = [];
    # When set, `getBlob` fails with this message. Models a per-blob failure (a 403 on one blob,
    # an archived tier, a body over the response-size cap) without any transport involved.
    string? downloadError = ();
|};

isolated client class MockBlobStore {
    *BlobStore;

    private final readonly & MockBlob[] blobs;
    private final readonly & string[] containers;
    private final int pageSize;
    private final boolean stickyMarker;

    // Every blob name passed to `getBlob`, in call order. Mutable, hence the lock.
    private string[] fetched = [];

    // + blobs - the account's contents
    // + containers - container names, in listing order. Defaults to those the blobs imply, in
    //                first-appearance order; give it explicitly to include an EMPTY container
    // + pageSize - blobs (and containers) per page, driving `NextMarker` pagination
    // + stickyMarker - when true, every page returns the FIRST page's marker instead of
    //                  advancing. Models a service or proxy whose cursor never moves, which
    //                  would spin the loader's `while true` forever
    isolated function init(MockBlob[] blobs, string[]? containers = (), int pageSize = 1000,
            boolean stickyMarker = false) {
        self.blobs = blobs.cloneReadOnly();
        self.containers = (containers ?: containersOf(blobs)).cloneReadOnly();
        self.pageSize = pageSize;
        self.stickyMarker = stickyMarker;
    }

    isolated remote function listContainers(string? marker) returns blobs:ListContainerResult|error {
        int[] window = check pageWindow(marker, self.containers.length(), self.pageSize);
        blobs:Container[] page = [];
        foreach int i in window[0] ..< window[1] {
            page.push({Name: self.containers[i], Properties: {}});
        }
        return {
            containerList: page,
            nextMarker: self.markerFor(window[1], self.containers.length()),
            responseHeaders: emptyHeaders()
        };
    }

    isolated remote function listBlobs(string container, string? marker, string? prefix)
            returns blobs:ListBlobResult|error {
        if self.containers.indexOf(container) is () {
            return containerNotFound(container);
        }
        // No delimiter: a prefix listing matches at every depth beneath it.
        MockBlob[] matching = from MockBlob blob in self.blobs
            where blob.container == container && (prefix is () || blob.name.startsWith(prefix))
            select blob;
        int[] window = check pageWindow(marker, matching.length(), self.pageSize);
        blobs:Blob[] page = [];
        foreach int i in window[0] ..< window[1] {
            page.push(toConnectorBlob(matching[i]));
        }
        return {
            blobList: page,
            nextMarker: self.markerFor(window[1], matching.length()),
            responseHeaders: emptyHeaders()
        };
    }

    // `""` ends pagination, exactly as Azure signals the last page. Under `stickyMarker` the
    // cursor is pinned to the end of the first page, so it never advances and never terminates.
    private isolated function markerFor(int end, int total) returns string {
        if end >= total {
            return "";
        }
        return self.stickyMarker ? self.pageSize.toString() : end.toString();
    }

    isolated remote function getBlobProperties(string container, string blobName)
            returns blobs:ResponseHeaders|error {
        MockBlob? blob = self.find(container, blobName);
        if blob is () {
            // NOT a `blobs:ServerError`. `getBlobProperties` is an HTTP HEAD, so the 404 has no
            // XML body, and the connector's `handleResponse` falls to its untyped branch —
            // a bare `error` whose message is a fixed constant, with the status text buried in
            // the detail. Modelling this faithfully is the whole point: a friendlier fake here
            // hid a real defect in `isNotFoundError`.
            return headNotFound(container, blobName);
        }
        blobs:ResponseHeaders headers = emptyHeaders();
        headers["Content-Length"] = blob.content.length().toString();
        headers["Last-Modified"] = MOCK_LAST_MODIFIED;
        headers["x-ms-creation-time"] = MOCK_CREATION_TIME;
        string? contentType = blob.contentType;
        if contentType is string {
            headers["Content-Type"] = contentType;
        }
        return headers;
    }

    isolated remote function getBlob(string container, string blobName) returns blobs:BlobResult|error {
        lock {
            self.fetched.push(blobName);
        }
        MockBlob? blob = self.find(container, blobName);
        if blob is () {
            return blobNotFound(container, blobName);
        }
        string? downloadError = blob.downloadError;
        if downloadError is string {
            return error blobs:ServerError(downloadError,
                    httpStatus = 403, errorCode = "AuthorizationFailure", message = downloadError);
        }
        blobs:Properties properties = {};
        string? contentType = blob.contentType;
        if contentType is string {
            properties.blobContentType = contentType;
        }
        return {blobContent: blob.content, properties, responseHeaders: emptyHeaders()};
    }

    // The blob names `getBlob` was called with, in order — the evidence for what was and was
    // not downloaded.
    isolated function fetchedNames() returns string[] {
        lock {
            return self.fetched.clone();
        }
    }

    isolated function fetchCount() returns int {
        lock {
            return self.fetched.length();
        }
    }

    private isolated function find(string container, string blobName) returns MockBlob? {
        foreach MockBlob blob in self.blobs {
            if blob.container == container && blob.name == blobName {
                return blob;
            }
        }
        return ();
    }
}

// Azure reports these in RFC 1123, which `time:utcFromString` rejects — see the `toUtc` note.
// Kept in that form deliberately so the fixtures do not imply a parsing behaviour the loader
// does not yet have.
const string MOCK_LAST_MODIFIED = "Thu, 10 Mar 2022 11:00:00 GMT";
const string MOCK_CREATION_TIME = "Wed, 09 Mar 2022 10:00:00 GMT";

// Container names implied by the blobs, in first-appearance order.
isolated function containersOf(MockBlob[] blobs) returns string[] {
    string[] names = [];
    foreach MockBlob blob in blobs {
        if names.indexOf(blob.container) is () {
            names.push(blob.container);
        }
    }
    return names;
}

// Resolves a `NextMarker` cursor to a `[start, end)` window. The marker is the index the last
// page stopped at, matching how the loader feeds `nextMarker` straight back.
isolated function pageWindow(string? marker, int total, int pageSize) returns int[]|error {
    int 'start = marker is string ? check int:fromString(marker) : 0;
    if 'start < 0 || 'start > total {
        return error(string `The mock store received an out-of-range marker '${marker ?: ""}'`);
    }
    int end = 'start + pageSize;
    return ['start, end > total ? total : end];
}

isolated function toConnectorBlob(MockBlob blob) returns blobs:Blob {
    map<json> properties = {
        "Content-Length": blob.content.length(),
        "Creation-Time": MOCK_CREATION_TIME,
        "Last-Modified": MOCK_LAST_MODIFIED
    };
    string? contentType = blob.contentType;
    if contentType is string {
        properties["Content-Type"] = contentType;
    }
    return {Name: blob.name, Properties: properties};
}

isolated function emptyHeaders() returns blobs:ResponseHeaders =>
    {Date: MOCK_LAST_MODIFIED, x\-ms\-version: "2019-12-12", x\-ms\-request\-id: "mock-request"};

isolated function containerNotFound(string container) returns blobs:ServerError =>
    error("The specified container does not exist.", httpStatus = 404,
            errorCode = "ContainerNotFound",
            message = string `The specified container '${container}' does not exist.`);

// The 404 the connector produces for a HEAD request (`getBlobProperties`). Azure returns no
// body on a HEAD, so `handleResponse` cannot build a typed `ServerError` and instead returns
// `error(AZURE_BLOB_ERROR_CODE, message = "Status Code: 404 <reason>")` — meaning `message()`
// is the fixed constant below and the status text is only reachable through `detail()`.
isolated function headNotFound(string container, string blobName) returns error =>
    error(AZURE_BLOB_ERROR_CODE,
            message = string `Status Code: 404 The specified blob does not exist. ` +
                string `(container '${container}', blob '${blobName}')`);

// Mirrors `AZURE_BLOB_ERROR_CODE` in the connector: the literal value its untyped errors carry
// as their message, which is why matching on `message()` alone never sees a status code.
const string AZURE_BLOB_ERROR_CODE = "(ballerinax/azure-storage-service)BlobError";

isolated function blobNotFound(string container, string blobName) returns blobs:ServerError =>
    error("The specified blob does not exist.", httpStatus = 404, errorCode = "BlobNotFound",
            message = string `The blob '${blobName}' does not exist in container '${container}'.`);

// Builds the loader under test over a fake account. Sources go through the real
// `resolveSources`, so normalization and validation are exercised on the way in.
isolated function loaderOver(MockBlobStore store, Source[] sources) returns BlobLoader|error {
    return new (store, check resolveSources(sources));
}

// Runs a load and normalizes the single-document collapse away, so a test that cares about
// contents does not also have to care about arity. Tests that DO care assert on `load()`
// directly (see `testLoadCollapsesASingleDocument`).
isolated function loadAll(MockBlobStore store, Source[] sources) returns ai:Document[]|error {
    BlobLoader loader = check loaderOver(store, sources);
    ai:Document[]|ai:Document result = check loader.load();
    return result is ai:Document[] ? result : [result];
}

// The `fileName` of each loaded document, in load order.
isolated function loadedNames(ai:Document[] documents) returns string[] {
    string[] names = [];
    foreach ai:Document document in documents {
        names.push(document.metadata?.fileName ?: "<unnamed>");
    }
    return names;
}

// Asserts a set of loaded names irrespective of order, with a readable message on failure.
isolated function assertLoaded(ai:Document[] documents, string[] expected, string message) {
    string[] actual = loadedNames(documents).sort();
    test:assertEquals(actual, expected.sort(), message);
}
