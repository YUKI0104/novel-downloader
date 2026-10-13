import CryptoKit
import Foundation

/// 七猫输出写入器：TXT（单文件 / 分章目录）+ 中文 EPUB 2.0。
/// 逐函数照搬 `~/code/novel-downloader/qimao/writers.go`：
///   `WriteSingleTxt`(:24) / `WriteChapterTxts`(:40) / `WriteEpub`(:56) /
///   `xmlEscape`(:233) / `uuid5URL`(:259)
enum QimaoWriters {

    struct OrderedChapter: Sendable {
        var chapter: QimaoModels.BookChapter
        var content: String
    }

    /// Go `len(string)` 是**字节数**（中文 3 字节/字），分隔线长度照搬字节数（上限 40）。
    private static func rule(_ title: String) -> String {
        String(repeating: "─", count: min(title.utf8.count, 40))
    }

    // MARK: - TXT

    /// writers.go:24 `WriteSingleTxt`
    static func writeSingleTxt(book: QimaoModels.Book, chapters: [OrderedChapter], path: URL) throws {
        var sb = ""
        sb += "标题: " + book.title + "\n"
        sb += "作者: " + book.author + "\n\n"
        sb += "简介:\n" + book.intro + "\n\n"
        sb += String(repeating: "=", count: 40) + "\n\n"
        for oc in chapters {
            sb += oc.chapter.title + "\n"
            sb += rule(oc.chapter.title) + "\n"
            sb += oc.content + "\n\n"
        }
        try Data(sb.utf8).write(to: path)
    }

    /// writers.go:40 `WriteChapterTxts`
    static func writeChapterTxts(book: QimaoModels.Book, chapters: [OrderedChapter], dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = "书名: \(book.title)\n作者: \(book.author)\n简介:\n\(book.intro)"
        try Data(meta.utf8).write(to: dir.appendingPathComponent("00-简介.txt"))
        for (index, oc) in chapters.enumerated() {
            let name = String(format: "%04d-", index + 1) + QimaoSign.safeFilename(oc.chapter.title) + ".txt"
            let content = "\(oc.chapter.title)\n\(rule(oc.chapter.title))\n\n\(oc.content)"
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    // MARK: - EPUB 2.0

    /// writers.go:56 `WriteEpub`（结构照搬：mimetype → container.xml → content.opf →
    /// toc.ncx → cover.xhtml → style.css → chapter-XXXX.xhtml，封面图可选嵌入）。
    static func writeEpub(book: QimaoModels.Book, chapters: [OrderedChapter], path: URL, coverURL: String) throws {
        let uid = uuid5URL("qimao://" + book.bookID)
        let safeTitle = xmlEscape(book.title)
        let safeAuthor = xmlEscape(book.author)
        let safeIntro = xmlEscape(book.intro)
        let safeTags = xmlEscape(book.tags)

        struct Entry { var idx: Int; var title: String; var body: String }
        var entries: [Entry] = []
        for (i, oc) in chapters.enumerated() {
            var body = xmlEscape(oc.content)
            body = body.replacingOccurrences(of: "\n", with: "<br/>\n")
            entries.append(Entry(idx: i + 1, title: xmlEscape(oc.chapter.title), body: body))
        }

        var files: [QimaoZip.OutEntry] = []
        let em = { (name: String, content: String) in
            files.append(QimaoZip.OutEntry(name: name, data: Data(content.utf8)))
        }

        // 1. mimetype —— 必须第一个且 STORED
        files.append(QimaoZip.OutEntry(name: "mimetype", data: Data("application/epub+zip".utf8), stored: true))

        // 2. container.xml
        em("META-INF/container.xml", """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)

        // 3. content.opf
        var manifest = [
            #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>"#,
            #"<item id="css" href="style.css" media-type="text/css"/>"#,
        ]
        var spine = [#"<itemref idref="cover"/>"#]
        for e in entries {
            let fid = String(format: "ch%04d", e.idx)
            manifest.append(#"<item id="\#(fid)" href="chapter-\#(String(format: "%04d", e.idx)).xhtml" media-type="application/xhtml+xml"/>"#)
            spine.append(#"<itemref idref="\#(fid)"/>"#)
        }

        // 封面图（拿不到就跳过，和 Go 一样不报错）
        if !coverURL.isEmpty, let (data, contentType) = fetchImage(coverURL) {
            let exts = ["image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"]
            let bare = contentType.components(separatedBy: ";")[0]
            let ext = exts[bare] ?? ".jpg"
            files.append(QimaoZip.OutEntry(name: "OEBPS/cover" + ext, data: data))
            manifest.insert(#"<item id="cover-img" href="cover\#(ext)" media-type="\#(contentType)"/>"#, at: 0)
        }

        em("OEBPS/content.opf", """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:identifier id="bookid">\(uid)</dc:identifier>
            <dc:title>\(safeTitle)</dc:title>
            <dc:creator opf:role="aut">\(safeAuthor)</dc:creator>
            <dc:language>zh-CN</dc:language>
            <dc:description>\(safeIntro)</dc:description>
            <dc:subject>\(safeTags)</dc:subject>
          </metadata>
          <manifest>
            \(manifest.joined(separator: "\n    "))
          </manifest>
          <spine toc="ncx">
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """)

        // 4. toc.ncx
        var nav: [String] = []
        for e in entries {
            nav.append("""
                <navPoint id="nav-\(String(format: "%04d", e.idx))" playOrder="\(e.idx)">
                  <navLabel><text>\(e.title)</text></navLabel>
                  <content src="chapter-\(String(format: "%04d", e.idx)).xhtml"/>
                </navPoint>
            """)
        }
        em("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.dtd/mil/ncx" version="2005-1" xml:lang="zh-CN">
          <head>
            <meta name="dtb:uid" content="\(uid)"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(safeTitle)</text></docTitle>
          <docAuthor><text>\(safeAuthor)</text></docAuthor>
          <navMap>
        \(nav.joined(separator: "\n"))
          </navMap>
        </ncx>
        """)

        // 5. cover.xhtml
        em("OEBPS/cover.xhtml", """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
        <body style="text-align:center;padding:2em;">
          <h1>\(safeTitle)</h1>
          <p>作者: \(safeAuthor)</p>
          <hr/><p>\(safeIntro)</p>
          <p>标签: \(safeTags)</p>
        </body></html>
        """)

        // 6. style.css
        em("OEBPS/style.css", "body{font-family:sans-serif;line-height:1.8;margin:1em 2em;max-width:40em}\n"
            + "h1{text-align:center;font-size:1.3em;margin:1.5em 0 1em}\n"
            + "p{text-indent:2em;margin:.3em 0}\n")

        // 7. chapter-XXXX.xhtml
        for e in entries {
            em("OEBPS/chapter-\(String(format: "%04d", e.idx)).xhtml", """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head>
              <title>\(e.title)</title>
              <link href="style.css" rel="stylesheet"/>
            </head><body>
              <h1>\(e.title)</h1>
              \(e.body)
            </body></html>
            """)
        }

        try QimaoZip.write(files).write(to: path)
    }

    // MARK: - 杂项

    /// writers.go:233 `xmlEscape`（`&` 先换，避免二次转义）
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// writers.go:252 `fetchImage`：15s 超时，失败返回 nil（不阻断导出）。
    static func fetchImage(_ urlString: String) -> (Data, String)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, String)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = (data, http.value(forHTTPHeaderField: "Content-Type") ?? "")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    /// writers.go:259 `uuid5URL`：SHA-1 版 UUID v5（URL 命名空间），与 Python uuid5 一致。
    static func uuid5URL(_ name: String) -> String {
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
                                  0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var bytes = Data(namespace)
        bytes.append(Data(name.utf8))
        var sum = [UInt8](Insecure.SHA1.hash(data: bytes))
        sum[6] = (sum[6] & 0x0F) | 0x50
        sum[8] = (sum[8] & 0x3F) | 0x80
        func hex(_ range: Range<Int>) -> String {
            sum[range].map { String(format: "%02x", $0) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }
}
