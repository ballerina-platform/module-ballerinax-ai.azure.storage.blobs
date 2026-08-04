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

import ballerina/http;
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
        // A SAS token is the query string including the leading `?`.
        accessKeyOrSAS: "?sv=2022-11-02&ss=b&srt=co&sp=rl&sig=abc",
        authorizationMethod: blobs:SAS
    };
    _ = check newBlobClient(config);
}

@test:Config {}
isolated function testNewBlobClientWithAccessKey() returns error? {
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        // A syntactically valid base64 access key; no network call is made at construction.
        accessKeyOrSAS: "dGhpcy1pcy1hLWZha2Uta2V5LWZvci10ZXN0aW5n",
        authorizationMethod: blobs:ACCESS_KEY
    };
    _ = check newBlobClient(config);
}

@test:Config {}
isolated function testNewBlobClientLeavesCallerConfigUntouched() returns error? {
    // The defaulting in `newBlobClient` works on a spread copy, so the caller's own record
    // must come back out with `retryConfig`/`responseLimits` still unset.
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "?sv=2022-11-02&sig=abc",
        authorizationMethod: blobs:SAS
    };
    _ = check newBlobClient(config);
    test:assertTrue(config.retryConfig is (), "The caller's config must not be mutated");
    test:assertTrue(config.responseLimits is (), "The caller's config must not be mutated");
}

@test:Config {}
isolated function testNewBlobClientAcceptsAnImmutableConfig() returns error? {
    // A readonly config would make an in-place `clone()`-based defaulting fail; the spread
    // copy must accept it.
    blobs:ConnectionConfig & readonly config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "?sv=2022-11-02&sig=abc",
        authorizationMethod: blobs:SAS
    };
    _ = check newBlobClient(config);
}

@test:Config {}
isolated function testNewBlobClientHonoursAnExplicitRetryConfig() returns error? {
    // An explicit value always wins over the default — including one that deliberately
    // disables retrying.
    //
    // Asserted against the EFFECTIVE config, not the caller's record: the caller's record only
    // shows that nothing mutated it (which `testNewBlobClientLeavesCallerConfigUntouched`
    // already covers), and would look identical if the defaulting had overwritten the policy on
    // its way to the connector.
    http:RetryConfig noRetry = {count: 0, interval: 0};
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "?sv=2022-11-02&sig=abc",
        authorizationMethod: blobs:SAS,
        retryConfig: noRetry
    };
    blobs:ConnectionConfig effective = applyConnectionDefaults(config);
    test:assertEquals(effective.retryConfig?.count, 0,
            "The caller's retry policy is what reaches the connector");
    test:assertEquals(effective.responseLimits?.maxEntityBodySize,
            DEFAULT_RESPONSE_LIMITS.maxEntityBodySize,
            "The limit the caller did NOT set is still defaulted");
    _ = check newBlobClient(config);
}

@test:Config {}
isolated function testEffectiveConfigDefaultsWhatTheCallerLeftUnset() {
    blobs:ConnectionConfig config = {
        accountName: "contosostorage",
        accessKeyOrSAS: "?sv=2022-11-02&sig=abc",
        authorizationMethod: blobs:SAS
    };
    blobs:ConnectionConfig effective = applyConnectionDefaults(config);
    test:assertEquals(effective.retryConfig?.count, DEFAULT_RETRY_CONFIG.count);
    test:assertEquals(effective.retryConfig?.statusCodes, DEFAULT_RETRY_CONFIG.statusCodes);
    test:assertEquals(effective.responseLimits?.maxEntityBodySize,
            DEFAULT_RESPONSE_LIMITS.maxEntityBodySize);
    test:assertEquals(effective.accountName, config.accountName, "Unrelated fields pass through");
}

@test:Config {}
isolated function testDefaultRetryConfigDoesNotRetry403() {
    // Azure Storage uses 403 for authorization failures (bad Shared Key signature, expired or
    // under-scoped SAS), never for throttling — retrying one cannot help.
    test:assertTrue(DEFAULT_RETRY_CONFIG.statusCodes.indexOf(403) is (),
            "403 must not be in the default retry status codes");
    test:assertTrue(DEFAULT_RETRY_CONFIG.statusCodes.indexOf(503) !is (),
            "503 ServerBusy is Azure's throttling signal and must be retried");
    test:assertTrue(DEFAULT_RETRY_CONFIG.statusCodes.indexOf(429) !is ());
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
