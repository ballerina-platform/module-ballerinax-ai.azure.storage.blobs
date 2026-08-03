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
import ballerina/http;
import ballerinax/azure_storage_service.blobs;

// Azure documents exponential backoff as the required response to a throttled or transient
// blob request (https://learn.microsoft.com/en-us/azure/architecture/best-practices/retry-service-specific).
// The blob service signals throttling as 503 `ServerBusy` and 500 `OperationTimedOut`, and
// account-level request-rate limits as 429; 502/504 cover a failure in front of the service.
//
// 403 is deliberately NOT retried, unlike a Google Drive loader where 403 doubles as the
// rate-limit signal. Azure Storage uses 403 only for authorization failures — a wrong Shared
// Key signature, an expired or under-scoped SAS — and none of those are fixed by waiting.
final http:RetryConfig & readonly DEFAULT_RETRY_CONFIG = {
    interval: 1,
    count: 4,
    backOffFactor: 2.0,
    maxWaitInterval: 20,
    statusCodes: [429, 500, 502, 503, 504]
};

// A backstop on how much of a single blob is read into memory. Unset, `maxEntityBodySize`
// defaults to -1, i.e. unlimited — and a blob container is exactly where a multi-gigabyte
// object turns up, so one oversized blob could otherwise exhaust the heap and take every
// concurrent load down with it. A blob above this cap fails that one blob, which a folder
// listing then skips like any other per-blob failure.
final http:ResponseLimitConfigs & readonly DEFAULT_RESPONSE_LIMITS = {
    maxEntityBodySize: 104857600
};

// Constructs the Azure Blob Storage connector client from the connector's own
// `ConnectionConfig` (Shared Key or SAS), wrapping any construction failure as an `ai:Error`.
// The loader consumes the connector's config type directly rather than re-declaring one, so
// callers configure auth exactly as they would for the connector, and a caller who already
// holds a `blobs:BlobClient` can hand that over instead.
//
// `retryConfig` and `responseLimits` are optional on the connector's config and unset by
// default, which leaves a bulk load with no retry at all over Azure's throttling and an
// unbounded response body. Both are filled in here when the caller supplied neither — an
// explicit value always wins, including one that deliberately disables retrying.
isolated function newBlobClient(blobs:ConnectionConfig config) returns blobs:BlobClient|ai:Error {
    // A spread copy rather than `clone()`, which returns a readonly value unchanged and would
    // make the defaulting below fail on an immutable caller config. This copy is always mutable,
    // and the caller's own record is never touched.
    blobs:ConnectionConfig effective = {...config};
    if effective.retryConfig is () {
        effective.retryConfig = DEFAULT_RETRY_CONFIG;
    }
    if effective.responseLimits is () {
        effective.responseLimits = DEFAULT_RESPONSE_LIMITS;
    }
    blobs:BlobClient|error blobClient = new (effective);
    if blobClient is error {
        return error ai:Error(
            string `Failed to initialize the Azure Blob Storage client: ${blobClient.message()}`, blobClient);
    }
    return blobClient;
}

// The four Azure Blob operations this loader performs, named as an object type so the whole
// load path can be exercised against a fake.
//
// A seam at this boundary, rather than an HTTP-level mock of the Blob REST surface, is forced
// by the connector: `blobs:BlobClient` derives its base URL from the account name
// (`https://{account}.blob.core.windows.net`) and offers no way to redirect it, so no test
// listener can ever receive its requests. Everything above this interface — pagination, the
// `"*"` fan-out, the file-vs-folder probe, classification, the skip-don't-abort walk — is
// therefore testable offline, while the interface itself stays a pass-through thin enough that
// nothing meaningful can hide in it.
type BlobStore isolated client object {
    isolated remote function listContainers(string? marker) returns blobs:ListContainerResult|error;
    isolated remote function listBlobs(string container, string? marker, string? prefix)
            returns blobs:ListBlobResult|error;
    isolated remote function getBlobProperties(string container, string blobName)
            returns blobs:ResponseHeaders|error;
    isolated remote function getBlob(string container, string blobName) returns blobs:BlobResult|error;
};

// The production `BlobStore`: a pass-through to the connector client, pinning the arguments the
// loader never varies (page size, snapshot IDs) so they cannot drift between call sites.
isolated client class ConnectorBlobStore {
    *BlobStore;

    private final blobs:BlobClient blobClient;

    isolated function init(blobs:BlobClient blobClient) {
        self.blobClient = blobClient;
    }

    isolated remote function listContainers(string? marker) returns blobs:ListContainerResult|error {
        return self.blobClient->listContainers((), marker, ());
    }

    isolated remote function listBlobs(string container, string? marker, string? prefix)
            returns blobs:ListBlobResult|error {
        return self.blobClient->listBlobs(container, (), marker, prefix);
    }

    isolated remote function getBlobProperties(string container, string blobName)
            returns blobs:ResponseHeaders|error {
        return self.blobClient->getBlobProperties(container, blobName);
    }

    isolated remote function getBlob(string container, string blobName) returns blobs:BlobResult|error {
        return self.blobClient->getBlob(container, blobName, ());
    }
}
