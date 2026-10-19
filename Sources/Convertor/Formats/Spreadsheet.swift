import AppKit

/// A workbook as plain strings, enough to move data between CSV, TSV, XLSX, ODS and PDF.
struct Workbook {
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    var sheets: [Sheet]

    init(sheets: [Sheet]) {
        self.sheets = sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : sheets
    }
}

enum Spreadsheet {
    // MARK: Read

    static func read(_ url: URL) async throws -> Workbook {
        switch Catalog.normalize(url) {
        case "csv": return Workbook(sheets: [.init(name: "Sheet1", rows: parseDelimited(try text(url), delimiter: ","))])
        case "tsv": return Workbook(sheets: [.init(name: "Sheet1", rows: parseDelimited(try text(url), delimiter: "\t"))])
        case "xlsx": return try await readXLSX(url)
        case "ods": return try await readODS(url)
        default:
            // XLS and Numbers: let Numbers (or LibreOffice) turn it into XLSX first.
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let xlsx = temp.appendingPathComponent("sheet.xlsx")
            if IWork.App.numbers.isInstalled {
                try await IWork.export(url, with: .numbers, as: .excel, to: xlsx)
            } else if LibreOffice.path != nil {
                try await LibreOffice.convert(url, to: "xlsx", output: xlsx)
            } else {
                throw ConvertError("Numbers is needed to read \(url.pathExtension.uppercased()) files. It's free on the Mac App Store.")
            }
            return try await readXLSX(xlsx)
        }
    }

    private static func text(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    /// RFC 4180 style parser: quoted fields may contain delimiters, quotes ("") and newlines.
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()

        func handle(_ char: Character) {
            switch char {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: row.append(field); field = ""
            case "\n", "\r\n": row.append(field); rows.append(row); row = []; field = ""
            case "\r", "\u{FEFF}": break
            default: field.append(char)
            }
        }

        while let char = iterator.next() {
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            handle(next)
                        }
                    } else { quoted = false }
                } else { field.append(char) }
            } else {
                handle(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func readXLSX(_ url: URL) async throws -> Workbook {
        let root = try await ZipPackage.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }
        let xl = root.appendingPathComponent("xl")

        func document(_ url: URL) -> XMLDocument? { try? XMLDocument(contentsOf: url, options: []) }

        let shared: [String] = document(xl.appendingPathComponent("sharedStrings.xml"))?
            .elements("si").map { $0.elements("t").map { $0.stringValue ?? "" }.joined() } ?? []

        var targets: [String: String] = [:]
        for rel in document(xl.appendingPathComponent("_rels/workbook.xml.rels"))?.elements("Relationship") ?? [] {
            if let id = rel.attribute(forName: "Id")?.stringValue, let target = rel.attribute(forName: "Target")?.stringValue {
                targets[id] = target
            }
        }

        guard let workbook = document(xl.appendingPathComponent("workbook.xml")) else {
            throw ConvertError("\(url.lastPathComponent) has no workbook")
        }
        var sheets: [Workbook.Sheet] = []
        for sheet in workbook.elements("sheet") {
            let name = sheet.attribute(forName: "name")?.stringValue ?? "Sheet\(sheets.count + 1)"
            let relID = sheet.attributes?.first { $0.localName == "id" && $0.name != "sheetId" }?.stringValue ?? ""
            guard let target = targets[relID] else { continue }
            let path = target.hasPrefix("/") ? root.appendingPathComponent(String(target.dropFirst())) : xl.appendingPathComponent(target)
            guard let xml = document(path) else { continue }

            var rows: [[String]] = []
            for row in xml.elements("row") {
                let rowIndex = (Int(row.attribute(forName: "r")?.stringValue ?? "") ?? rows.count + 1) - 1
                while rows.count < rowIndex { rows.append([]) }
                var cells: [String] = []
                for cell in row.elements("c", deep: false) {
                    let column = columnIndex(cell.attribute(forName: "r")?.stringValue) ?? cells.count
                    while cells.count < column { cells.append("") }
                    let value = cell.elements("v", deep: false).first?.stringValue ?? ""
                    switch cell.attribute(forName: "t")?.stringValue {
                    case "s": cells.append(Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "")
                    case "inlineStr": cells.append(cell.elements("t").map { $0.stringValue ?? "" }.joined())
                    case "b": cells.append(value == "1" ? "TRUE" : "FALSE")
                    default: cells.append(value)
                    }
                }
                rows.append(cells)
            }
            sheets.append(.init(name: name, rows: rows))
        }
        return Workbook(sheets: sheets)
    }

    /// "C12" → 2
    private static func columnIndex(_ reference: String?) -> Int? {
        guard let reference else { return nil }
        let letters = reference.prefix { $0.isLetter }.uppercased()
        guard !letters.isEmpty else { return nil }
        return letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    private static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    private static func readODS(_ url: URL) async throws -> Workbook {
        let root = try await ZipPackage.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let content = try? XMLDocument(contentsOf: root.appendingPathComponent("content.xml"), options: []) else {
            throw ConvertError("\(url.lastPathComponent) has no content")
        }

        var sheets: [Workbook.Sheet] = []
        for table in content.elements("table") {
            var rows: [[String]] = []
            for row in table.elements("table-row") {
                var cells: [String] = []
                for cell in row.children?.compactMap({ $0 as? XMLElement }) ?? [] where cell.localName?.hasSuffix("table-cell") == true {
                    let text = cell.elements("p").map { $0.stringValue ?? "" }.joined(separator: "\n")
                    let repeats = Int(cell.attribute(forName: "table:number-columns-repeated")?.stringValue ?? "") ?? 1
                    // Blank filler cells can repeat thousands of times; they're trimmed below anyway.
                    cells += Array(repeating: text, count: text.isEmpty ? min(repeats, 64) : min(repeats, 10_000))
                }
                while cells.last?.isEmpty == true { cells.removeLast() }
                let repeats = Int(row.attribute(forName: "table:number-rows-repeated")?.stringValue ?? "") ?? 1
                rows += Array(repeating: cells, count: cells.isEmpty ? min(repeats, 64) : min(repeats, 10_000))
            }
            while rows.last?.isEmpty == true { rows.removeLast() }
            sheets.append(.init(name: table.attribute(forName: "table:name")?.stringValue ?? "Sheet\(sheets.count + 1)", rows: rows))
        }
        return Workbook(sheets: sheets)
    }

    // MARK: Write

    static func write(_ workbook: Workbook, to output: URL, ext: String) async throws {
        switch ext {
        case "csv", "tsv":
            let delimiter: Character = ext == "tsv" ? "\t" : ","
            let body = workbook.sheets[0].rows.map { row in
                row.map { escapeDelimited($0, delimiter: delimiter) }.joined(separator: String(delimiter))
            }.joined(separator: "\n") + "\n"
            try body.write(to: output, atomically: true, encoding: .utf8)
        case "xlsx":
            try await writeXLSX(workbook, to: output)
        case "ods":
            try await writeODS(workbook, to: output)
        case "pdf":
            try await DocumentEngine.printToPDF(attributedTables(workbook), output: output)
        default:
            throw ConvertError("Can't write \(ext.uppercased()) spreadsheets")
        }
    }

    private static func escapeDelimited(_ field: String, delimiter: Character) -> String {
        if delimiter == "\t" {
            // TSV has no quoting, so flatten anything that would break the layout.
            return field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Numbers stay numbers in XLSX/ODS; anything with a leading zero ("007") stays text.
    private static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.count < 20, let value = Double(text), value.isFinite else { return nil }
        if text.hasPrefix("0") && text.count > 1 && !text.hasPrefix("0.") { return nil }
        if text.hasPrefix("+") || text.lowercased().contains("e") || text.lowercased().contains("n") { return nil }
        return value
    }

    /// "3" rather than "3.0", so values survive a round trip unchanged.
    private static func numberString(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    private static func sheetName(_ name: String, index: Int) -> String {
        let cleaned = name.filter { !"[]:*?/\\".contains($0) }.prefix(31)
        return cleaned.isEmpty ? "Sheet\(index + 1)" : String(cleaned)
    }

    private static func writeXLSX(_ workbook: Workbook, to output: URL) async throws {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var files: [(path: String, data: Data)] = []

        var overrides = "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        var sheetEntries = ""
        var relEntries = ""
        for (index, sheet) in workbook.sheets.enumerated() {
            let number = index + 1
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetEntries += "<sheet name=\"\(sheetName(sheet.name, index: index).xmlEscaped)\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            relEntries += "<Relationship Id=\"rId\(number)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"

            var data = header + "<worksheet xmlns=\"\(ns)\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                data += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = "\(columnName(c))\(r + 1)"
                    if let numeric = number(value) {
                        data += "<c r=\"\(ref)\"><v>\(numberString(numeric))</v></c>"
                    } else {
                        data += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(value.xmlEscaped)</t></is></c>"
                    }
                }
                data += "</row>"
            }
            data += "</sheetData></worksheet>"
            files.append(("xl/worksheets/sheet\(number).xml", data.utf8Data))
        }

        files.append(("[Content_Types].xml", (header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(overrides)</Types>
        """).utf8Data))
        files.append(("_rels/.rels", (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """).utf8Data))
        files.append(("xl/workbook.xml", (header + """
        <workbook xmlns="\(ns)" xmlns:r="\(rel)"><sheets>\(sheetEntries)</sheets></workbook>
        """).utf8Data))
        files.append(("xl/_rels/workbook.xml.rels", (header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relEntries)</Relationships>
        """).utf8Data))

        try await ZipPackage.write(files, to: output)
    }

    private static func writeODS(_ workbook: Workbook, to output: URL) async throws {
        var tables = ""
        for (index, sheet) in workbook.sheets.enumerated() {
            tables += "<table:table table:name=\"\(sheetName(sheet.name, index: index).xmlEscaped)\">"
            let columns = max(1, sheet.rows.map(\.count).max() ?? 1)
            tables += "<table:table-column table:number-columns-repeated=\"\(columns)\"/>"
            for row in sheet.rows {
                tables += "<table:table-row>"
                for value in row {
                    if value.isEmpty {
                        tables += "<table:table-cell/>"
                    } else if let numeric = number(value) {
                        tables += "<table:table-cell office:value-type=\"float\" office:value=\"\(numberString(numeric))\"><text:p>\(value.xmlEscaped)</text:p></table:table-cell>"
                    } else {
                        let paragraphs = value.components(separatedBy: "\n").map { "<text:p>\($0.xmlEscaped)</text:p>" }.joined()
                        tables += "<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>"
                    }
                }
                if row.isEmpty { tables += "<table:table-cell/>" }
                tables += "</table:table-row>"
            }
            if sheet.rows.isEmpty { tables += "<table:table-row><table:table-cell/></table:table-row>" }
            tables += "</table:table>"
        }

        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">\
        <office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
        <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>\
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
        </manifest:manifest>
        """
        try await ZipPackage.write([
            ("mimetype", "application/vnd.oasis.opendocument.spreadsheet".utf8Data),
            ("content.xml", content.utf8Data),
            ("META-INF/manifest.xml", manifest.utf8Data),
        ], to: output, storedFirst: "mimetype")
    }

    /// Each sheet as a bordered table, for PDF export.
    private static func attributedTables(_ workbook: Workbook) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 9)
        for sheet in workbook.sheets {
            if workbook.sheets.count > 1 {
                result.append(NSAttributedString(string: sheet.name + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            }
            let columns = max(1, sheet.rows.map(\.count).max() ?? 1)
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.collapsesBorders = true
            for (r, row) in sheet.rows.enumerated() {
                for c in 0..<columns {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(.gray)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    if r == 0 { block.backgroundColor = NSColor(white: 0.93, alpha: 1) }
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    let value = c < row.count ? row[c] : ""
                    result.append(NSAttributedString(string: value + "\n", attributes: [
                        .font: r == 0 ? NSFont.boldSystemFont(ofSize: 9) : font, .paragraphStyle: style,
                    ]))
                }
            }
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }
}
