// 哔哩轻小说 (linovelib) — 外置 JS 书源
// 照 Dart linovelib_client.dart 翻译：
//   详情  /novel/{aid}.html（og:novel:* meta）
//   目录  /novel/{aid}/catalog（div.volume / .chapter-list a）
//   正文  /novel/{aid}/{cid}.html（#TextContent，多页跟“下一页”）
//   搜索  POST /S6/（search_guard 三步 + searchkey）
//   排行  /top/{type}/{page}.html
class LinovelibSource extends BookSource {
    name = "哔哩轻小说"
    key = "linovelib"
    version = "1.4.0"
    minAppVersion = "1.0.0"
    url = "https://www.linovelib.com"

    base = "https://www.linovelib.com"
    ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    headers(referer) {
        return {
            "User-Agent": this.ua,
            "Referer": referer || (this.base + "/"),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
    }

    async getHtml(url, referer) {
        let res = await Network.get(url, this.headers(referer))
        return res.body
    }

    async getDoc(url, referer) {
        return new HtmlDocument(await this.getHtml(url, referer))
    }

    _abs(href) {
        if (!href) return ""
        if (href.startsWith("//")) return "https:" + href
        if (href.startsWith("http")) return href
        if (href.startsWith("/")) return this.base + href
        return this.base + "/" + href
    }

    _text(el) {
        return el ? String(el.text || "").replace(/\s+/g, " ").trim() : ""
    }

    // 搜索前置：search_guard 需要先拿 cookie 票据
    async _searchGuard() {
        try {
            await this.getHtml(this.base + "/", this.base + "/")
            await this.getHtml(this.base + "/S6/?search_guard=css", this.base + "/S6/")
            let js = await this.getHtml(this.base + "/S6/?search_guard=js", this.base + "/S6/")
            let m = js.match(/document\.cookie="([^"]+)"/)
            if (m) {
                let kv = m[1].split(";")[0].split("=")
                if (kv.length >= 2) {
                    Network.setCookies(this.base + "/", [{ name: kv[0], value: kv.slice(1).join("="), domain: "www.linovelib.com", path: "/" }])
                }
            }
            let r = Date.now()
            await this.getHtml(this.base + "/S6/?search_guard=redeem&r=" + r, this.base + "/S6/")
            await this.getHtml(this.base + "/S6/?search_guard=redeem&r=" + (r + 1), this.base + "/S6/")
            return true
        } catch (e) {
            return false
        }
    }

    async _parseList(url, referer) {
        let doc = await this.getDoc(url, referer)
        let books = []
        for (let a of doc.querySelectorAll('a[href*="/novel/"]')) {
            let href = a.attributes["href"] || ""
            let m = href.match(/\/novel\/(\d+)\.html/)
            if (!m) continue
            let title = this._text(a)
            if (!title) continue
            if (books.some((b) => b.id === m[1])) continue
            books.push({
                id: m[1], title: title, cover: "", description: "",
                tags: [], sourceKey: this.key,
            })
        }
        return books
    }

    search = {
        load: async (keyword, options, page) => {
            let body = "searchkey=" + encodeURIComponent(keyword) + "&searchtype=all"
            let res = await Network.post(
                this.base + "/S6/",
                {
                    "User-Agent": this.ua,
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": this.base + "/",
                    "Origin": this.base,
                },
                body,
            )
            let html = res.body
            if (html.includes("search_challenge") || html.includes("checkcode.php")) {
                await this._searchGuard()
                res = await Network.post(
                    this.base + "/S6/",
                    {
                        "User-Agent": this.ua,
                        "Content-Type": "application/x-www-form-urlencoded",
                        "Referer": this.base + "/",
                        "Origin": this.base,
                    },
                    body,
                )
                html = res.body
            }
            if (html.includes("search_challenge") || html.includes("checkcode.php")) {
                throw "哔哩轻小说搜索需要人机验证，请稍后重试"
            }
            let doc = new HtmlDocument(html)
            let books = []
            for (let a of doc.querySelectorAll(".search-result-list a[href*='/novel/'], .se-result-book a[href*='/novel/']")) {
                let href = a.attributes["href"] || ""
                let m = href.match(/\/novel\/(\d+)\.html/)
                if (!m) continue
                let title = this._text(a)
                if (!title || books.some((b) => b.id === m[1])) continue
                books.push({
                    id: m[1], title: title, cover: "", description: "",
                    tags: [], sourceKey: this.key,
                })
            }
            return { comics: books, maxPage: books.length >= 20 ? page + 1 : page }
        },
    }

    explore = [{
        title: "排行榜",
        type: "singlePageWithMultiPart",
        load: async () => {
            let types = {
                "月点击榜": "monthvisit", "周点击榜": "weekvisit",
                "月推荐榜": "monthvote", "周推荐榜": "weekvote",
                "最近更新": "lastupdate", "最新入库": "postdate",
                "收藏榜": "goodnum", "新书榜": "newhot", "全本": "done",
            }
            let parts = {}
            for (let title in types) {
                let path = types[title] === "done"
                    ? "/topfull/allvisit/1.html"
                    : "/top/" + types[title] + "/1.html"
                try {
                    parts[title] = await this._parseList(this.base + path)
                } catch (e) {
                    parts[title] = []
                }
            }
            return parts
        },
    }]

    comic = {
        loadInfo: async (id) => {
            let doc = await this.getDoc(this.base + "/novel/" + id + ".html")
            let meta = (names) => {
                for (let n of names) {
                    let el = doc.querySelector('meta[property="' + n + '"], meta[name="' + n + '"]')
                    if (el && el.attributes["content"]) return el.attributes["content"]
                }
                return ""
            }
            let name = meta(["og:novel:book_name", "og:title"])
            if (!name) name = this._text(doc.querySelector("h1.book-name")) || this._text(doc.querySelector("h1"))
            let cover = this._abs(meta(["og:image", "pic"]))
            let intro = meta(["og:description", "description"])
            let dec = doc.querySelector(".book-dec")
            if (dec) {
                let ps = []
                for (let p of dec.querySelectorAll("p")) {
                    let t = this._text(p)
                    if (t) ps.push(t)
                }
                if (ps.length) intro = ps.join("\n")
            }
            intro = intro.replace(/^[\s\S]*?内容简介[：:]/, "").trim()
            let tags = meta(["og:novel:tags"])
            let chapters = {}
            try {
                let doc2 = await this.getDoc(this.base + "/novel/" + id + "/catalog")
                let vols = doc2.querySelectorAll("div.volume")
                for (let vi = 0; vi < vols.length; vi++) {
                    let vol = vols[vi]
                    let nameEl = vol.querySelector(".volume-info .volume-title, .volume-info h2, .volume-info a, h2, h3")
                    let volName = this._text(nameEl) || ("第" + (vi + 1) + "卷")
                    let group = {}
                    let ci = 0
                    for (let a of vol.querySelectorAll(".chapter-list a, ul a")) {
                        let href = a.attributes["href"] || ""
                        let m = href.match(/\/novel\/(\d+)\/(\d+)/)
                        if (!m || m[1] !== String(id)) continue
                        let t = this._text(a)
                        if (!t) continue
                        ci++
                        group[(vi + 1) + "-" + ci] = t
                    }
                    if (Object.keys(group).length) chapters[volName] = group
                }
            } catch (e) {}
            return {
                id: String(id),
                title: name || ("小说_" + id),
                subtitle: meta(["og:novel:author", "author"]),
                updateTime: meta(["og:novel:update_time", "update"]) || null,
                cover: cover,
                description: intro,
                tags: tags ? { "标签": tags.split(/[ ,，]+/).filter((x) => x) } : {},
                chapters: chapters,
                subId: null,
            }
        },
        loadChapterText: async (bookId, epId) => {
            // epId = "卷序号-章序号"：按目录顺序反查 cid
            let parts = String(epId).split("-")
            let vol = parseInt(parts[0])
            let chap = parseInt(parts[1])
            let doc0 = await this.getDoc(this.base + "/novel/" + bookId + "/catalog")
            let vols0 = doc0.querySelectorAll("div.volume")
            let target = vols0[vol - 1]
            if (!target) throw "章节不存在: " + epId
            let cid = null
            let ci = 0
            for (let a of target.querySelectorAll(".chapter-list a, ul a")) {
                let href = a.attributes["href"] || ""
                let m = href.match(/\/novel\/(\d+)\/(\d+)/)
                if (!m || m[1] !== String(bookId)) continue
                ci++
                if (ci === chap) { cid = m[2]; break }
            }
            if (!cid) throw "章节不存在: " + epId
            let url = this.base + "/novel/" + bookId + "/" + cid + ".html"
            let lines = []
            let images = []
            let seen = {}
            let pageTitle = ""
            let guard = 0
            while (url && !seen[url] && guard < 20) {
                guard++
                seen[url] = true
                let html = await this.getHtml(url)
                let doc = new HtmlDocument(html)
                if (!pageTitle) pageTitle = this._text(doc.querySelector("#mlfy_main_text h1"))
                let tc = doc.querySelector("#TextContent")
                if (tc) {
                    // HTMLDocument 没有 remove()，直接跳过这些标签即可
                    for (let p of tc.querySelectorAll("p")) {
                        let t = this._text(p)
                        if (t) lines.push(t)
                    }
                    for (let img of tc.querySelectorAll("img")) {
                        let src = img.attributes["data-src"] || img.attributes["src"]
                        let abs = this._abs(src)
                        if (abs && !images.includes(abs)) images.push(abs)
                    }
                    if (!lines.length && !images.length) {
                        let raw = this._text(tc)
                        if (raw) lines.push(raw)
                    }
                }
                // 分页：只跟同一章的“下一页”
                let next = ""
                for (let a of doc.querySelectorAll("a")) {
                    if (this._text(a) === "下一页") { next = this._abs(a.attributes["href"]); break }
                }
                if (!next || !next.includes("/novel/" + bookId + "/" + cid)) break
                url = next
            }
            for (let src of images) if (!lines.includes(src)) lines.push(src)
            return { content: lines.join("\n"), images: images }
        },
        loadEp: async () => ({ images: [] }),
    }
}
