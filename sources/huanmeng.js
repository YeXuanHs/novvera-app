// 幻梦轻小说 (huanmengacg) — 外置 JS 书源
// 全部照 Dart huanmeng_client.dart 翻译：
//   搜索  /index.php/bookapi/search?password&page&size&key
//   详情  /index.php/bookapi/detail?id=
//   目录  /index.php/bookapi/chapters?id=&size=5000
//   正文  /index.php/bookapi/content?bid=&cid=
class HuanmengSource extends BookSource {
    name = "幻梦轻小说"
    key = "huanmeng"
    version = "1.6.1"
    minAppVersion = "1.0.0"
    url = "https://www.huanmengacg.com"

    base = "https://www.huanmengacg.com"
    apiPassword = "chiyu666"
    ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    headers() {
        return { "User-Agent": this.ua, "Referer": this.base + "/" }
    }

    async apiGet(path, query) {
        let q = ["password=" + encodeURIComponent(this.apiPassword)]
        for (let k in query) q.push(k + "=" + encodeURIComponent(query[k]))
        let res = await Network.get(this.base + path + "?" + q.join("&"), this.headers())
        let json = JSON.parse(res.body)
        let code = json["code"]
        if (code != null && code != 0 && code != 200 && code != 1) {
            throw "huanmeng api error: " + (json["msg"] || code)
        }
        return json
    }

    mapBook(raw) {
        let id = String(raw["id"] || "").trim()
        let cover = String(raw["pic"] || raw["picx"] || "").trim()
        if (cover.startsWith("http://")) cover = "https://" + cover.substring(7)
        return {
            id: id,
            title: String(raw["name"] || "").trim(),
            author: String(raw["author"] || "").trim(),
            cover: cover,
            description: String(raw["intro"] || raw["text"] || "").trim(),
            tags: String(raw["tags"] || raw["kind"] || "").split(/[,，、]/).map((x) => x.trim()).filter((x) => x),
            sourceKey: this.key,
        }
    }

    _decode(s) {
        return String(s || "")
            .replace(/&#(\d+);/g, (m, d) => String.fromCharCode(parseInt(d)))
            .replace(/&nbsp;/g, " ")
            .replace(/&amp;/g, "&")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/&quot;/g, '"')
    }

    _splitVolume(rawName) {
        let name = this._decode(rawName)
        let m = name.match(/^(第.+?卷|特别篇|番外|短篇|全一卷|幕间)/)
        if (!m) return ["正文", name]
        let vol = m[1]
        let title = name.substring(m[0].length).replace(/^[·\-—_\s]+/, "").trim()
        if (!title) title = vol
        return [vol, title]
    }

    async catalogData(aid) {
        let json = await this.apiGet("/index.php/bookapi/chapters", { id: String(aid), size: "5000" })
        let data = json["data"]
        let list = data && data["list"]
        if (!list || list.length === 0) throw "目录为空"
        let volMap = {}
        let volOrder = []
        for (let e of list) {
            let cid = String(e["id"] || "").trim()
            let full = String(e["name"] || "").trim()
            if (!cid || !full) continue
            let vt = this._splitVolume(full)
            let vol = vt[0]
            if (!volMap[vol]) { volMap[vol] = []; volOrder.push(vol) }
            volMap[vol].push({ seq: volMap[vol].length + 1, title: vt[1], cid: cid })
        }
        return { order: volOrder, map: volMap }
    }

    _parseContent(html) {
        let lines = []
        let images = []
        let text = String(html || "")
            // 保留图片位置：先把 img 替换成占位 URL 行
            .replace(/<img[^>]*src=["']([^"']+)["'][^>]*>/gi, (m, src) => {
                let u = src.trim()
                if (u.startsWith("//")) u = "https:" + u
                else if (!u.startsWith("http")) u = this.base + (u.startsWith("/") ? u : "/" + u)
                if (u.includes("aifun.ltd")) return ""
                if (!images.includes(u)) images.push(u)
                return "\n" + u + "\n"
            })
            .replace(/<(script|style)[\s\S]*?<\/\1>/gi, "")
            .replace(/<br\s*\/?>/gi, "\n")
            .replace(/<\/(p|div|h\d)>/gi, "\n")
            .replace(/<[^>]+>/g, "")
        for (let raw of text.split(/\r?\n/)) {
            let line = this._decode(raw).trim()
            if (!line) continue
            // 站点水印/分隔条
            if (/^[\s\-—–_=━─═]{4,}$/.test(line)) continue
            if (/^\(?https?:\/\/(www\.)?huanmengacg\.com\/?\)?$/i.test(line)) continue
            if (!line.replace(/\s+/g, "")) continue
            lines.push(line)
        }
        return { lines: lines, images: images }
    }

    search = {
        load: async (keyword, options, page) => {
            let key = String(keyword || "").trim()
            if (!key) return { comics: [], maxPage: 1 }
            let json = await this.apiGet("/index.php/bookapi/search", {
                page: String(page), size: "20", key: key,
            })
            let data = json["data"] || {}
            let list = data["list"] || []
            let comics = []
            for (let e of list) comics.push(this.mapBook(e))
            let pages = parseInt(data["pages"] || 1) || 1
            return { comics: comics, maxPage: pages }
        },
    }

    comic = {
        loadInfo: async (id) => {
            let json = await this.apiGet("/index.php/bookapi/detail", { id: String(id) })
            let data = json["data"]
            if (!data) throw "详情为空"
            let b = this.mapBook(data)
            let kind = this._decode(data["kind"] || "")
            let tags = []
            for (let part of kind.split(/[,，、]/)) {
                let t = part.trim()
                if (!t) continue
                if (t.startsWith("总字数") || t.startsWith("总点击")) continue
                if (t === "连载" || t === "完结") continue
                tags.push(t)
            }
            let chapters = {}
            try {
                let cat = await this.catalogData(String(id))
                for (let vi = 0; vi < cat.order.length; vi++) {
                    let vol = cat.order[vi]
                    let group = {}
                    for (let ci = 0; ci < cat.map[vol].length; ci++) {
                        group[(vi + 1) + "-" + (ci + 1)] = cat.map[vol][ci].title
                    }
                    chapters[vol] = group
                }
            } catch (e) {}
            return {
                id: b.id,
                title: b.title,
                subtitle: String(data["author"] || "").trim(),
                updateTime: String(data["addtime"] || "").trim() || null,
                cover: b.cover,
                description: b.description,
                tags: {
                    "作者": b.author ? [b.author] : [],
                    "状态": String(data["state"] || "").trim() ? [String(data["state"]).trim()] : [],
                    "标签": tags.length ? tags : b.tags,
                },
                chapters: chapters,
                subId: null,
            }
        },
        loadChapterText: async (bookId, epId) => {
            // epId = "卷序号-章序号"
            let parts = String(epId).split("-")
            let vol = parseInt(parts[0])
            let chap = parseInt(parts[1])
            let cat = await this.catalogData(String(bookId))
            let volName = cat.order[vol - 1]
            if (!volName || !cat.map[volName][chap - 1]) throw "章节不存在: " + epId
            let cid = cat.map[volName][chap - 1].cid
            let json = await this.apiGet("/index.php/bookapi/content", {
                bid: String(bookId), cid: cid,
            })
            let data = json["data"]
            if (!data) throw "章节正文为空"
            let html = String(data["content"] || "")
            if (html.includes("书籍已下架") && !html.includes("<img")) {
                throw "章节已下架或不可用"
            }
            let parsed = this._parseContent(html)
            return { content: parsed.lines.join("\n"), images: parsed.images }
        },
        loadEp: async () => ({ images: [] }),
    }
}
