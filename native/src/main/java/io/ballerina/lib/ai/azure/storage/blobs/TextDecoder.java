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

import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.IllegalCharsetNameException;
import java.nio.charset.StandardCharsets;
import java.nio.charset.UnsupportedCharsetException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Decodes downloaded blob bytes into a string, and renders HTML markup as plain text.
 *
 * <p>Decoding is done here rather than with {@code string:fromBytes} because that is strict
 * UTF-8 only. A blob container holds plenty of text that is not: spreadsheets exported as CSV
 * carry a UTF-8 BOM, Windows-authored files are frequently UTF-16 or windows-1252, and Azure
 * echoes back the {@code charset} recorded on the blob's {@code Content-Type}. A strict-UTF-8
 * decode turns all of those into failures — which, in a prefix listing, means the blob is
 * silently skipped.
 *
 * <p>The charset is resolved in priority order: a byte-order mark (authoritative and
 * self-describing), then the charset Azure declares, then UTF-8 as the default. Any BOM is
 * stripped so it never reaches the document body — a leading {@code U+FEFF} would otherwise
 * corrupt the first CSV header cell, the first Markdown heading, and any downstream
 * {@code startsWith} check, and would be carried into every embedding built from the document.
 *
 * <p>Decoding stays strict ({@link CodingErrorAction#REPORT}): once the charset is right, bytes
 * that still do not decode indicate genuinely corrupt content, which the caller should see as
 * an error rather than silently receive as replacement characters.
 */
public final class TextDecoder {

    private static final byte[] BOM_UTF_8 = {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF};
    private static final byte[] BOM_UTF_16BE = {(byte) 0xFE, (byte) 0xFF};
    private static final byte[] BOM_UTF_16LE = {(byte) 0xFF, (byte) 0xFE};

    // <script>/<style> bodies are markup-adjacent noise, never document text, so they are
    // dropped wholly rather than having their tags stripped and their source code kept.
    private static final Pattern SCRIPT_OR_STYLE =
            Pattern.compile("<(script|style)\\b[^>]*>.*?</\\1\\s*>", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern COMMENT = Pattern.compile("<!--.*?-->", Pattern.DOTALL);
    // Tags that imply a line break in the rendered text, so words either side stay separate.
    private static final Pattern BLOCK_BOUNDARY = Pattern.compile(
            "<\\s*/?\\s*(br|p|div|li|tr|h[1-6]|table|ul|ol|section|article|header|footer|blockquote|pre)\\b[^>]*>",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern ANY_TAG = Pattern.compile("<[^>]*>", Pattern.DOTALL);
    private static final Pattern NUMERIC_ENTITY = Pattern.compile("&#(x?)([0-9a-fA-F]+);");
    private static final Pattern BLANK_RUN = Pattern.compile("[ \\t\\x0B\\f\\r]+");
    private static final Pattern NEWLINE_RUN = Pattern.compile("\\n{3,}");

    private TextDecoder() {
    }

    /**
     * Decodes text bytes using the charset implied by a BOM, else the declared charset, else
     * UTF-8. Any BOM is stripped from the result.
     *
     * @param content     the raw bytes
     * @param charsetName the charset Azure declared on the blob's Content-Type ({@code ""}
     *                    when absent)
     * @return the decoded text, or a Ballerina error if the bytes are not valid in the
     *         resolved charset
     */
    public static Object decodeText(BArray content, BString charsetName) {
        byte[] bytes = content.getBytes();
        Charset charset = charsetFromBom(bytes);
        int offset = charset != null ? bomLength(bytes) : 0;
        if (charset == null) {
            charset = declaredCharset(charsetName.getValue());
        }
        try {
            CharsetDecoder decoder = charset.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
            CharBuffer decoded = decoder.decode(ByteBuffer.wrap(bytes, offset, bytes.length - offset));
            return StringUtils.fromString(decoded.toString());
        } catch (CharacterCodingException e) {
            return ErrorCreator.createError(StringUtils.fromString(
                    "the content is not valid " + charset.name() + " text"));
        }
    }

    /**
     * Renders HTML markup as plain text: drops script/style bodies and comments, turns block
     * boundaries into line breaks, strips the remaining tags, resolves character references,
     * and collapses the whitespace the markup left behind.
     *
     * <p>This is deliberately a lightweight renderer, not an HTML parser. Storing raw markup in
     * a document body puts tags and undecoded entities into every embedding, which is worse for
     * retrieval than an imperfect de-tagging.
     *
     * @param html the raw HTML source
     * @return the rendered plain text
     */
    public static BString htmlToText(BString html) {
        String text = html.getValue();
        text = SCRIPT_OR_STYLE.matcher(text).replaceAll(" ");
        text = COMMENT.matcher(text).replaceAll(" ");
        text = BLOCK_BOUNDARY.matcher(text).replaceAll("\n");
        text = ANY_TAG.matcher(text).replaceAll(" ");
        text = decodeEntities(text);
        text = BLANK_RUN.matcher(text).replaceAll(" ");
        text = NEWLINE_RUN.matcher(text).replaceAll("\n\n");
        return StringUtils.fromString(text.trim());
    }

    /** Returns the charset a leading byte-order mark declares, or {@code null} if there is none. */
    private static Charset charsetFromBom(byte[] bytes) {
        if (startsWith(bytes, BOM_UTF_8)) {
            return StandardCharsets.UTF_8;
        }
        if (startsWith(bytes, BOM_UTF_16BE)) {
            return StandardCharsets.UTF_16BE;
        }
        if (startsWith(bytes, BOM_UTF_16LE)) {
            return StandardCharsets.UTF_16LE;
        }
        return null;
    }

    private static int bomLength(byte[] bytes) {
        return startsWith(bytes, BOM_UTF_8) ? BOM_UTF_8.length : 2;
    }

    private static boolean startsWith(byte[] bytes, byte[] prefix) {
        if (bytes.length < prefix.length) {
            return false;
        }
        for (int i = 0; i < prefix.length; i++) {
            if (bytes[i] != prefix[i]) {
                return false;
            }
        }
        return true;
    }

    /**
     * Resolves the charset Azure declared, falling back to UTF-8 when it is absent or names
     * something this JVM does not know.
     */
    private static Charset declaredCharset(String charsetName) {
        if (charsetName.isBlank()) {
            return StandardCharsets.UTF_8;
        }
        try {
            return Charset.forName(charsetName.trim());
        } catch (IllegalCharsetNameException | UnsupportedCharsetException e) {
            return StandardCharsets.UTF_8;
        }
    }

    /** Resolves the HTML character references that actually occur in document text. */
    private static String decodeEntities(String text) {
        String result = text;
        Matcher matcher = NUMERIC_ENTITY.matcher(result);
        StringBuilder builder = new StringBuilder();
        while (matcher.find()) {
            String replacement;
            try {
                int radix = matcher.group(1).isEmpty() ? 10 : 16;
                replacement = Character.toString(Integer.parseInt(matcher.group(2), radix));
            } catch (IllegalArgumentException e) {
                replacement = matcher.group();
            }
            matcher.appendReplacement(builder, Matcher.quoteReplacement(replacement));
        }
        matcher.appendTail(builder);
        result = builder.toString();

        result = result.replace("&nbsp;", " ")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&mdash;", "—")
                .replace("&ndash;", "–")
                .replace("&hellip;", "…");
        // &amp; is resolved last: doing it earlier would turn "&amp;lt;" into "<".
        return result.replace("&amp;", "&");
    }
}
