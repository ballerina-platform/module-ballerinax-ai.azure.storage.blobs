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

import ballerina/test;
import ballerinax/azure_storage_service.blobs;

// ---- Source defaults ---------------------------------------------------------

@test:Config {}
isolated function testSourceDefaults() {
    Source src = {container: "documents"};
    test:assertEquals(src.paths, ["/"], "paths defaults to the whole container");
    test:assertFalse(src.recursive, "recursive defaults to false");
    test:assertTrue(src.includeExtensions is (), "includeExtensions defaults to () (all types)");
}

@test:Config {}
isolated function testSourceExplicitValues() {
    Source src = {
        container: "specs",
        paths: ["/api", "/design.md"],
        recursive: true,
        includeExtensions: ["pdf", ".md"]
    };
    test:assertEquals(src.container, "specs");
    test:assertEquals(src.paths.length(), 2);
    test:assertTrue(src.recursive);
    test:assertEquals(src.includeExtensions, ["pdf", ".md"]);
}

// ---- newBlobClient construction ---------------------------------------------

@test:Config {}
isolated function testNewBlobClientWithSas() returns error? {
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "sv=2022-11-02&ss=b&srt=co&sp=rl&sig=abc",
        authorizationMethod: blobs:SAS
    };
    blobs:BlobClient _ = check newBlobClient(config);
}

@test:Config {}
isolated function testNewBlobClientWithAccessKey() returns error? {
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        // A syntactically valid base64 access key; no network call is made at construction.
        accessKeyOrSAS: "dGhpcy1pcy1hLWZha2Uta2V5LWZvci10ZXN0aW5n",
        authorizationMethod: blobs:ACCESS_KEY
    };
    blobs:BlobClient _ = check newBlobClient(config);
}

// ---- BlobEntry shape ---------------------------------------------------------

@test:Config {}
isolated function testBlobEntryDefaults() {
    BlobEntry entry = {name: "reports/q1.pdf"};
    test:assertEquals(entry.name, "reports/q1.pdf");
    test:assertTrue(entry.contentType is (), "Optional metadata defaults to ()");
    test:assertTrue(entry.contentLength is ());
    test:assertTrue(entry.creationTime is ());
    test:assertTrue(entry.lastModified is ());
}
