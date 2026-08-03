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
import ballerinax/azure_storage_service.blobs;

// ---- init --------------------------------------------------------------------

// The connector's own config, which the loader consumes directly rather than re-declaring, so
// callers configure auth exactly as they would for `azure_storage_service.blobs`.
final blobs:ConnectionConfig & readonly TEST_CONFIG = {
    accountName: "acct",
    accessKeyOrSAS: "?sv=2022-11-02&sig=abc",
    authorizationMethod: blobs:SAS
};

@test:Config {}
isolated function testInitWithoutSourcesFails() {
    TextDataLoader|ai:Error loader = new (TEST_CONFIG, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
}

@test:Config {}
isolated function testInitWithEmptyContainerFails() {
    TextDataLoader|ai:Error loader = new (TEST_CONFIG, [{container: "  "}]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("container name must not be empty"), loader.message());
    } else {
        test:assertFail("Expected an error when a source container name is blank");
    }
}

@test:Config {}
isolated function testInitWithSourcesSucceeds() returns error? {
    TextDataLoader _ = check new (TEST_CONFIG, [{container: "documents"}]);
}

@test:Config {}
isolated function testInitAcceptsAnExistingClient() returns error? {
    // A caller who already talks to the storage account can hand over their own client rather
    // than paying for a second HTTP connection pool. The loader does not own it.
    blobs:BlobClient existing = check new (TEST_CONFIG);
    TextDataLoader _ = check new (existing, [{container: "documents"}]);
}

@test:Config {}
isolated function testInitValidatesSourcesBeforeResolvingTheConnection() {
    // Source validation runs before the connection is resolved, so it applies identically to
    // both connection forms — an invalid source fails even when a ready-made client is given.
    blobs:BlobClient|error existing = new (TEST_CONFIG);
    if existing is error {
        test:assertFail(existing.message());
    }
    TextDataLoader|ai:Error loader = new (existing, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided, even with a supplied client");
    }
}

@test:Config {}
isolated function testInitAcceptsASourceThatSelectsNothing() returns error? {
    // `paths: []` selects nothing. It is a warning, not an error: unlike an empty `sources`
    // array, it is a legitimate way to disable one source in a list.
    TextDataLoader _ = check new (TEST_CONFIG, [{container: "documents", paths: []}]);
}

// ---- normalizeBlobPath -------------------------------------------------------

@test:Config {}
isolated function testNormalizeBlobPathRoot() {
    test:assertEquals(normalizeBlobPath("/"), "");
    test:assertEquals(normalizeBlobPath(""), "");
    test:assertEquals(normalizeBlobPath("  "), "");
}

@test:Config {}
isolated function testNormalizeBlobPathStripsLeadingSlashKeepsTrailing() {
    test:assertEquals(normalizeBlobPath("/reports"), "reports", "Leading slash dropped");
    test:assertEquals(normalizeBlobPath("reports"), "reports");
    test:assertEquals(normalizeBlobPath("/reports/"), "reports/", "Trailing slash preserved (explicit folder)");
    test:assertEquals(normalizeBlobPath("/reports/2026/q1.pdf"), "reports/2026/q1.pdf");
    test:assertEquals(normalizeBlobPath("  /docs  "), "docs", "Trimmed then normalized");
}

// ---- isDirectChild (non-recursive filter) -----------------------------------

@test:Config {}
isolated function testIsDirectChildRootPrefix() {
    test:assertTrue(isDirectChild("readme.md", ""), "A root-level blob is a direct child of the root");
    test:assertFalse(isDirectChild("sub/a.txt", ""), "A blob in a virtual folder is not a direct child of the root");
}

@test:Config {}
isolated function testIsDirectChildFolderPrefix() {
    test:assertTrue(isDirectChild("reports/q1.pdf", "reports/"), "Directly under the prefix");
    test:assertFalse(isDirectChild("reports/2026/q1.pdf", "reports/"), "In a nested sub-folder");
    test:assertTrue(isDirectChild("reports/", "reports/"), "The prefix marker itself has an empty remainder");
}

@test:Config {}
isolated function testIsDirectChildRequiresThePrefix() {
    // A length-only check would take the remainder from the wrong offset and answer about a
    // substring of an unrelated name. The server-side prefix filter should make this
    // unreachable, so this pins the guard rather than an observed failure.
    test:assertFalse(isDirectChild("archive/q1.pdf", "reports/"),
            "A name that is not under the prefix is not a direct child of it");
    test:assertFalse(isDirectChild("reportsX/q1.pdf", "reports/"),
            "A name sharing only a leading substring is not under the prefix");
    test:assertFalse(isDirectChild("q1.pdf", "reports/"), "A shorter unrelated name is not a child");
}

// ---- dedupeStrings -----------------------------------------------------------

@test:Config {}
isolated function testDedupeStringsPreservesOrder() {
    test:assertEquals(dedupeStrings(["a", "b", "a", "c", "b"]), ["a", "b", "c"]);
    test:assertEquals(dedupeStrings([]), []);
}

// ---- propString / propDecimal ------------------------------------------------

@test:Config {}
isolated function testPropStringReadsValues() {
    map<json> props = {"Content-Type": "application/pdf", "Empty": "", "Last-Modified": "Wed, 09 Mar 2022 10:00:00 GMT"};
    test:assertEquals(propString(props, "Content-Type"), "application/pdf");
    test:assertEquals(propString(props, "Last-Modified"), "Wed, 09 Mar 2022 10:00:00 GMT");
    test:assertTrue(propString(props, "Empty") is (), "An empty-string value reads as ()");
    test:assertTrue(propString(props, "Missing") is (), "A missing key reads as ()");
}

@test:Config {}
isolated function testPropDecimalParsesContentLength() {
    map<json> stringValued = {"Content-Length": "12345"};
    test:assertEquals(propDecimal(stringValued, "Content-Length"), <decimal>12345, "String content length parses");
    map<json> intValued = {"Content-Length": 678};
    test:assertEquals(propDecimal(intValued, "Content-Length"), <decimal>678, "Numeric JSON content length parses");
    test:assertTrue(propDecimal({}, "Content-Length") is (), "A missing content length reads as ()");
    test:assertTrue(propDecimal({"Content-Length": "notanumber"}, "Content-Length") is (), "Unparseable reads as ()");
}

// ---- toBlobEntry -------------------------------------------------------------

@test:Config {}
isolated function testToBlobEntryReadsProperties() {
    blobs:Blob blob = {
        Name: "reports/q1.pdf",
        Properties: {
            "Content-Type": "application/pdf",
            "Content-Length": "45678",
            "Creation-Time": "Wed, 09 Mar 2022 10:00:00 GMT",
            "Last-Modified": "Thu, 10 Mar 2022 11:00:00 GMT"
        }
    };
    BlobEntry entry = toBlobEntry(blob);
    test:assertEquals(entry.name, "reports/q1.pdf");
    test:assertEquals(entry.contentType, "application/pdf");
    test:assertEquals(entry.contentLength, <decimal>45678);
    test:assertEquals(entry.creationTime, "Wed, 09 Mar 2022 10:00:00 GMT");
    test:assertEquals(entry.lastModified, "Thu, 10 Mar 2022 11:00:00 GMT");
}

@test:Config {}
isolated function testToBlobEntryToleratesMissingProperties() {
    blobs:Blob blob = {Name: "notes.txt", Properties: {}};
    BlobEntry entry = toBlobEntry(blob);
    test:assertEquals(entry.name, "notes.txt");
    test:assertTrue(entry.contentType is ());
    test:assertTrue(entry.contentLength is ());
    test:assertTrue(entry.creationTime is ());
    test:assertTrue(entry.lastModified is ());
}

// ---- entryFromHeaders (the HEAD existence probe) -----------------------------

@test:Config {}
isolated function testEntryFromHeadersReadsBlobMetadata() {
    // What `getBlobProperties` returns for a real blob: the connector copies every response
    // header onto its open `ResponseHeaders` record.
    blobs:ResponseHeaders headers = {
        Date: "Wed, 09 Mar 2022 10:00:00 GMT",
        x\-ms\-version: "2019-12-12",
        x\-ms\-request\-id: "req-1",
        "Content-Type": "application/pdf",
        "Content-Length": "45678",
        "x-ms-creation-time": "Wed, 09 Mar 2022 10:00:00 GMT",
        "Last-Modified": "Thu, 10 Mar 2022 11:00:00 GMT"
    };
    BlobEntry entry = entryFromHeaders("reports/q1.pdf", headers);
    test:assertEquals(entry.name, "reports/q1.pdf");
    test:assertEquals(entry.contentType, "application/pdf");
    test:assertEquals(entry.contentLength, <decimal>45678);
    test:assertEquals(entry.creationTime, "Wed, 09 Mar 2022 10:00:00 GMT");
    test:assertEquals(entry.lastModified, "Thu, 10 Mar 2022 11:00:00 GMT");
    // The probe is what lets an explicitly named blob be classified before it is downloaded.
    test:assertEquals(classify(entry.name, entry.contentType), EXTRACTABLE);
}

@test:Config {}
isolated function testEntryFromHeadersIsCaseInsensitive() {
    // HTTP header names are case-insensitive and nothing in the connector normalizes them.
    blobs:ResponseHeaders headers = {
        Date: "",
        x\-ms\-version: "",
        x\-ms\-request\-id: "",
        "content-type": "text/plain",
        "CONTENT-LENGTH": "12"
    };
    BlobEntry entry = entryFromHeaders("notes.txt", headers);
    test:assertEquals(entry.contentType, "text/plain");
    test:assertEquals(entry.contentLength, <decimal>12);
}

@test:Config {}
isolated function testEntryFromHeadersToleratesMissingAndBlankHeaders() {
    blobs:ResponseHeaders headers = {
        Date: "",
        x\-ms\-version: "",
        x\-ms\-request\-id: "",
        "Content-Type": "   ",
        "Content-Length": "notanumber"
    };
    BlobEntry entry = entryFromHeaders("notes.txt", headers);
    test:assertTrue(entry.contentType is (), "A blank header value reads as ()");
    test:assertTrue(entry.contentLength is (), "An unparseable Content-Length reads as ()");
    test:assertTrue(entry.creationTime is (), "A missing header reads as ()");
    test:assertTrue(entry.lastModified is ());
}

// ---- isNotFoundError ---------------------------------------------------------

@test:Config {}
isolated function testIsNotFoundErrorFromServerErrorStatus() {
    blobs:ServerError err = error("Blob not found",
            httpStatus = 404, errorCode = "BlobNotFound", message = "The specified blob does not exist.");
    test:assertTrue(isNotFoundError(err), "A 404 ServerError is recognised as not-found");
}

@test:Config {}
isolated function testIsNotFoundErrorFromErrorCode() {
    // A non-404 status but a *NotFound error code is still treated as not-found.
    blobs:ServerError err = error("missing",
            httpStatus = 400, errorCode = "ContainerNotFound", message = "The specified container does not exist.");
    test:assertTrue(isNotFoundError(err));
}

@test:Config {}
isolated function testIsNotFoundErrorFromMessageText() {
    test:assertTrue(isNotFoundError(error("Resource not found")));
    test:assertTrue(isNotFoundError(error("request failed with status code '404'")));
}

@test:Config {}
isolated function testIsNotFoundErrorFalseForOtherErrors() {
    test:assertFalse(isNotFoundError(error("internal server error")));
    blobs:ServerError err = error("forbidden",
            httpStatus = 403, errorCode = "AuthenticationFailed", message = "Server failed to authenticate.");
    test:assertFalse(isNotFoundError(err), "A 403 is not a not-found");
}
