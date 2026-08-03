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

# A rule selecting what to load from one Azure Blob container. Several may be configured
# per loader. A container is the unit of addressing; there is no site/library chain, so a
# container maps directly to a `Source`.
public type Source record {|
    # The container name to read from, or `"*"` for every container in the account.
    # For `"*"`, a missing path is tolerated (skipped) rather than an error.
    string container;
    # Blob-name prefixes (virtual-folder paths, e.g. `/reports`) to read.
    # Defaults to `["/"]`, the whole container; `[]` reads nothing.
    string[] paths = ["/"];
    # Whether virtual sub-folders under a prefix are traversed. Defaults to `false`.
    boolean recursive = false;
    # Case-insensitive extension allowlist for prefix listings.
    # Defaults to `()`, all types.
    string[]? includeExtensions = ();
|};

// A source with its paths already normalized to Azure blob-name prefixes and its container
// validated. Normalization and validation happen in `init`, so a misconfigured source fails
// immediately rather than part-way through a long load, after documents have already been
// fetched and then discarded.
type ResolvedSource record {|
    string container;
    // Paths with `normalizeBlobPath` applied: trimmed, no leading `/`, container root as `""`,
    // and a trailing `/` preserved (it distinguishes an explicit folder from an ambiguous path).
    string[] paths;
    boolean recursive;
    string[]? includeExtensions;
    // True for the `"*"` container, where the same paths are applied to every container in the
    // account and so need not exist in all of them: a missing path is skipped, not an error.
    boolean tolerateMissing;
|};

// A normalized listing entry, decoupled from the connector's `Blob` record (whose
// `Properties` are an untyped `map<json>`). The loader reads the connector's
// blob metadata into this shape before building an `ai:TextDocument`.

# A single blob discovered while listing a container prefix.
type BlobEntry record {|
    # The full blob name (may contain `/`, giving virtual folders), e.g. `reports/q1.pdf`.
    string name;
    # The blob's `Content-Type`, if reported.
    string? contentType = ();
    # The blob's size in bytes, if reported.
    decimal? contentLength = ();
    # The blob's creation timestamp (ISO 8601), if reported.
    string? creationTime = ();
    # The blob's last-modified timestamp (ISO 8601), if reported.
    string? lastModified = ();
|};
