# Ballerina Azure Blob Storage Data Loader

The `ballerinax/ai.azure.storage.blobs` module provides a `TextDataLoader` that retrieves documents from Azure Blob Storage containers and returns them as `ai:TextDocument` values, ready to be chunked, embedded, and indexed by the [Ballerina AI](https://central.ballerina.io/ballerina/ai) module. Inherently textual blobs are decoded directly, while PDF and Microsoft Office documents have their text extracted with Apache Tika (PDFBox for PDF, Apache POI for Office).

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is expected (for example, in a Retrieval-Augmented Generation ingestion pipeline).

The acquisition layer — authentication, blob listing, download, and pagination — is delegated to the [`ballerinax/azure_storage_service.blobs`](https://central.ballerina.io/ballerinax/azure_storage_service.blobs) connector.

## Overview

- Reads blobs from one or more Azure Blob **containers** in a storage account.
- Loads individual blobs as well as entire virtual folders (blob-name prefixes), optionally recursively.
- Reads from multiple containers — including **every** container in the account — with a single loader instance.
- Follows the `NextMarker` cursor to page through large containers automatically.
- Returns every blob as an `ai:TextDocument`, based on its `Content-Type` (authoritative) and, when
  that is missing or unrecognised, its file extension:
  - Inherently textual blobs (e.g. `txt`, `md`, `json`, `csv`, `xml`) are decoded directly. Decoding
    honours a byte-order mark first, then the `charset` on the blob's `Content-Type`, then UTF-8;
    any BOM is stripped rather than carried into the document.
  - `html`, `htm` and `xhtml` blobs are **rendered to plain text** — tags, script/style bodies and
    character references are resolved away, so no markup reaches the document body.
  - `pdf` blobs have their text extracted with Apache Tika (PDFBox).
  - Microsoft Office documents (`.doc`, `.docx`, `.ppt`, `.pptx`, `.xls`, `.xlsx`) have their text
    extracted with Apache Tika (Apache POI) — both by extension and by their Office MIME types
    reported in blob listings.
  - Other blobs that cannot be represented as text (e.g. images, audio, archives) are skipped with a
    logged warning; explicitly naming such a blob as a path is an error.
  - A **scanned (image-only) PDF** — one that parses but has no text layer — is skipped with a logged
    warning in folder listings, and surfaces a descriptive error when named explicitly. **OCR is not
    supported** (see the limitation below).
- Classifies each blob from its **listing metadata**, before downloading it, so an unsupported blob
  costs no bandwidth at all.
- Never lets one bad blob discard a bulk load: any per-blob failure inside a folder listing is
  skipped with a logged warning and a summary count, while an explicitly named blob still errors.

> **No OCR.** Scanned PDFs are detected and reported, not read: extracting their text requires OCR,
> which this loader does not ship. Two future paths exist — Tesseract via Tika's OCR module (requires
> the native `tesseract` binary installed on every host) or a managed service such as Azure AI
> Document Intelligence.

## Authentication

The loader is initialized with the connector's own `blobs:ConnectionConfig` record, so authentication is configured exactly as it would be for `ballerinax/azure_storage_service.blobs` directly. It supports two authorization mechanisms, both configured through `accessKeyOrSAS` together with `authorizationMethod`:

| Mechanism | `authorizationMethod` | `accessKeyOrSAS` holds | Best for |
| --- | --- | --- | --- |
| Shared Access Signature (SAS) | `blobs:SAS` | A SAS token — the query string **including the leading `?`**, e.g. `?sv=...&sig=...` | Scoped, time-limited, pre-signed access without sharing an account key |
| Shared Key (account access key) | `blobs:ACCESS_KEY` | One of the storage account's access keys | Full-account, server-to-server access; each request is signed with HMAC-SHA256 |

> **Note:** Azure AD / Microsoft Entra ID (OAuth2) is **not** supported in this version, as the underlying connector authorizes with Shared Key and SAS only.

The service endpoint is derived from the account name as `https://{accountName}.blob.core.windows.net`.

## Usage

### Initialization

```ballerina
import ballerinax/ai.azure.storage.blobs as blob;
import ballerinax/azure_storage_service.blobs;

final blob:TextDataLoader loader = check new (
    {
        accountName: "contosostorage",
        accessKeyOrSAS: "?sv=2022-11-02&ss=b&srt=co&sp=rl&sig=...",
        authorizationMethod: blobs:SAS
    },
    [
        {
            // Load one explicit blob plus everything under /onboarding (recursively),
            // restricted to PDFs.
            container: "documents",
            paths: ["/policies/leave-policy.pdf", "/onboarding"],
            recursive: true,
            includeExtensions: ["pdf"]
        },
        {
            // A bare container name loads the whole container (non-recursive).
            container: "specs",
            paths: ["/api-design.md"]
        }
    ]
);
```

### Reusing an existing client

A caller who already talks to the storage account can hand the loader an existing `blobs:BlobClient` instead of a config, avoiding a second HTTP connection pool:

```ballerina
final blobs:BlobClient blobClient = check new ({
    accountName: "contosostorage",
    accessKeyOrSAS: "?sv=2022-11-02&ss=b&srt=co&sp=rl&sig=...",
    authorizationMethod: blobs:SAS
});

final blob:TextDataLoader loader = check new (blobClient, [{container: "documents"}]);
```

A supplied client is **not owned** by the loader: it is never closed or reconfigured, and its retry and response-limit settings are left exactly as configured. The defaults described under [Retries and response limits](#retries-and-response-limits) apply only when the loader builds the client itself.

### The container / prefix model

Azure Blob Storage has no real folders: a container holds a flat set of blobs, and hierarchy is simulated by `/` characters in blob names (e.g. `reports/2026/q1.pdf`). This loader maps a configured **path** onto a blob-name **prefix**:

- **A path with a trailing `/`, or the container root (`/`)** is treated as a virtual folder and listed by prefix.
- **A path without a trailing `/`** is first tried as an explicitly named blob. If an exact blob exists it is loaded directly (and always loaded, regardless of the extension filter). If no such blob exists, the path is treated as a virtual folder — unless it looks like a file (has an extension), in which case a missing blob is reported as an error to help catch typos.
- **A deliberately named non-text blob** (an image, an archive, a scanned PDF, etc.) is an **error**, whereas the same blob discovered while listing a folder is skipped with a warning.

`paths` defaults to `["/"]`, so a `Source` with only a `container` loads the whole container; set `paths` to `[]` to load nothing.

### Recursion

By default a folder prefix loads only the blobs **directly** under it. Set `recursive: true` to include blobs at any depth beneath the prefix:

```ballerina
{container: "documents", paths: ["/reports"], recursive: true}
```

### Reading from every container

Set `container` to `"*"` to read from **every** container in the storage account. Because the `paths` are then applied to all containers, a path that does not exist in a given container is **skipped** for it rather than treated as an error:

```ballerina
{container: "*", paths: ["/shared"], recursive: true}
```

### Filtering by file type

Each `Source` has its own `includeExtensions` to restrict which blobs are loaded from folder prefixes:

- `includeExtensions: ["pdf"]` — only PDF blobs.
- `includeExtensions: ["pdf", ".md", "TXT"]` — case-insensitive; a leading dot is optional.
- omitted / `()` (the default) — load all types.

The filter applies to blobs discovered while listing a folder prefix. A blob listed **explicitly** in `paths` is always loaded, even if its extension isn't in the list.

### Failure handling

The loader draws a deliberate line between a blob you **named** and a blob it **discovered**:

- **A blob named explicitly in `paths`** — an unsupported type, a scanned PDF, a download failure, or (when the path looks like a file) a missing blob is reported as an `ai:Error`. Naming a blob expresses intent, so failing to load it is a mistake worth surfacing.
- **A blob discovered while listing a prefix** — every per-blob failure is skipped with a logged warning and the walk continues. One non-UTF-8 `.txt`, one corrupt PDF, or one 403 on a single blob must not discard the documents already collected or abandon the rest of the container. When anything was skipped, a single summary line reports how many were loaded versus skipped, so a prefix where everything failed is distinguishable from an empty one.

Unsupported blobs are identified from the **listing metadata** (Azure reports a real `Content-Type` per blob) and from a `HEAD` probe for explicitly named paths, so they are never downloaded in the first place.

### How a blob's type is decided

The blob's `Content-Type` is authoritative and settles the type on its own; the blob-name extension is consulted only when the `Content-Type` is missing or unrecognised. Azure lets a blob's name and its `Content-Type` be set independently, so a PDF stored as `notes.txt` is still text-extracted rather than decoded as UTF-8.

Parameters are ignored when matching, so `text/plain; charset=UTF-8` and `application/pdf; version=1.7` classify as expected. `application/octet-stream` — what Azure records for a blob uploaded without an explicit type — carries no information and falls through to the extension.

One extension is deliberately **not** treated as text: `.ts`, which is both TypeScript source and an MPEG transport stream. Guessing text there would download a whole video to produce binary garbage. A `.ts` blob served with a `text/*` `Content-Type` still loads as text, via the rule above.

### Overlapping sources

Sources and paths may overlap freely — `paths: ["/", "/reports"]`, the same container listed twice, or a container reached both directly and through `"*"`. Each blob is loaded **once**: duplicates are identified by `container` + blob name and skipped before they are downloaded, so an overlap costs neither a duplicate document nor a second request. Identical blob names in *different* containers are distinct and both load.

### Blob name limitations

Blob names containing **`#`**, **`%`**, or **non-ASCII characters** cannot currently be loaded. The underlying `ballerinax/azure_storage_service.blobs` connector does not percent-encode the request path or the `prefix` query parameter, so such a name is either truncated at the `#` (which can silently return a *different* blob), rejected with a 400, or sent raw and mangled.

The loader cannot correct this from the outside: pre-encoding the name would be double-encoded for SAS auth and would invalidate the Shared Key signature, which is computed over the decoded resource path. So instead:

- a blob with such a name **discovered in a listing** is skipped with a warning naming the reason;
- a **configured path** containing one of these characters is rejected at `init` with a clear error, rather than failing later with an opaque 400.

This is an upstream limitation; see `REVIEW-CHECKLIST.md` (`IMPL1`) for the issue to be filed.

### Retries and response limits

When the loader constructs its own client from a `blobs:ConnectionConfig`, it fills in two settings the connector leaves unset — but only when the caller supplied neither, so an explicit value always wins (including one that deliberately disables retrying):

| Setting | Default applied | Rationale |
| --- | --- | --- |
| `retryConfig` | 4 attempts, 1 s interval, backoff factor 2.0, max wait 20 s, on `429, 500, 502, 503, 504` | Azure signals throttling as 503 `ServerBusy` / 500 `OperationTimedOut` and account request-rate limits as 429, and documents exponential backoff as the required response. **403 is deliberately not retried**: Azure Storage uses it for authorization failures (bad Shared Key signature, expired or under-scoped SAS), which waiting cannot fix |
| `responseLimits.maxEntityBodySize` | 100 MB | Unset, this is unlimited, and a container is exactly where a multi-gigabyte object turns up. A blob above the cap fails that one blob, which a prefix listing then skips like any other per-blob failure |

Neither default is applied to a caller-supplied `blobs:BlobClient`.

### Loading documents

```ballerina
public function main() returns error? {
    ai:Document[]|ai:Document documents = check loader.load();
    // Pass the documents to a chunker / embedding provider / vector store ...
}
```

`load()` returns a single `ai:Document` when exactly one blob is resolved, and an `ai:Document[]` otherwise (mirroring `ai:TextDataLoader`).

Each returned `ai:TextDocument` carries metadata including the full blob name (`fileName`), the source `container`, and — when reported by Azure — the `mimeType` and `fileSize`. `fileName` alone is not unique across a load that spans several containers, so `container` + `fileName` is the key to trace a document back to the blob it came from.

> **Note:** Azure's List Blobs response reports blob timestamps in RFC 1123 format, which the Ballerina `time` module's ISO 8601 parser does not accept, so `createdAt` / `modifiedAt` are currently omitted from the document metadata.

## Configuration reference

### Connection

The loader takes the connector's own `blobs:ConnectionConfig` (from `ballerinax/azure_storage_service.blobs`) rather than re-declaring one, so every option the connector supports is available and configured the same way. The fields that matter here:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `accountName` | `string` | — | The Azure Storage account name; used to build the blob service endpoint |
| `accessKeyOrSAS` | `string` | — | An account access key, or a SAS token (the query string **including the leading `?`**), interpreted per `authorizationMethod` |
| `authorizationMethod` | `blobs:AuthorizationMethod` | — | `blobs:ACCESS_KEY` (Shared Key) or `blobs:SAS` |
| `httpVersion` | `http:HttpVersion` | `http:HTTP_1_1` | HTTP version understood by the client |
| `timeout` | `decimal` | `60` | Response timeout, in seconds |
| `retryConfig` | `http:RetryConfig?` | see [Retries and response limits](#retries-and-response-limits) | Retry policy; defaulted by the loader when unset |
| `responseLimits` | `http:ResponseLimitConfigs?` | see [Retries and response limits](#retries-and-response-limits) | Response size caps; defaulted by the loader when unset |

Alternatively, pass an already-constructed `blobs:BlobClient` — see [Reusing an existing client](#reusing-an-existing-client).

### `Source`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `container` | `string` | — | The container name to read from, or `"*"` for every container in the account |
| `paths` | `string[]` | `["/"]` | Blob-name prefixes (virtual-folder paths) and/or explicit blob names. The default `["/"]` loads the whole container; `[]` loads nothing |
| `recursive` | `boolean` | `false` | Whether folder prefixes are traversed into virtual sub-folders |
| `includeExtensions` | `string[]?` | `()` | Extension allowlist applied to folder-prefix contents (e.g. `["pdf"]`). Case-insensitive; `()` loads all types. Explicit blob paths bypass it |
