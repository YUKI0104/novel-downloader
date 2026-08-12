package qimao

// 输出写入器: txt(单文件) / chapters(分章目录) / epub(手写 EPUB 2.0)。
// 忠实移植自 swiftcat.py 的 _write_single_txt / _write_chapter_txts / _write_epub。

import (
	"archive/zip"
	"bytes"
	"crypto/sha1"
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type OrderedChapter struct {
	Chapter BookChapter
	Content string
}

// WriteSingleTxt 输出单文件 TXT。
func WriteSingleTxt(book *Book, chapters []OrderedChapter, path string) error {
	var sb strings.Builder
	sb.WriteString("标题: " + book.Title + "\n")
	sb.WriteString("作者: " + book.Author + "\n\n")
	sb.WriteString("简介:\n" + book.Intro + "\n\n")
	sb.WriteString(strings.Repeat("=", 40) + "\n\n")
	for _, oc := range chapters {
		sb.WriteString(oc.Chapter.Title + "\n")
		sb.WriteString(strings.Repeat("─", min(len(oc.Chapter.Title), 40)) + "\n")
		sb.WriteString(oc.Content + "\n\n")
	}
	return os.WriteFile(path, []byte(sb.String()), 0644)
}

// WriteChapterTxts 输出分章目录。
func WriteChapterTxts(book *Book, chapters []OrderedChapter, dir string) error {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	meta := fmt.Sprintf("书名: %s\n作者: %s\n简介:\n%s", book.Title, book.Author, book.Intro)
	if err := os.WriteFile(filepath.Join(dir, "00-简介.txt"), []byte(meta), 0644); err != nil {
		return err
	}
	for i, oc := range chapters {
		name := fmt.Sprintf("%04d-%s.txt", i+1, SafeFilename(oc.Chapter.Title))
		content := fmt.Sprintf("%s\n%s\n\n%s", oc.Chapter.Title,
			strings.Repeat("─", min(len(oc.Chapter.Title), 40)), oc.Content)
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0644); err != nil {
			return err
		}
	}
	return nil
}

// WriteEpub 手写 EPUB 2.0。coverURL 若非空尝试嵌入封面图。
func WriteEpub(book *Book, chapters []OrderedChapter, path, coverURL string) error {
	uid := uuid5URL("qimao://" + book.BookID)
	safeTitle := xmlEscape(book.Title)
	safeAuthor := xmlEscape(book.Author)
	safeIntro := xmlEscape(book.Intro)
	safeTags := xmlEscape(book.Tags)

	type entry struct {
		idx int
		title, body string
	}
	entries := make([]entry, 0, len(chapters))
	for i, oc := range chapters {
		body := xmlEscape(oc.Content)
		body = strings.ReplaceAll(body, "\n", "<br/>\n")
		entries = append(entries, entry{i + 1, xmlEscape(oc.Chapter.Title), body})
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	// 1. mimetype — 必须第一个且 STORED
	h := &zip.FileHeader{Name: "mimetype", Method: zip.Store}
	if err := writeZipFile(zw, h, "application/epub+zip"); err != nil {
		return err
	}

	// 2. container.xml
	container := `<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>`
	if err := writeZipStr(zw, "META-INF/container.xml", container); err != nil {
		return err
	}

	// 3. content.opf
	manifest := []string{
		`<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>`,
		`<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>`,
		`<item id="css" href="style.css" media-type="text/css"/>`,
	}
	spine := []string{`<itemref idref="cover"/>`}
	for _, e := range entries {
		fid := fmt.Sprintf("ch%04d", e.idx)
		manifest = append(manifest, fmt.Sprintf(`<item id="%s" href="chapter-%04d.xhtml" media-type="application/xhtml+xml"/>`, fid, e.idx))
		spine = append(spine, fmt.Sprintf(`<itemref idref="%s"/>`, fid))
	}

	// 封面图
	coverImg := ""
	if coverURL != "" {
		if data, ct := fetchImage(coverURL); data != nil {
			ext := map[string]string{"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}
			e := ext[strings.Split(ct, ";")[0]]
			if e == "" {
				e = ".jpg"
			}
			name := "OEBPS/cover" + e
			if err := writeZipBytes(zw, name, data); err == nil {
				coverImg = fmt.Sprintf(`<item id="cover-img" href="cover%s" media-type="%s"/>`, e, ct)
				manifest = append([]string{coverImg}, manifest...)
			}
		}
	}

	opf := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:title>%s</dc:title>
    <dc:creator opf:role="aut">%s</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:description>%s</dc:description>
    <dc:subject>%s</dc:subject>
  </metadata>
  <manifest>
    %s
  </manifest>
  <spine toc="ncx">
    %s
  </spine>
</package>`, uid, safeTitle, safeAuthor, safeIntro, safeTags,
		strings.Join(manifest, "\n    "), strings.Join(spine, "\n    "))
	if err := writeZipStr(zw, "OEBPS/content.opf", opf); err != nil {
		return err
	}

	// 4. toc.ncx
	var nav []string
	for _, e := range entries {
		nav = append(nav, fmt.Sprintf(`    <navPoint id="nav-%04d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="chapter-%04d.xhtml"/>
    </navPoint>`, e.idx, e.idx, e.title, e.idx))
	}
	ncx := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.dtd/mil/ncx" version="2005-1" xml:lang="zh-CN">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <docAuthor><text>%s</text></docAuthor>
  <navMap>
%s
  </navMap>
</ncx>`, uid, safeTitle, safeAuthor, strings.Join(nav, "\n"))
	if err := writeZipStr(zw, "OEBPS/toc.ncx", ncx); err != nil {
		return err
	}

	// 5. cover.xhtml
	cover := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
<body style="text-align:center;padding:2em;">
  <h1>%s</h1>
  <p>作者: %s</p>
  <hr/><p>%s</p>
  <p>标签: %s</p>
</body></html>`, safeTitle, safeAuthor, safeIntro, safeTags)
	if err := writeZipStr(zw, "OEBPS/cover.xhtml", cover); err != nil {
		return err
	}

	// 6. style.css
	css := "body{font-family:sans-serif;line-height:1.8;margin:1em 2em;max-width:40em}\n" +
		"h1{text-align:center;font-size:1.3em;margin:1.5em 0 1em}\n" +
		"p{text-indent:2em;margin:.3em 0}\n"
	if err := writeZipStr(zw, "OEBPS/style.css", css); err != nil {
		return err
	}

	// 7. chapter xhtml
	for _, e := range entries {
		ch := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head>
  <title>%s</title>
  <link href="style.css" rel="stylesheet"/>
</head><body>
  <h1>%s</h1>
  %s
</body></html>`, e.title, e.title, e.body)
		if err := writeZipStr(zw, fmt.Sprintf("OEBPS/chapter-%04d.xhtml", e.idx), ch); err != nil {
			return err
		}
	}

	if err := zw.Close(); err != nil {
		return err
	}
	return os.WriteFile(path, buf.Bytes(), 0644)
}

// ---------------------------------------------------------------------------
// zip 工具
// ---------------------------------------------------------------------------

func writeZipStr(zw *zip.Writer, name, content string) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, content)
	return err
}

func writeZipBytes(zw *zip.Writer, name string, content []byte) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = w.Write(content)
	return err
}

func writeZipFile(zw *zip.Writer, h *zip.FileHeader, content string) error {
	w, err := zw.CreateHeader(h)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, content)
	return err
}

// ---------------------------------------------------------------------------
// 杂项
// ---------------------------------------------------------------------------

func xmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "'", "&#39;", "\"", "&quot;")
	return r.Replace(s)
}

func fetchImage(url string) ([]byte, string) {
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Get(url)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return nil, ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, ""
	}
	return data, resp.Header.Get("Content-Type")
}

// uuid5URL 用 SHA-1 实现 UUID v5(URL 命名空间),与 Python uuid5 一致。
func uuid5URL(name string) string {
	namespace := []byte{0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8}
	h := sha1.New()
	h.Write(namespace)
	h.Write([]byte(name))
	sum := h.Sum(nil)
	sum[6] = (sum[6] & 0x0f) | 0x50
	sum[8] = (sum[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		binary.BigEndian.Uint32(sum[0:4]),
		binary.BigEndian.Uint16(sum[4:6]),
		binary.BigEndian.Uint16(sum[6:8]),
		binary.BigEndian.Uint16(sum[8:10]),
		sum[10:16])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
