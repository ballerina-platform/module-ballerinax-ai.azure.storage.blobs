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

@test:Config {}
isolated function testInitWithoutSourcesFails() {
    blobs:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "sas", authorizationMethod: blobs:SAS};
    TextDataLoader|ai:Error loader = new (config, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
}

@test:Config {}
isolated function testInitWithSourcesSucceeds() returns error? {
    blobs:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "sas", authorizationMethod: blobs:SAS};
    TextDataLoader _ = check new (config, [{container: "documents"}]);
}

@test:Config {}
isolated function testInitWithExistingClientSucceeds() returns error? {
    // An already-constructed client is used as-is, so a caller sharing one client across
    // several loaders does not open a second connection pool per loader.
    blobs:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "sas", authorizationMethod: blobs:SAS};
    blobs:BlobClient blobClient = check new (config);
    TextDataLoader _ = check new (blobClient, [{container: "documents"}]);
}

@test:Config {}
isolated function testInitWithExistingClientStillValidatesSources() returns error? {
    // The source check runs before the connection is resolved, so it applies to both forms.
    blobs:ConnectionConfig config = {accountName: "acct", accessKeyOrSAS: "sas", authorizationMethod: blobs:SAS};
    blobs:BlobClient blobClient = check new (config);
    TextDataLoader|ai:Error loader = new (blobClient, []);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
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
