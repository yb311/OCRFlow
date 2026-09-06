import Foundation

/// Reads a PaddleOCR character dictionary out of a model's `inference.yml`.
///
/// PaddleOCR ships each recogniser's charset inside `inference.yml` rather than
/// as a separate file, so a model downloaded from Hugging Face has to be
/// unpacked before it can decode anything. This is the Swift twin of
/// `Scripts/ppocr_dict.py`, kept in the app so an in-app download needs no
/// external tooling.
///
/// Everything here works on Unicode scalars rather than `Character`s. A charset
/// entry is often a lone combining mark — Arabic harakat, Thai vowel signs,
/// Devanagari matras — and Swift fuses such a mark with the space in front of
/// it into a single grapheme cluster, so a `Character`-based scan for the YAML
/// `"- "` marker stops dead at the first one and silently truncates the charset.
enum PPDictionary {

    /// Parses the `PostProcess.character_dict` list. Returns nil when the file
    /// carries no charset, which is the case for detection models.
    static func characters(fromInferenceYAML yaml: String) -> [String]? {
        var characters: [String] = []
        var inside = false

        for line in yaml.components(separatedBy: "\n") {
            guard inside else {
                inside = line.trimmingCharacters(in: .whitespaces) == "character_dict:"
                continue
            }
            let scalars = Array(line.unicodeScalars)
            var i = 0
            while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }

            guard i + 1 < scalars.count, scalars[i] == "-", scalars[i + 1] == " " else {
                // A non-empty line that is not an entry closes the list.
                if i < scalars.count { break }
                continue
            }
            // Keep the entry exactly as written: a space is a valid character,
            // and so is the ideographic space that opens the PP-OCR charsets.
            characters.append(unquote(Array(scalars[(i + 2)...])))
        }

        return characters.isEmpty ? nil : characters
    }

    /// Extracts the charset and writes it as the one-character-per-line file
    /// `PPRecognizer` expects.
    static func writeDictionary(fromInferenceYAML yaml: String, to url: URL) throws {
        guard let characters = characters(fromInferenceYAML: yaml) else {
            throw PPOCRError.dictionaryMissing
        }
        try (characters.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - YAML scalars

    /// Entries YAML would otherwise read as numbers or punctuation are quoted
    /// in the file, so `'1'` has to come back as `1` rather than `'1'`.
    private static func unquote(_ token: [Unicode.Scalar]) -> String {
        guard token.count >= 2, let first = token.first, let last = token.last else {
            return string(token)
        }
        let body = Array(token.dropFirst().dropLast())
        if first == "'" && last == "'" {
            return string(body).replacingOccurrences(of: "''", with: "'")
        }
        if first == "\"" && last == "\"" {
            return unescape(body)
        }
        return string(token)
    }

    private static func unescape(_ body: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var i = 0
        while i < body.count {
            guard body[i] == "\\", i + 1 < body.count else {
                out.append(body[i]); i += 1; continue
            }
            let code = body[i + 1]
            i += 2
            switch code {
            case "n":  out.append("\n")
            case "t":  out.append("\t")
            case "r":  out.append("\r")
            case "0":  out.append("\0")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "x", "u", "U":
                let width = code == "x" ? 2 : (code == "u" ? 4 : 8)
                let digits = string(Array(body[i..<min(i + width, body.count)]))
                if digits.unicodeScalars.count == width,
                   let value = UInt32(digits, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.append(scalar)
                    i += width
                } else {
                    out.append("\\"); out.append(code)
                }
            default:
                out.append(code)
            }
        }
        return String(out)
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
