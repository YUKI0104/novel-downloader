package main

// 封面 URL → webview 可渲染形式。
// WKWebView 在 wails.localhost 页面里不渲染 http://127.0.0.1 子资源,
// 番茄内核代理的封面(如 /api/preview-cover/xxx)会被解析成这种 http://127.0.0.1 URL
// → 取回字节、按需缩放、转成 data URI 返回(同源内联,必能渲染);
// 直连 https 的 CDN 封面(搜索/七猫)原样返回,不额外开销。

import (
	"bytes"
	"encoding/base64"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"image/jpeg"
	"io"
	"net/http"
	"strings"
	"time"
)

// displayableCover 返回前端可直接用作 <img src> 的封面值。
// maxW>0 时把图片等比缩到该宽度(缩略图用,减小 data URI 体积);解码失败则回退原图 base64。
func displayableCover(url string, maxW int) string {
	if !strings.HasPrefix(url, "http://127.0.0.1") && !strings.HasPrefix(url, "http://localhost") {
		return url // 直连 https 封面,直接可用
	}
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Get(url)
	if err != nil {
		appLog("封面抓取失败 %s: %v", url, err)
		return ""
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil || len(b) == 0 {
		appLog("封面抓取失败 %s: HTTP %d 空响应(%v)", url, resp.StatusCode, err)
		return ""
	}
	if resp.StatusCode != http.StatusOK {
		appLog("封面抓取非 200 %s: HTTP %d len=%d", url, resp.StatusCode, len(b))
	}
	if img, _, err := image.Decode(bytes.NewReader(b)); err == nil && maxW > 0 {
		small := scaleToWidth(img, maxW)
		var buf bytes.Buffer
		if jpeg.Encode(&buf, small, &jpeg.Options{Quality: 85}) == nil {
			return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(buf.Bytes())
		}
	}
	ct := http.DetectContentType(b)
	return "data:" + ct + ";base64," + base64.StdEncoding.EncodeToString(b)
}

// scaleToWidth 等比例缩放到指定宽度(最近邻采样,缩略图足够)。
func scaleToWidth(src image.Image, maxW int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= maxW || w == 0 || h == 0 {
		return src
	}
	nw := maxW
	nh := max(1, h*maxW/w)
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		sy := (y * h) / nh
		for x := 0; x < nw; x++ {
			sx := (x * w) / nw
			dst.Set(x, y, src.At(b.Min.X+sx, b.Min.Y+sy))
		}
	}
	return dst
}
