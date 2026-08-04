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
import java.util.HashMap;
import java.util.Map;
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
    // The UTF-32 BOMs must be tested BEFORE the UTF-16 ones: UTF-32LE begins with the whole of
    // the UTF-16LE BOM, so a UTF-16-first test claims it, decodes with a 2-byte offset, and
    // produces text riddled with NULs. (UTF-32BE begins 00 00, which no UTF-16 BOM matches, but
    // it is kept alongside its sibling.)
    private static final byte[] BOM_UTF_32LE = {(byte) 0xFF, (byte) 0xFE, 0x00, 0x00};
    private static final byte[] BOM_UTF_32BE = {0x00, 0x00, (byte) 0xFE, (byte) 0xFF};

    // `StandardCharsets` gained UTF-32 constants only in Java 22 and this module targets 21, so
    // they are resolved by name. Both are standard JDK charsets (jdk.charsets), and the native
    // image is built with `-H:+AddAllCharsets`, so they are present in either runtime. Resolved
    // defensively all the same: a null here means "decode as declared instead", never "decode
    // this UTF-32 as UTF-16".
    private static final Charset UTF_32LE = charsetOrNull("UTF-32LE");
    private static final Charset UTF_32BE = charsetOrNull("UTF-32BE");

    // <script>/<style> bodies are markup-adjacent noise, never document text, so they are
    // dropped wholly rather than having their tags stripped and their source code kept.
    //
    // The body is bounded ({0,MAX_SCRIPT_OR_STYLE_BODY}) rather than an open `.*?`. Unbounded,
    // every unclosed `<script`/`<style` start tag makes the engine scan to the end of the input
    // before failing, so a document with many of them costs O(n²) on the load thread. A script
    // or style block longer than the bound is left to the general tag-stripping below, which
    // keeps its text — worse output than dropping it, but only for a pathological input.
    private static final int MAX_SCRIPT_OR_STYLE_BODY = 1 << 20;
    private static final Pattern SCRIPT_OR_STYLE = Pattern.compile(
            "<(script|style)\\b[^>]*>.{0," + MAX_SCRIPT_OR_STYLE_BODY + "}?</\\1\\s*>",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern COMMENT = Pattern.compile("<!--.*?-->", Pattern.DOTALL);
    // Tags that imply a line break in the rendered text, so words either side stay separate.
    private static final Pattern BLOCK_BOUNDARY = Pattern.compile(
            "<\\s*/?\\s*(br|p|div|li|tr|h[1-6]|table|ul|ol|section|article|header|footer|blockquote|pre)\\b[^>]*>",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern ANY_TAG = Pattern.compile("<[^>]*>", Pattern.DOTALL);
    // Numeric (`&#233;`, `&#xE9;`) and named (`&eacute;`) character references in one pattern,
    // so a single pass resolves both. That pass is also what makes `&amp;lt;` come out as the
    // literal "&lt;": the text a replacement produces is never rescanned.
    private static final Pattern CHARACTER_REFERENCE =
            Pattern.compile("&(?:#(x?)([0-9a-fA-F]+)|([a-zA-Z][a-zA-Z0-9]{1,31}));");
    private static final Pattern BLANK_RUN = Pattern.compile("[ \\t\\x0B\\f\\r]+");
    private static final Pattern NEWLINE_RUN = Pattern.compile("\\n{3,}");

    // Names of the Latin-1 supplement references, in code point order from U+00A0 to U+00FF.
    private static final String LATIN_1_NAMES =
            "nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr "
            + "deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 "
            + "frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute "
            + "Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml "
            + "times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc "
            + "atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml "
            + "eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml "
            + "yacute thorn yuml";

    // Uppercase Greek, from U+0391. U+03A2 is unassigned and has no reference, so it is held by
    // a placeholder that is filtered out.
    private static final String GREEK_UPPER_NAMES =
            "Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron "
            + "Pi Rho - Sigma Tau Upsilon Phi Chi Psi Omega";

    // Lowercase Greek, from U+03B1.
    private static final String GREEK_LOWER_NAMES =
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron "
            + "pi rho sigmaf sigma tau upsilon phi chi psi omega";

    // Every remaining HTML 4.01 reference: the markup-significant ones, typography, and the
    // symbol and mathematical sets, as `name` / `code point` pairs.
    private static final String[] OTHER_NAMES = {
        "quot", "34", "amp", "38", "apos", "39", "lt", "60", "gt", "62",
        "OElig", "338", "oelig", "339", "Scaron", "352", "scaron", "353", "Yuml", "376",
        "fnof", "402", "circ", "710", "tilde", "732",
        "thetasym", "977", "upsih", "978", "piv", "982",
        "ensp", "8194", "emsp", "8195", "thinsp", "8201", "zwnj", "8204", "zwj", "8205",
        "lrm", "8206", "rlm", "8207", "ndash", "8211", "mdash", "8212",
        "lsquo", "8216", "rsquo", "8217", "sbquo", "8218",
        "ldquo", "8220", "rdquo", "8221", "bdquo", "8222",
        "dagger", "8224", "Dagger", "8225", "bull", "8226", "hellip", "8230",
        "permil", "8240", "prime", "8242", "Prime", "8243",
        "lsaquo", "8249", "rsaquo", "8250", "oline", "8254", "frasl", "8260", "euro", "8364",
        "image", "8465", "weierp", "8472", "real", "8476", "trade", "8482", "alefsym", "8501",
        "larr", "8592", "uarr", "8593", "rarr", "8594", "darr", "8595", "harr", "8596",
        "crarr", "8629", "lArr", "8656", "uArr", "8657", "rArr", "8658", "dArr", "8659",
        "hArr", "8660", "forall", "8704", "part", "8706", "exist", "8707", "empty", "8709",
        "nabla", "8711", "isin", "8712", "notin", "8713", "ni", "8715", "prod", "8719",
        "sum", "8721", "minus", "8722", "lowast", "8727", "radic", "8730", "prop", "8733",
        "infin", "8734", "ang", "8736", "and", "8743", "or", "8744", "cap", "8745",
        "cup", "8746", "int", "8747", "there4", "8756", "sim", "8764", "cong", "8773",
        "asymp", "8776", "ne", "8800", "equiv", "8801", "le", "8804", "ge", "8805",
        "sub", "8834", "sup", "8835", "nsub", "8836", "sube", "8838", "supe", "8839",
        "oplus", "8853", "otimes", "8855", "perp", "8869", "sdot", "8901",
        "lceil", "8968", "rceil", "8969", "lfloor", "8970", "rfloor", "8971",
        "lang", "9001", "rang", "9002", "loz", "9674",
        "spades", "9824", "clubs", "9827", "hearts", "9829", "diams", "9830"
    };

    /**
     * The complete set of HTML 4.01 named character references (plus {@code &apos;}, which HTML 5
     * added), mapped to their replacement text.
     *
     * <p>A partial table is worse than none: an unresolved {@code &eacute;} does not merely look
     * wrong, it puts a token that is not a word into every embedding built from the document.
     *
     * <p>Declared after the tables it reads — static initialisers run in source order, so a
     * field placed above them would be built from nulls.
     */
    private static final Map<String, String> NAMED_REFERENCES = buildNamedReferences();

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
     * retrieval than an imperfect de-tagging. The cost of that simplicity is that each stage
     * copies the document, so peak usage is a small multiple of the blob — bounded by the 100 MB
     * {@code maxEntityBodySize} cap the loader applies in {@code client.bal}.
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

    /**
     * Returns the charset a leading byte-order mark declares, or {@code null} if there is none.
     *
     * <p>Order matters: the four-byte UTF-32 marks are tested first because UTF-32LE
     * ({@code FF FE 00 00}) has the two-byte UTF-16LE mark as its prefix.
     */
    private static Charset charsetFromBom(byte[] bytes) {
        if (startsWith(bytes, BOM_UTF_8)) {
            return StandardCharsets.UTF_8;
        }
        if (startsWith(bytes, BOM_UTF_32LE)) {
            return UTF_32LE;
        }
        if (startsWith(bytes, BOM_UTF_32BE)) {
            return UTF_32BE;
        }
        if (startsWith(bytes, BOM_UTF_16BE)) {
            return StandardCharsets.UTF_16BE;
        }
        if (startsWith(bytes, BOM_UTF_16LE)) {
            return StandardCharsets.UTF_16LE;
        }
        return null;
    }

    /** The length of the byte-order mark {@link #charsetFromBom} matched, in the same order. */
    private static int bomLength(byte[] bytes) {
        if (startsWith(bytes, BOM_UTF_8)) {
            return BOM_UTF_8.length;
        }
        if (startsWith(bytes, BOM_UTF_32LE) || startsWith(bytes, BOM_UTF_32BE)) {
            return BOM_UTF_32LE.length;
        }
        return BOM_UTF_16BE.length;
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

    /** Resolves a charset by name, or {@code null} when this runtime does not provide it. */
    private static Charset charsetOrNull(String name) {
        try {
            return Charset.forName(name);
        } catch (IllegalCharsetNameException | UnsupportedCharsetException e) {
            return null;
        }
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

    /**
     * Resolves numeric and named HTML character references in one left-to-right pass.
     *
     * <p>A reference this table does not know, or a numeric one naming an invalid code point, is
     * left exactly as it was written: the source text is a better answer than a guess.
     */
    private static String decodeEntities(String text) {
        Matcher matcher = CHARACTER_REFERENCE.matcher(text);
        StringBuilder builder = new StringBuilder();
        while (matcher.find()) {
            String name = matcher.group(3);
            String replacement;
            if (name != null) {
                replacement = NAMED_REFERENCES.getOrDefault(name, matcher.group());
            } else {
                try {
                    int radix = matcher.group(1).isEmpty() ? 10 : 16;
                    replacement = Character.toString(Integer.parseInt(matcher.group(2), radix));
                } catch (IllegalArgumentException e) {
                    replacement = matcher.group();
                }
            }
            matcher.appendReplacement(builder, Matcher.quoteReplacement(replacement));
        }
        matcher.appendTail(builder);
        return builder.toString();
    }

    /** Assembles the named-reference table from the contiguous ranges and the explicit pairs. */
    private static Map<String, String> buildNamedReferences() {
        Map<String, String> references = new HashMap<>();
        putRange(references, LATIN_1_NAMES, 0x00A0);
        putRange(references, GREEK_UPPER_NAMES, 0x0391);
        putRange(references, GREEK_LOWER_NAMES, 0x03B1);
        for (int i = 0; i < OTHER_NAMES.length; i += 2) {
            references.put(OTHER_NAMES[i], Character.toString(Integer.parseInt(OTHER_NAMES[i + 1])));
        }
        // A non-breaking space is folded to an ordinary one: it is whitespace to every reader of
        // the document body, and leaving U+00A0 in place defeats the whitespace collapsing that
        // `htmlToText` applies right after this.
        references.put("nbsp", " ");
        return Map.copyOf(references);
    }

    /** Maps space-separated names onto consecutive code points from {@code firstCodePoint}. */
    private static void putRange(Map<String, String> references, String names, int firstCodePoint) {
        String[] parts = names.split(" ");
        for (int i = 0; i < parts.length; i++) {
            if (!"-".equals(parts[i])) {
                references.put(parts[i], Character.toString(firstCodePoint + i));
            }
        }
    }
}
