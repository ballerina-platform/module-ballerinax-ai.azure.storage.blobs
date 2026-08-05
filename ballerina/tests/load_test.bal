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

// End-to-end coverage of `load()` against the in-memory account in `mock_store.bal`. Everything
// above the connector boundary runs for real here: source normalization, `NextMarker`
// pagination, the file-vs-folder probe, classification, the extension filter, the
// skip-don't-abort walk, and the single-document collapse.

import ballerina/ai;
import ballerina/test;

// A small account: one container, a root file, a `reports/` folder with a nested sub-folder,
// and one unsupported blob.
isolated function sampleBlobs() returns MockBlob[] => [
    {container: "docs", name: "readme.md", contentType: "text/markdown", content: "# Readme".toBytes()},
    {container: "docs", name: "reports/q1.txt", contentType: "text/plain", content: "Q1 revenue".toBytes()},
    {container: "docs", name: "reports/q2.txt", contentType: "text/plain", content: "Q2 revenue".toBytes()},
    {container: "docs", name: "reports/2026/q3.txt", contentType: "text/plain", content: "Q3 revenue".toBytes()},
    {container: "docs", name: "logo.png", contentType: "image/png", content: [137, 80, 78, 71]}
];

// ---- whole-container load ----------------------------------------------------

@test:Config {}
isolated function testLoadWholeContainerNonRecursive() returns error? {
    MockBlobStore store = new (sampleBlobs());
    // `paths` defaults to ["/"], the container root, and `recursive` to false.
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    assertLoaded(documents, ["readme.md"],
            "A non-recursive root load takes only blobs directly under the root");
}

@test:Config {}
isolated function testLoadWholeContainerRecursive() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store, [{container: "docs", recursive: true}]);
    assertLoaded(documents, ["readme.md", "reports/q1.txt", "reports/q2.txt", "reports/2026/q3.txt"],
            "A recursive root load takes every supported blob at every depth");
}

@test:Config {}
isolated function testLoadDocumentContentAndMetadata() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["/readme.md"]}]);
    test:assertEquals(documents.length(), 1);
    ai:Document document = documents[0];
    if document is ai:TextDocument {
        test:assertEquals(document.content, "# Readme");
        test:assertEquals(document.metadata?.mimeType, "text/markdown");
        test:assertEquals(document.metadata?.fileSize, <decimal>8);
        ai:Metadata metadata = document.metadata ?: {};
        test:assertEquals(metadata["container"], "docs", "The source container is carried on the document");
    } else {
        test:assertFail("Expected a TextDocument");
    }
}

// ---- folder prefixes ---------------------------------------------------------

@test:Config {}
isolated function testLoadFolderPrefixNonRecursive() returns error? {
    MockBlobStore store = new (sampleBlobs());
    // Azure lists a prefix without a delimiter, so `reports/2026/q3.txt` comes back from the
    // service and must be filtered out client-side by `isDirectChild`.
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["/reports"]}]);
    assertLoaded(documents, ["reports/q1.txt", "reports/q2.txt"],
            "A non-recursive prefix load excludes blobs in virtual sub-folders");
}

@test:Config {}
isolated function testLoadFolderPrefixRecursive() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents =
        check loadAll(store, [{container: "docs", paths: ["/reports"], recursive: true}]);
    assertLoaded(documents, ["reports/q1.txt", "reports/q2.txt", "reports/2026/q3.txt"],
            "A recursive prefix load descends into virtual sub-folders");
}

@test:Config {}
isolated function testTrailingSlashIsAlwaysAFolder() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["/reports/"]}]);
    assertLoaded(documents, ["reports/q1.txt", "reports/q2.txt"],
            "A trailing slash is a folder prefix and is never probed as a blob");
    test:assertEquals(store.fetchedNames().indexOf("reports/"), (),
            "A trailing-slash path must not be probed as an exact blob");
}

@test:Config {}
isolated function testFolderMarkerBlobsAreSkipped() returns error? {
    // Some tools create zero-length blobs whose name ends in `/` to fake a folder.
    MockBlob[] withMarker = [
        {container: "docs", name: "reports/", contentType: "application/octet-stream"},
        {container: "docs", name: "reports/q1.txt", contentType: "text/plain", content: "Q1".toBytes()}
    ];
    MockBlobStore store = new (withMarker);
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["/reports/"]}]);
    assertLoaded(documents, ["reports/q1.txt"], "A folder-marker blob is not a document");
    test:assertEquals(store.fetchedNames(), ["reports/q1.txt"],
            "A folder-marker blob is skipped before it is downloaded");
}

// REGRESSION: the file-vs-folder probe asks `getExtension` whether a path "looks like a file",
// and that search used to run over the WHOLE path. A folder with a dot in its name therefore
// lent its dot to every extension-less path beneath it — `specs/v1.2/notes` answered
// `"2/notes"` — so the path was judged a file, its 404 was final, and a folder that genuinely
// exists came back as `blob not found`.
@test:Config {}
isolated function testAPathUnderADottedFolderIsStillResolvedAsAFolder() returns error? {
    MockBlob[] dotted = [
        {container: "docs", name: "specs/v1.2/notes/intro.txt", contentType: "text/plain",
            content: "intro".toBytes()},
        {container: "docs", name: "specs/v1.2/notes/detail.txt", contentType: "text/plain",
            content: "detail".toBytes()}
    ];
    MockBlobStore store = new (dotted);
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["/specs/v1.2/notes"]}]);
    assertLoaded(documents, ["specs/v1.2/notes/intro.txt", "specs/v1.2/notes/detail.txt"],
            "A dot in an ancestor folder must not make an extension-less path look like a file");
}

// ---- explicitly named blobs --------------------------------------------------

@test:Config {}
isolated function testExplicitBlobBypassesTheExtensionFilter() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store,
            [{container: "docs", paths: ["/readme.md"], includeExtensions: ["pdf"]}]);
    assertLoaded(documents, ["readme.md"],
            "Naming a blob explicitly loads it regardless of includeExtensions");
}

@test:Config {}
isolated function testExplicitlyNamedUnsupportedBlobIsAnError() {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[]|error result = loadAll(store, [{container: "docs", paths: ["/logo.png"]}]);
    if result is error {
        test:assertTrue(result.message().includes("Unsupported"), result.message());
    } else {
        test:assertFail("Deliberately naming a non-text blob must error, not silently skip it");
    }
}

@test:Config {}
isolated function testExplicitlyNamedUnsupportedBlobIsNeverDownloaded() {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[]|error ignored = loadAll(store, [{container: "docs", paths: ["/logo.png"]}]);
    test:assertTrue(ignored is error, "Naming an unsupported blob errors");
    test:assertEquals(store.fetchCount(), 0,
            "The HEAD probe classifies a named blob, so an unsupported one costs no download");
}

@test:Config {}
isolated function testMissingFileLikePathIsAnError() {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[]|error result = loadAll(store, [{container: "docs", paths: ["/missing.txt"]}]);
    if result is error {
        test:assertTrue(result.message().includes("blob not found"), result.message());
    } else {
        test:assertFail("A missing path that looks like a file must be reported, to catch typos");
    }
}

@test:Config {}
isolated function testMissingExtensionlessPathFallsBackToAPrefix() returns error? {
    MockBlobStore store = new (sampleBlobs());
    // `reports` is not a blob, but it has no extension, so it is retried as a folder prefix.
    ai:Document[] documents = check loadAll(store, [{container: "docs", paths: ["reports"]}]);
    assertLoaded(documents, ["reports/q1.txt", "reports/q2.txt"],
            "An extensionless path with no matching blob is treated as a folder");
}

// ---- classification: unsupported blobs are never downloaded ------------------

@test:Config {}
isolated function testUnsupportedBlobInAListingIsSkippedWithoutDownloading() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store, [{container: "docs", recursive: true}]);
    test:assertEquals(loadedNames(documents).indexOf("logo.png"), (), "The image is not a document");
    test:assertEquals(store.fetchedNames().indexOf("logo.png"), (),
            "Classification happens on listing metadata, so an image is never fetched");
    test:assertEquals(store.fetchCount(), 4, "Only the four supported blobs were downloaded");
}

// ---- includeExtensions -------------------------------------------------------

@test:Config {}
isolated function testIncludeExtensionsFiltersAListing() returns error? {
    MockBlob[] mixed = [
        {container: "docs", name: "a.txt", contentType: "text/plain", content: "a".toBytes()},
        {container: "docs", name: "b.md", contentType: "text/markdown", content: "b".toBytes()},
        {container: "docs", name: "c.json", contentType: "application/json", content: "{}".toBytes()}
    ];
    MockBlobStore store = new (mixed);
    ai:Document[] documents =
        check loadAll(store, [{container: "docs", includeExtensions: [".MD", "json"]}]);
    assertLoaded(documents, ["b.md", "c.json"],
            "The allowlist is case-insensitive and tolerates a leading dot");
    test:assertEquals(store.fetchedNames().indexOf("a.txt"), (),
            "A filtered-out blob is never downloaded");
}

// ---- NextMarker pagination ---------------------------------------------------

@test:Config {}
isolated function testListingFollowsNextMarkerAcrossPages() returns error? {
    MockBlob[] many = [];
    foreach int i in 0 ..< 7 {
        many.push({
            container: "docs",
            name: string `file-${i}.txt`,
            contentType: "text/plain",
            content: i.toString().toBytes()
        });
    }
    // A page size of 2 over 7 blobs forces four pages; a walk that stopped after the first
    // would return 2 documents.
    MockBlobStore store = new (many, pageSize = 2);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    test:assertEquals(documents.length(), 7, "Every page of a paginated listing is consumed");
}

@test:Config {}
isolated function testMissingNamedContainerIsAnError() {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[]|error result = loadAll(store, [{container: "nope"}]);
    if result is error {
        test:assertTrue(result.message().includes("Failed to list blobs"), result.message());
    } else {
        test:assertFail("An explicitly named container that does not exist must be reported");
    }
}

// ---- skip-don't-abort inside a listing ---------------------------------------

@test:Config {}
isolated function testAFailedBlobDoesNotAbortTheListing() returns error? {
    MockBlob[] withFailure = [
        {container: "docs", name: "a.txt", contentType: "text/plain", content: "a".toBytes()},
        {
            container: "docs",
            name: "b.txt",
            contentType: "text/plain",
            content: "b".toBytes(),
            downloadError: "This request is not authorized to perform this operation."
        },
        {container: "docs", name: "c.txt", contentType: "text/plain", content: "c".toBytes()}
    ];
    MockBlobStore store = new (withFailure);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    assertLoaded(documents, ["a.txt", "c.txt"],
            "One 403 on one blob must not discard the rest of the container");
}

@test:Config {}
isolated function testUndecodableBlobIsSkippedInAListing() returns error? {
    MockBlob[] withBadText = [
        // 0xFF is not a valid UTF-8 start byte.
        {container: "docs", name: "broken.txt", contentType: "text/plain", content: [255, 254, 253]},
        {container: "docs", name: "good.txt", contentType: "text/plain", content: "ok".toBytes()}
    ];
    MockBlobStore store = new (withBadText);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    assertLoaded(documents, ["good.txt"], "A blob that will not decode is skipped, not fatal");
}

@test:Config {}
isolated function testScannedPdfIsSkippedInAListingButErrorsWhenNamed() returns error? {
    MockBlob[] withScan = [
        {container: "docs", name: "scan.pdf", contentType: "application/pdf", content: SCANNED_PDF_BYTES},
        {container: "docs", name: "notes.txt", contentType: "text/plain", content: "n".toBytes()}
    ];
    MockBlobStore listingStore = new (withScan);
    ai:Document[] documents = check loadAll(listingStore, [{container: "docs"}]);
    assertLoaded(documents, ["notes.txt"], "A scanned PDF found in a listing is skipped");

    MockBlobStore namedStore = new (withScan);
    ai:Document[]|error named = loadAll(namedStore, [{container: "docs", paths: ["/scan.pdf"]}]);
    if named is error {
        test:assertTrue(isScannedPdfError(named), named.message());
    } else {
        test:assertFail("An explicitly named scanned PDF must surface the descriptive error");
    }
}

@test:Config {}
isolated function testAListingWhereEverythingFailsReturnsEmptyNotError() returns error? {
    MockBlob[] allBad = [
        {container: "docs", name: "a.txt", contentType: "text/plain", content: "a".toBytes(), downloadError: "403"},
        {container: "docs", name: "b.txt", contentType: "text/plain", content: "b".toBytes(), downloadError: "403"}
    ];
    MockBlobStore store = new (allBad);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    test:assertEquals(documents.length(), 0,
            "A prefix where every blob failed yields no documents rather than an error");
}

@test:Config {}
isolated function testAFailedNamedBlobIsStillAnError() {
    MockBlob[] withFailure = [
        {
            container: "docs",
            name: "a.txt",
            contentType: "text/plain",
            content: "a".toBytes(),
            downloadError: "This request is not authorized to perform this operation."
        }
    ];
    MockBlobStore store = new (withFailure);
    ai:Document[]|error result = loadAll(store, [{container: "docs", paths: ["/a.txt"]}]);
    if result is error {
        test:assertTrue(result.message().includes("Failed to download"), result.message());
    } else {
        test:assertFail("Naming a blob expresses intent, so failing to load it must be reported");
    }
}

// ---- de-duplication across overlapping sources -------------------------------
// REGRESSION: sources overlap easily, and every overlapping blob used to be downloaded twice
// and emitted as two identical documents, duplicating it in whatever index the caller built.

@test:Config {}
isolated function testOverlappingPathsInOneSourceLoadEachBlobOnce() returns error? {
    MockBlobStore store = new (sampleBlobs());
    // `/` (recursive) already covers everything `/reports` does.
    ai:Document[] documents =
        check loadAll(store, [{container: "docs", paths: ["/", "/reports"], recursive: true}]);
    assertLoaded(documents, ["readme.md", "reports/q1.txt", "reports/q2.txt", "reports/2026/q3.txt"],
            "An overlapping path must not duplicate documents");
    test:assertEquals(store.fetchCount(), 4, "A duplicate is skipped before it is downloaded");
}

@test:Config {}
isolated function testOverlappingSourcesLoadEachBlobOnce() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents = check loadAll(store, [
        {container: "docs", recursive: true},
        {container: "docs", paths: ["/reports/"]}
    ]);
    test:assertEquals(documents.length(), 4, "De-duplication spans sources, not just paths");
}

@test:Config {}
isolated function testAnExplicitPathAndItsFolderDoNotDuplicate() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents =
        check loadAll(store, [{container: "docs", paths: ["/reports/q1.txt", "/reports/"]}]);
    assertLoaded(documents, ["reports/q1.txt", "reports/q2.txt"],
            "A named blob that the following prefix also covers is loaded once");
}

@test:Config {}
isolated function testSameBlobInDifferentContainersIsNotDeduplicated() returns error? {
    // The key is container-qualified: two blobs with the same name in different containers are
    // different blobs and must both load.
    MockBlob[] same = [
        {container: "docs", name: "notes.txt", contentType: "text/plain", content: "one".toBytes()},
        {container: "specs", name: "notes.txt", contentType: "text/plain", content: "two".toBytes()}
    ];
    MockBlobStore store = new (same);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}, {container: "specs"}]);
    test:assertEquals(documents.length(), 2, "Identical names in different containers are distinct");
}

// ---- pagination guard --------------------------------------------------------

@test:Config {}
isolated function testAStuckPaginationCursorIsReportedNotLoopedOn() {
    // A service echoing the same marker back would otherwise spin `while true` forever, holding
    // every page fetched so far in memory.
    MockBlobStore store = new (sampleBlobs(), pageSize = 2, stickyMarker = true);
    ai:Document[]|error result = loadAll(store, [{container: "docs"}]);
    if result is error {
        test:assertTrue(result.message().includes("not advancing"), result.message());
    } else {
        test:assertFail("A non-advancing pagination cursor must be reported, not looped on");
    }
}

// ---- blob names the connector cannot address ---------------------------------
// ⬆️ UPSTREAM: the connector does not percent-encode request paths. `#` truncates the path (so
// a DIFFERENT blob may be returned, with no error at all), `%` gives a 400, and non-ASCII is
// sent raw.

@test:Config {}
isolated function testUnaddressableBlobNamesAreSkippedInAListing() returns error? {
    MockBlob[] awkward = [
        {container: "docs", name: "notes#1.txt", contentType: "text/plain", content: "hash".toBytes()},
        {container: "docs", name: "what?.txt", contentType: "text/plain", content: "qm".toBytes()},
        {container: "docs", name: "50%-done.txt", contentType: "text/plain", content: "pct".toBytes()},
        {container: "docs", name: "résumé.txt", contentType: "text/plain", content: "acc".toBytes()},
        {container: "docs", name: "fine.txt", contentType: "text/plain", content: "ok".toBytes()}
    ];
    MockBlobStore store = new (awkward);
    ai:Document[] documents = check loadAll(store, [{container: "docs"}]);
    assertLoaded(documents, ["fine.txt"], "Unaddressable names are skipped, and the walk continues");
    test:assertEquals(store.fetchedNames(), ["fine.txt"],
            "An unaddressable blob is never requested, so it cannot silently return another blob");
}

@test:Config {}
isolated function testUnaddressableConfiguredPathIsRejectedAtInit() {
    foreach string path in ["/notes#1.txt", "/what?.txt", "/50%-done.txt", "/résumés/"] {
        ResolvedSource[]|ai:Error resolved = resolveSources([{container: "docs", paths: [path]}]);
        if resolved is ai:Error {
            test:assertTrue(resolved.message().includes("not addressable"), resolved.message());
        } else {
            test:assertFail(string `The path '${path}' cannot be requested and must be rejected`);
        }
    }
}

@test:Config {}
isolated function testOrdinaryPathsRemainAddressable() {
    test:assertTrue(isAddressableBlobName("reports/2026/q1.pdf"));
    test:assertTrue(isAddressableBlobName("a-b_c.d~e"));
    test:assertTrue(isAddressableBlobName(""), "The container root is addressable");
    test:assertFalse(isAddressableBlobName("a#b"));
    // `?` opens the query string, so the path is truncated exactly as `#` truncates it — and
    // under SAS auth the token the connector appends merges into that query.
    test:assertFalse(isAddressableBlobName("a?b"));
    test:assertFalse(isAddressableBlobName("a%20b"));
    test:assertFalse(isAddressableBlobName("café.txt"));
}

// ---- load() arity ------------------------------------------------------------

@test:Config {}
isolated function testLoadCollapsesASingleDocument() returns error? {
    MockBlobStore store = new (sampleBlobs());
    BlobLoader loader = check loaderOver(store, [{container: "docs", paths: ["/readme.md"]}]);
    ai:Document[]|ai:Document result = check loader.load();
    test:assertFalse(result is ai:Document[],
            "Exactly one resolved blob collapses to a single document, not a one-element array");
}

@test:Config {}
isolated function testLoadReturnsAnArrayForSeveralDocuments() returns error? {
    MockBlobStore store = new (sampleBlobs());
    BlobLoader loader = check loaderOver(store, [{container: "docs", recursive: true}]);
    ai:Document[]|ai:Document result = check loader.load();
    test:assertTrue(result is ai:Document[], "Several resolved blobs return an array");
}

@test:Config {}
isolated function testLoadReturnsAnEmptyArrayWhenNothingMatches() returns error? {
    MockBlobStore store = new (sampleBlobs());
    BlobLoader loader = check loaderOver(store, [{container: "docs", paths: []}]);
    ai:Document[]|ai:Document result = check loader.load();
    test:assertTrue(result is ai:Document[] && result.length() == 0,
            "A source that selects nothing yields an empty array");
}

// ---- several sources ---------------------------------------------------------

@test:Config {}
isolated function testSeveralSourcesAreLoadedInOrder() returns error? {
    MockBlob[] across = [
        {container: "docs", name: "a.txt", contentType: "text/plain", content: "a".toBytes()},
        {container: "specs", name: "b.txt", contentType: "text/plain", content: "b".toBytes()}
    ];
    MockBlobStore store = new (across);
    ai:Document[] documents = check loadAll(store, [
        {container: "specs"},
        {container: "docs"}
    ]);
    test:assertEquals(loadedNames(documents), ["b.txt", "a.txt"],
            "Sources are loaded in the order configured");
}

@test:Config {}
isolated function testSeveralPathsInOneSource() returns error? {
    MockBlobStore store = new (sampleBlobs());
    ai:Document[] documents =
        check loadAll(store, [{container: "docs", paths: ["/readme.md", "/reports/"]}]);
    assertLoaded(documents, ["readme.md", "reports/q1.txt", "reports/q2.txt"],
            "Every configured path in a source contributes");
}
