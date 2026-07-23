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
import ballerinax/azure_storage_service.blobs;

// Constructs the underlying Azure Blob Storage connector client from the connector's
// `ConnectionConfig`, wrapping any construction failure as an `ai:Error`.
isolated function newBlobClient(blobs:ConnectionConfig config) returns blobs:BlobClient|ai:Error {
    blobs:BlobClient|error blobClient = new (config);
    if blobClient is error {
        return error ai:Error(
            string `Failed to initialize the Azure Blob Storage client: ${blobClient.message()}`, blobClient);
    }
    return blobClient;
}
