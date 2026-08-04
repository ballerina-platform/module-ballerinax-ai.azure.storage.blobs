/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.azure.storage.blobs;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import org.apache.tika.exception.WriteLimitReachedException;
import org.apache.tika.extractor.EmbeddedDocumentExtractor;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.microsoft.OfficeParser;
import org.apache.tika.parser.microsoft.ooxml.OOXMLParser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.parser.pdf.PDFParserConfig;
import org.apache.tika.sax.BodyContentHandler;
import org.xml.sax.ContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.util.Locale;
import java.util.Set;

/**
 * Extracts plain text from documents using Apache Tika.
 *
 * <p>Supports PDF documents and Microsoft Office formats (.doc/.docx, .ppt/.pptx,
 * .xls/.xlsx): the shipped Tika parser modules are {@code tika-parser-pdf-module} (PDFBox)
 * and {@code tika-parser-microsoft-module} (Apache POI), declared as platform dependencies
 * in {@code Ballerina.toml}. The caller ({@code classify}) decides which blobs are routed here.
 *
 * <p>Unlike {@code ai:TextDataLoader}, which reads from a file path, this reads straight
 * from the in-memory bytes downloaded from Azure Blob Storage via a {@link ByteArrayInputStream},
 * so no temporary file is ever written.
 *
 * <p>The concrete parser is selected explicitly from the file extension rather than via
 * {@code AutoDetectParser}. {@code AutoDetectParser} eagerly instantiates every parser
 * registered on the runtime classpath, and in a full Ballerina runtime one of those
 * unrelated parsers fails to initialise against the {@code commons-lang3} version bundled
 * in the runtime ({@code SystemProperties.getUserName(String)} is absent) — a
 * {@code NoSuchMethodError} a platform-dependency {@code commons-lang3} cannot override.
 * Selecting the exact parser we need ({@link PDFParser}, {@link OOXMLParser}, or
 * {@link OfficeParser}) loads only that parser and sidesteps the issue.
 *
 * <p>For the same reason, recursion into <em>embedded</em> objects (thumbnails, OLE objects,
 * attachments) is disabled via a no-op {@link EmbeddedDocumentExtractor}: Office parsers would
 * otherwise route embedded content through {@code AutoDetectParser}'s container detection,
 * which triggers the same {@code commons-lang3} failure. Only the document's own text is
 * needed here, so skipping embedded objects is both a fix and the desired behavior.
 */
public final class TextExtractor {

    /**
     * The ceiling on extracted text, in characters, per document.
     *
     * <p>An unlimited handler ({@code -1}) makes the extracted text unbounded independently of
     * how large the blob was: compressed formats expand, and an OOXML file well under the
     * loader's 100 MB download cap can hold far more text than that, on top of the bytes the
     * loader is already holding. 50 million characters is roughly 100 MB of {@code char} data
     * and some tens of thousands of pages of prose — comfortably beyond any real document, while
     * still bounding a decompression bomb.
     *
     * <p>Configurable via the {@code MAX_EXTRACTED_CHARACTERS_PROPERTY} system property, for the
     * caller who genuinely has a larger document.
     */
    private static final int DEFAULT_MAX_EXTRACTED_CHARACTERS = 50_000_000;

    static final String MAX_EXTRACTED_CHARACTERS_PROPERTY =
            "ballerina.ai.azure.storage.blobs.maxExtractedCharacters";

    private static final int MAX_EXTRACTED_CHARACTERS = resolveMaxExtractedCharacters();

    /**
     * The error message returned for a PDF that parses successfully but yields no text.
     * PDFBox extracts only the text layer, so both a scanned/image-only document and a
     * genuinely blank one parse "successfully" with empty text — silently producing an
     * empty document unless detected here. The message is deliberately NEUTRAL: without
     * OCR the loader cannot tell a scan from a blank page, so it does not guess. The
     * Ballerina layer matches this message (see {@code isTextlessPdfError} in
     * {@code utils.bal}) to skip such files in prefix listings while surfacing a
     * descriptive error for explicitly named paths.
     */
    static final String TEXTLESS_PDF_MESSAGE =
            "the PDF contains no extractable text content (it may be a scanned/image-only "
                    + "document or an empty one); OCR is not supported";

    // OOXML (.docx/.xlsx/.pptx) Office MIME types, parsed by OOXMLParser.
    private static final Set<String> OOXML_MIME_TYPES = Set.of(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation");

    // Legacy OLE2 (.doc/.xls/.ppt) Office MIME types, parsed by OfficeParser.
    private static final Set<String> OLE2_MIME_TYPES = Set.of(
            "application/msword",
            "application/vnd.ms-excel",
            "application/vnd.ms-powerpoint");

    // PDF MIME types, parsed by PDFParser. `application/x-pdf` is a legacy spelling still seen
    // on blobs uploaded by older tooling.
    private static final Set<String> PDF_MIME_TYPES = Set.of(
            "application/pdf",
            "application/x-pdf");

    private TextExtractor() {
    }

    /**
     * Extracts the textual content of a document held entirely in memory.
     *
     * @param content  the raw file bytes
     * @param fileName the file name, used to select the parser and as a Tika hint
     * @param mimeType the blob's Content-Type ({@code ""} if unknown), used to select the
     *                 parser when the file name has no recognised extension — Azure Blob
     *                 listings surface a real Content-Type, so the caller's classification
     *                 can be MIME-only and parser selection must agree with it
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractText(BArray content, BString fileName, BString mimeType) {
        byte[] bytes = content.getBytes();
        try (InputStream stream = new ByteArrayInputStream(bytes)) {
            Parser parser = selectParser(fileName.getValue(), mimeType.getValue());
            BodyContentHandler handler = new BodyContentHandler(MAX_EXTRACTED_CHARACTERS);
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            ParseContext context = new ParseContext();
            context.set(EmbeddedDocumentExtractor.class, SkipEmbeddedExtractor.INSTANCE);
            // OCR is not supported (no Tesseract shipped): disable the PDF parser's OCR
            // fallback explicitly, otherwise it NPEs trying to OCR image-only pages.
            PDFParserConfig pdfConfig = new PDFParserConfig();
            pdfConfig.setOcrStrategy(PDFParserConfig.OCR_STRATEGY.NO_OCR);
            context.set(PDFParserConfig.class, pdfConfig);
            parser.parse(stream, handler, metadata, context);
            String text = handler.toString();
            // A PDF that parses but yields no text is either scanned/image-only or blank:
            // PDFBox reads only the text layer, so surface one neutral descriptive error
            // instead of silently returning an empty document (or guessing which case it is).
            if (parser instanceof PDFParser && text.trim().isEmpty()) {
                return ErrorCreator.createError(StringUtils.fromString(TEXTLESS_PDF_MESSAGE));
            }
            return StringUtils.fromString(text);
        } catch (Exception e) {
            // The write limit is reported as an exception out of the handler, so it has to be
            // named here or it would surface as an opaque parse failure. It fails only THIS
            // blob: a prefix listing logs it and carries on, exactly as with any other per-blob
            // error, rather than losing the documents already collected.
            if (WriteLimitReachedException.isWriteLimitReached(e)) {
                return ErrorCreator.createError(StringUtils.fromString(
                        "the extracted text exceeds the " + MAX_EXTRACTED_CHARACTERS
                                + " character limit; raise the '" + MAX_EXTRACTED_CHARACTERS_PROPERTY
                                + "' system property to extract documents this large"));
            }
            String message = e.getMessage();
            return ErrorCreator.createError(StringUtils.fromString(
                    message != null ? message : e.getClass().getSimpleName()));
        }
    }

    /**
     * Reads the extracted-text ceiling from its system property, falling back to the default
     * when it is unset or not a positive integer. A silent fallback is right here: a typo in a
     * tuning property must not stop every document in the account from loading.
     */
    private static int resolveMaxExtractedCharacters() {
        String configured = System.getProperty(MAX_EXTRACTED_CHARACTERS_PROPERTY);
        if (configured == null) {
            return DEFAULT_MAX_EXTRACTED_CHARACTERS;
        }
        try {
            int limit = Integer.parseInt(configured.trim());
            return limit > 0 ? limit : DEFAULT_MAX_EXTRACTED_CHARACTERS;
        } catch (NumberFormatException e) {
            return DEFAULT_MAX_EXTRACTED_CHARACTERS;
        }
    }

    /**
     * Selects the Tika parser for a file from its MIME type, falling back to its extension.
     * OOXML (.docx/.xlsx/.pptx) and legacy OLE2 (.doc/.xls/.ppt) Office formats use POI;
     * everything else this method is called with is a PDF (the caller only routes PDF/Office
     * here), which uses PDFBox.
     *
     * <p>The MIME type is consulted FIRST, because it is what the Ballerina {@code classify}
     * treats as authoritative — the extension is its own fallback. Selecting on the extension
     * first would disagree with that decision whenever the two conflict: {@code notes.docx}
     * stored as {@code application/pdf} is classified from its MIME type, then parsed as OOXML,
     * and fails.
     *
     * <p>The media type is normalized the same way {@code essenceOf} normalizes it on the
     * Ballerina side. Azure echoes back whatever was set at upload, parameters and all
     * ({@code ...wordprocessingml.document; charset=binary}), which no exact match would catch.
     */
    private static Parser selectParser(String fileName, String mimeType) {
        String mime = essenceOf(mimeType);
        if (OOXML_MIME_TYPES.contains(mime)) {
            return new OOXMLParser();
        }
        if (OLE2_MIME_TYPES.contains(mime)) {
            return new OfficeParser();
        }
        if (PDF_MIME_TYPES.contains(mime)) {
            return new PDFParser();
        }
        String name = fileName.toLowerCase(Locale.ROOT);
        if (name.endsWith(".docx") || name.endsWith(".xlsx") || name.endsWith(".pptx")) {
            return new OOXMLParser();
        }
        if (name.endsWith(".doc") || name.endsWith(".xls") || name.endsWith(".ppt")) {
            return new OfficeParser();
        }
        return new PDFParser();
    }

    /**
     * Reduces a Content-Type to its bare essence: parameters stripped, trimmed, lower-cased.
     * Mirrors {@code essenceOf} in {@code utils.bal}, so both layers match on the same string.
     */
    private static String essenceOf(String mimeType) {
        int separator = mimeType.indexOf(';');
        String essence = separator < 0 ? mimeType : mimeType.substring(0, separator);
        return essence.trim().toLowerCase(Locale.ROOT);
    }

    /**
     * An {@link EmbeddedDocumentExtractor} that skips every embedded object, so parsing never
     * recurses into embedded content (see the class Javadoc for why this matters here).
     */
    private static final class SkipEmbeddedExtractor implements EmbeddedDocumentExtractor {
        static final SkipEmbeddedExtractor INSTANCE = new SkipEmbeddedExtractor();

        @Override
        public boolean shouldParseEmbedded(Metadata metadata) {
            return false;
        }

        @Override
        public void parseEmbedded(InputStream stream, ContentHandler handler, Metadata metadata,
                                  boolean outputHtml) {
            // Intentionally a no-op: embedded objects are not extracted.
        }
    }
}
