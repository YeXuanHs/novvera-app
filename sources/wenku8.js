// 轻小说文库 (wenku8) — 外置 JS 书源
// 全部逻辑照 Dart 版逐行翻译：
//   详情/目录/正文 = 官方 App 中转 API（HMAC 签名的 appver + base64 request）
//   搜索/排行       = 网页 GBK 页面
//   登录/书架       = 网页（usecookie=315360000，书架 delid 用书架项 bid）
class Wenku8Source extends BookSource {
    name = "轻小说文库"
    key = "wenku8"
    version = "1.3.0"
    minAppVersion = "1.0.0"
    url = "https://www.wenku8.net"

    base = "https://www.wenku8.net"
    relay = "https://wenku8-relay.mewx.org/"
    appVer = "1.29"
    appCode = "digital-bento"

    apiUa = "Dalvik/2.1.0 (Linux; U; Android 13; Pixel 6 Build/TQ3A.230805.001)"
    webUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    _headers(referer) {
        return {
            "User-Agent": this.webUa,
            "Referer": referer || (this.base + "/index.php"),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
    }

    async _getGbk(url, referer) {
        let res = await Network.fetchBytes("GET", url, this._headers(referer))
        return await Convert.decodeGbk(res.body)
    }

    // ---- App API（与 Dart _buildAppVer / _appApi 一致）----
    async _appver() {
        let bucket = Math.floor(Date.now() / 1000 / 60)
        let msg = this.appVer + "|" + this.appCode + "|" + bucket
        let digest = await Convert.hmacString(
            await Convert.encodeUtf8(this.appCode),
            await Convert.encodeUtf8(msg),
            "sha256",
        )
        return this.appVer + "-" + this.appCode + "-" + String(digest).substring(12, 20)
    }

    async _api(plain) {
        let body = "&appver=" + (await this._appver()) +
            "&request=" + (await Convert.encodeBase64Utf8(plain)) +
            "&timetoken=" + Date.now()
        let res = await Network.fetchBytes("POST", this.relay, {
            "User-Agent": this.apiUa,
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept-Encoding": "gzip",
        }, body)
        return await Convert.decodeUtf8(res.body)
    }

    _dataValue(block, name) {
        let re = new RegExp('<data\\s+name=[\'"]' + name + '[\'"]([^>]*)>(?:<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>|([^<]*))?</data>', "i")
        let m = re.exec(block)
        if (!m) return ""
        let cdata = (m[2] || "").trim()
        return cdata.length > 0 ? cdata : (m[3] || "").trim()
    }

    _dataAttr(block, name, attr) {
        let re = new RegExp('<data\\s+name=[\'"]' + name + '[\'"]([^>]*)>', "i")
        let m = re.exec(block)
        if (!m) return ""
        let a = new RegExp(attr + '=[\'"]([^\'"]*)[\'"]', "i")
        let am = a.exec(m[1])
        return am ? am[1] : ""
    }

    async _catalog(aid) {
        let xml = await this._api("action=book&do=list&aid=" + aid + "&t=0")
        let volumes = []
        let volRe = /<volume\s+vid=["'](\d+)["']>([\s\S]*?)<\/volume>/gi
        let vm
        while ((vm = volRe.exec(xml)) !== null) {
            let block = vm[2]
            let beforeChap = block.split(/<chapter/i)[0]
            let cdata = /<!\[CDATA\[([\s\S]*?)\]\]>/.exec(beforeChap)
            let volName = cdata ? cdata[1].trim() : ""
            if (!volName) volName = "卷" + (volumes.length + 1)
            let chapters = []
            let chapRe = /<chapter\s+cid=["'](\d+)["']><!\[CDATA\[([\s\S]*?)\]\]><\/chapter>/gi
            let cm
            while ((cm = chapRe.exec(block)) !== null) {
                chapters.push({ cid: cm[1], title: cm[2].trim(), seq: chapters.length + 1 })
            }
            if (chapters.length === 0) continue
            volumes.push({ name: volName, chapters: chapters })
        }
        return volumes
    }

    // 与 Dart parseWenku8NovelContent 一致
    _parseContent(raw) {
        let result = []
        let mdRe = /!\[[^\]]*\]\(\s*(https?:\/\/[^\s)]+?)\s*<!--image-->\s*[^)]*\)/gi
        for (let rawLine of raw.split("\r\n")) {
            let line = rawLine
            if (/^ *$/.test(line)) continue
            if (mdRe.test(line)) {
                mdRe.lastIndex = 0
                let kept = ""
                let last = 0
                let m
                while ((m = mdRe.exec(line)) !== null) {
                    let pre = line.substring(last, m.index).trim()
                    if (pre) result.push(pre)
                    let url = m[1].trim()
                    if (url.startsWith("http")) result.push(url)
                    last = m.index + m[0].length
                }
                kept = line.substring(last)
                line = kept
                if (!line.trim()) continue
            }
            mdRe.lastIndex = 0
            let marker = "<!--image-->"
            if (!line.includes(marker)) {
                let t = line.trim()
                if (t) result.push(t)
                continue
            }
            let i = 0
            while (true) {
                let start = line.indexOf(marker, i)
                if (start < 0) break
                let innerStart = start + marker.length
                let end = line.indexOf(marker, innerStart)
                if (end < 0) {
                    let t = line.trim()
                    if (t) result.push(t)
                    break
                }
                let url = line.substring(innerStart, end).trim()
                if (url.startsWith("http")) result.push(url)
                i = end + marker.length
            }
        }
        return result
    }

    // ---- 登录 / 书架 ----
    async _login(user, pwd) {
        try {
            let body = "username=" + encodeURIComponent(user) +
                "&password=" + encodeURIComponent(pwd) +
                "&usecookie=315360000&action=login&submit=" + encodeURIComponent("登 录")
            let headers = this._headers(this.base + "/login.php")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            let res = await Network.fetchBytes(
                "POST", this.base + "/login.php?do=submit", headers, body)
            let html = await Convert.decodeGbk(res.body)
            return html.includes("欢迎您") || html.includes("用户面板")
        } catch (e) {
            // 登录接口有 Cloudflare，Dio 没有浏览器指纹：交给原生 WebView 过。
            return await Network.loginWithWebview(
                this.base + "/login.php",
                ["欢迎您", "用户面板"],
                this.webUa,
                this.base + "/",
            )
        }
    }

    async _refresh() {
        let user = this.loadData("user")
        let pwd = this.loadData("pwd")
        if (user && pwd && await this._login(user, pwd)) return true
        let au = this.loadData("auto_user")
        let ap = this.loadData("auto_pwd")
        if (au && ap) return await this._login(au, ap)
        return false
    }

    init() {
        // 每次加载都重登一次拿新 cookie
        this._refresh().catch(() => {})
    }

    account = {
        login: async (account, pwd) => {
            if (!(await this._login(account, pwd))) return null
            this.saveData("user", account)
            this.saveData("pwd", pwd)
            return account
        },
        logout: () => {
            this.saveData("user", null)
            this.saveData("pwd", null)
            Network.deleteCookies(this.base + "/")
        },
        registerWebsite: "https://www.wenku8.net/register.php",
    }

    favorites = {
        title: "网络收藏",
        multiFolder: false,
        loadBooks: async (page, folder) => {
            if (page > 1) return { comics: [], maxPage: 1 }
            await this._refresh()
            let html = await this._getGbk(this.base + "/modules/article/bookcase.php")
            let doc = new HtmlDocument(html)
            let comics = []
            for (let tr of doc.querySelectorAll("table.grid tr")) {
                let a = tr.querySelector('a[href*="readbookcase.php?aid="]')
                if (!a) continue
                let href = a.attributes["href"] || ""
                let aid = (href.match(/aid=(\d+)/) || [])[1]
                let bid = (href.match(/bid=(\d+)/) || [])[1]
                if (!aid) continue
                let tds = tr.querySelectorAll("td")
                comics.push({
                    id: aid,
                    title: a.text.trim(),
                    cover: "",
                    description: tds.length > 5 ? tds[5].text.trim() : "",
                    tags: [],
                    sourceKey: this.key,
                    favoriteId: bid,
                })
            }
            return { comics: comics, maxPage: 1 }
        },
        addOrDelFavorite: async (bookId, folder, isAdding, favId) => {
            await this._refresh()
            if (isAdding) {
                let html = await this._getGbk(
                    this.base + "/modules/article/addbookcase.php?bid=" + bookId,
                    this.base + "/book/" + bookId + ".htm")
                return html.includes("处理成功") || html.includes("已经在书架")
            }
            if (!favId) return false
            let html = await this._getGbk(
                this.base + "/modules/article/bookcase.php?delid=" + favId)
            return html.includes("bookcase.php") || html.includes("书架")
        },
    }

    // ---- 网页列表（搜索 / 排行）----
    async _parseList(url) {
        let html = await this._getGbk(url)
        let doc = new HtmlDocument(html)
        let books = []
        for (let tr of doc.querySelectorAll("table.grid tr")) {
            let a = tr.querySelector('a[href*="/book/"]')
            if (!a) continue
            let m = (a.attributes["href"] || "").match(/\/book\/(\d+)\.htm/)
            if (!m) continue
            let tds = tr.querySelectorAll("td")
            books.push({
                id: m[1],
                title: a.text.trim(),
                cover: "",
                description: tds.length > 4 ? tds[4].text.trim() : "",
                tags: [],
                sourceKey: this.key,
            })
        }
        return books
    }

    search = {
        load: async (keyword, options, page) => {
            let gbk = Convert.encodeGbk(keyword)
            let bytes = new Uint8Array(gbk)
            let enc = ""
            for (let b of bytes) enc += "%" + b.toString(16).padStart(2, "0").toUpperCase()
            let url = this.base + "/modules/article/search.php?searchtype=articlename&searchkey=" +
                enc + "&page=" + page
            let books = await this._parseList(url)
            return { comics: books, maxPage: books.length >= 20 ? page + 1 : page }
        },
    }

    explore = [{
        title: "排行榜",
        type: "singlePageWithMultiPart",
        load: async () => {
            let types = {
                "总点击排行": "allvisit", "总推荐排行": "allvote",
                "月点击排行": "monthvisit", "周点击排行": "weekvisit",
                "最新入库": "postdate", "最近更新": "lastupdate",
                "总收藏量排行": "goodnum", "完结小说列表": "done",
            }
            let parts = {}
            for (let title in types) {
                parts[title] = await this._parseList(
                    this.base + "/modules/article/toplist.php?sort=" + types[title] + "&page=1")
            }
            return parts
        },
    }]

    comic = {
        loadInfo: async (id) => {
            let metaXml = await this._api("action=book&do=meta&aid=" + id + "&t=0")
            let intro = (await this._api("action=book&do=intro&aid=" + id + "&t=0")).trim()
            let name = this._dataValue(metaXml, "Title")
            let tags = this._dataAttr(metaXml, "Tags", "value")
            let volumes = await this._catalog(id)
            // BookChapters 需要 {卷名: {章节id: 标题}}
            let chapters = {}
            for (let v of volumes) {
                let group = {}
                for (let c of v.chapters) {
                    group[c.cid] = c.title
                }
                chapters[v.name] = group
            }
            return {
                id: String(id),
                title: name || "未知书名",
                cover: "https://img.wenku8.com/image/" + Math.floor(id / 1000) + "/" + id + "/" + id + "s.jpg",
                description: intro,
                tags: tags ? { "标签": tags.split(/[ ,，]+/).filter((x) => x) } : {},
                chapters: chapters,
                subId: null,
            }
        },
        loadChapterText: async (bookId, epId) => {
            // epId = "卷序号-章节cid"
            let parts = String(epId).split("-")
            let cid = parts.length > 1 ? parts.slice(1).join("-") : epId
            let raw = await this._api("action=book&do=text&aid=" + bookId + "&cid=" + cid + "&t=0")
            let segs = this._parseContent(raw)
            let images = segs.filter((x) => x.startsWith("http"))
            return { content: segs.join("\n"), images: images }
        },
        loadEp: async () => ({ images: [] }),
    }
}
