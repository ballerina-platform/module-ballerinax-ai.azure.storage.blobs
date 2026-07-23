# Ballerina Azure Blob Storage Data Loader

The `ballerinax/ai.azure.storage.blobs` module provides a `TextDataLoader` that retrieves documents from Azure Blob Storage containers and returns them as `ai:TextDocument` values, ready to be chunked, embedded, and indexed by the [Ballerina AI](https://central.ballerina.io/ballerina/ai) module. Inherently textual blobs are decoded directly, while PDF and Microsoft Office documents have their text extracted with Apache Tika (PDFBox for PDF, Apache POI for Office).

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is expected (for example, in a Retrieval-Augmented Generation ingestion pipeline).

The acquisition layer — authentication, blob listing, download, and pagination — is delegated to the [`ballerinax/azure_storage_service.blobs`](https://central.ballerina.io/ballerinax/azure_storage_service.blobs) connector.

## Overview

- Reads blobs from one or more Azure Blob **containers** in a storage account.
- Loads individual blobs as well as entire virtual folders (blob-name prefixes), optionally recursively.
- Reads from multiple containers — including **every** container in the account — with a single loader instance.
- Follows the `NextMarker` cursor to page through large containers automatically.
- Returns every blob as an `ai:TextDocument`, based on its MIME type / extension:
  - Inherently textual blobs (e.g. `txt`, `md`, `html`, `json`, `csv`, `xml`) are decoded directly.
  - `pdf` blobs have their text extracted with Apache Tika (PDFBox).
  - Microsoft Office documents (`.doc`, `.docx`, `.ppt`, `.pptx`, `.xls`, `.xlsx`) have their text
    extracted with Apache Tika (Apache POI) — both by extension and by their Office MIME types
    reported in blob listings.
  - Other blobs that cannot be represented as text (e.g. images, audio, archives) are skipped with a
    logged warning; explicitly naming such a blob as a path is an error.
  - A **scanned (image-only) PDF** — one that parses but has no text layer — is skipped with a logged
    warning in folder listings, and surfaces a descriptive error when named explicitly. **OCR is not
    supported** (see the limitation below).

> **No OCR.** Scanned PDFs are detected and reported, not read: extracting their text requires OCR,
> which this loader does not ship. Two future paths exist — Tesseract via Tika's OCR module (requires
> the native `tesseract` binary installed on every host) or a managed service such as Azure AI
> Document Intelligence.

## Authentication

Azure Blob Storage is accessed through the `ballerinax/azure_storage_service.blobs` connector, and the loader is initialized with that connector's `blobs:ConnectionConfig` directly (or with an existing `blobs:BlobClient` — see [Reusing an existing client](#reusing-an-existing-client)). It supports two authorization mechanisms, both configured through `accessKeyOrSAS` together with `authorizationMethod`:

| Mechanism | `authorizationMethod` | `accessKeyOrSAS` holds | Best for |
| --- | --- | --- | --- |
| Shared Access Signature (SAS) | `blobs:SAS` | A SAS token (the query string, e.g. `sv=...&sig=...`) | Scoped, time-limited, pre-signed access without sharing an account key |
| Shared Key (account access key) | `blobs:ACCESS_KEY` | One of the storage account's access keys | Full-account, server-to-server access; the connector signs each request with HMAC-SHA256 |

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
        accessKeyOrSAS: "sv=2022-11-02&ss=b&srt=co&sp=rl&sig=...",
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

If the application already holds a `blobs:BlobClient`, pass it in place of the `blobs:ConnectionConfig` rather than having the loader construct a second one:

```ballerina
final blobs:BlobClient blobClient = check new ({
    accountName: "contosostorage",
    accessKeyOrSAS: "sv=2022-11-02&ss=b&srt=co&sp=rl&sig=...",
    authorizationMethod: blobs:SAS
});

final blob:TextDataLoader loader = check new (blobClient, [{container: "documents"}]);
```

This shares one connection pool across every loader (and any other connector use) built on that client. A client supplied this way is **not** owned by the loader: the caller remains responsible for its lifecycle.

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

### Loading documents

```ballerina
public function main() returns error? {
    ai:Document[]|ai:Document documents = check loader.load();
    // Pass the documents to a chunker / embedding provider / vector store ...
}
```

`load()` returns a single `ai:Document` when exactly one blob is resolved, and an `ai:Document[]` otherwise (mirroring `ai:TextDataLoader`).

Each returned `ai:TextDocument` carries metadata including the full blob name (`fileName`), and — when reported by Azure — the `mimeType` and `fileSize`.

> **Note:** Azure's List Blobs response reports blob timestamps in RFC 1123 format, which the Ballerina `time` module's ISO 8601 parser does not accept, so `createdAt` / `modifiedAt` are currently omitted from the document metadata.

## Configuration reference

### `blobs:ConnectionConfig`

The loader is configured with the `ballerinax/azure_storage_service.blobs` connector's `ConnectionConfig` record. Its most relevant fields are:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `accountName` | `string` | — | The Azure Storage account name; used to build the blob service endpoint |
| `accessKeyOrSAS` | `string` | — | An account access key or a SAS token, interpreted per `authorizationMethod` |
| `authorizationMethod` | `blobs:AuthorizationMethod` | — | `blobs:ACCESS_KEY` (Shared Key) or `blobs:SAS` |
| `httpVersion` | `http:HttpVersion` | `http:HTTP_1_1` | HTTP version understood by the client |
| `http2Settings` | `http:ClientHttp2Settings` | — | HTTP/2 protocol settings |
| `timeout` | `decimal` | `30` | Response timeout, in seconds |
| `forwarded` | `string` | `"disable"` | Handling of the `forwarded`/`x-forwarded` header |
| `poolConfig` | `http:PoolConfiguration` | — | Request pooling configuration |
| `cache` | `http:CacheConfig` | — | HTTP caching configuration |
| `compression` | `http:Compression` | `http:COMPRESSION_AUTO` | `accept-encoding` handling |
| `circuitBreaker` | `http:CircuitBreakerConfig` | — | Circuit breaker configuration |
| `retryConfig` | `http:RetryConfig` | — | Retry configuration |
| `responseLimits` | `http:ResponseLimitConfigs` | — | Inbound response size limits |
| `secureSocket` | `http:ClientSecureSocket` | — | SSL/TLS options |
| `proxy` | `http:ProxyConfig` | — | Proxy server options |
| `validation` | `boolean` | `true` | Inbound payload validation |

The HTTP-level fields are forwarded to the underlying `ballerinax/azure_storage_service.blobs` client.

### `Source`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `container` | `string` | — | The container name to read from, or `"*"` for every container in the account |
| `paths` | `string[]` | `["/"]` | Blob-name prefixes (virtual-folder paths) and/or explicit blob names. The default `["/"]` loads the whole container; `[]` loads nothing |
| `recursive` | `boolean` | `false` | Whether folder prefixes are traversed into virtual sub-folders |
| `includeExtensions` | `string[]?` | `()` | Extension allowlist applied to folder-prefix contents (e.g. `["pdf"]`). Case-insensitive; `()` loads all types. Explicit blob paths bypass it |
