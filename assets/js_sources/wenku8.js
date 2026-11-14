// 轻小说文库 (wenku8) — 外置 JS 书源
// 账号/书架相关的 URL 与 DOM 均按 wenku8.net 实测结果实现：
//   登录  POST /login.php?do=submit           usecookie=315360000（一年，最长档）
//   书架  GET  /modules/article/bookcase.php  table.grid
//   加入  GET  /modules/article/addbookcase.php?bid={aid}
//   移除  GET  /modules/article/bookcase.php?delid={书架项bid}
// 站点是 GBK：用 Network.fetchBytes + Convert.decodeGbk，不要用 get()。
class Wenku8Source extends BookSource {
    name = "轻小说文库"
    key = "wenku8"
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = "https://www.wenku8.net"

    _base = "https://www.wenku8.net"

    _headers() {
        return {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Referer": this._base + "/index.php",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
    }

    async _getGbk(url, referer) {
        let headers = this._headers()
        if (referer) headers["Referer"] = referer
        let res = await Network.fetchBytes("GET", url, headers)
        return Convert.decodeGbk(res.body)
    }

    async _postGbk(url, data, referer) {
        let headers = this._headers()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        if (referer) headers["Referer"] = referer
        let res = await Network.fetchBytes("POST", url, headers, data)
        return Convert.decodeGbk(res.body)
    }

    // 每次加载源都重新登录一次，拿最新 cookie（一年有效）。
    async _ensureLogin() {
        let user = this._loadData("user")
        let pass = this._loadData("pass")
        if (user && pass) {
            if (await this._login(user, pass)) return true
        }
        let autoUser = this._loadData("auto_user")
        let autoPass = this._loadData("auto_pass")
        if (autoUser && autoPass) {
            return await this._login(autoUser, autoPass, true)
        }
        return false
    }

    async _login(user, pass, isAuto) {
        let body = await this._postGbk(
            this._base + "/login.php?do=submit",
            "username=" + encodeURIComponent(user) +
            "&password=" + encodeURIComponent(pass) +
            "&usecookie=315360000&action=login&submit=" + encodeURIComponent("登 录"),
            this._base + "/login.php"
        )
        let ok = body.includes("欢迎您") || body.includes("用户面板")
        if (ok) {
            this._saveData("logged_in", true)
        }
        return ok
    }

    init() {
        // 不阻塞加载；失败下次请求前会再试。
        this._ensureLogin().catch(() => {})
    }

    account = {
        login: async (account, pwd) => {
            let ok = await this._login(account, pwd)
            if (ok) {
                this._saveData("user", account)
                this._saveData("pass", pwd)
            }
            return ok ? { account: account } : null
        },
        logout: () => {
            this._saveData("user", null)
            this._saveData("pass", null)
            this._saveData("logged_in", false)
            Network.deleteCookies(this._base + "/")
        },
        registerWebsite: "https://www.wenku8.net/register.php",
    }

    search = {
        load: async (keyword, page, options) => {
            let url = this._base + "/modules/article/search.php?searchtype=articlename" +
                "&searchkey=" + encodeURIComponent(keyword) + "&page=" + page
            let html = await this._getGbk(url)
            let doc = new HTMLDocument(html)
            let books = []
            for (let tr of doc.querySelectorAll("table.grid tr")) {
                let a = tr.querySelector('a[href*="/book/"]')
                if (!a) continue
                let href = a.attributes["href"] || ""
                let m = href.match(/\/book\/(\d+)\.htm/)
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
            return { books: books, maxPage: books.length >= 20 ? page + 1 : page }
        },
    }

    favorites = {
        multiFolder: false,
        title: "网络收藏",
        loadBook: async (page, folder) => {
            if (page > 1) return []
            await this._ensureLogin()
            let html = await this._getGbk(this._base + "/modules/article/bookcase.php")
            let doc = new HTMLDocument(html)
            let books = []
            for (let tr of doc.querySelectorAll("table.grid tr")) {
                let a = tr.querySelector('a[href*="readbookcase.php?aid="]')
                if (!a) continue
                let href = a.attributes["href"] || ""
                let aid = (href.match(/aid=(\d+)/) || [])[1]
                let bid = (href.match(/bid=(\d+)/) || [])[1]
                if (!aid) continue
                let tds = tr.querySelectorAll("td")
                books.push({
                    id: aid,
                    title: a.text.trim(),
                    cover: "",
                    description: tds.length > 5 ? tds[5].text.trim() : "",
                    tags: [],
                    sourceKey: this.key,
                    favoriteId: bid,
                })
            }
            return books
        },
        addOrDelFavorite: async (bookId, folder, isAdding, favId) => {
            await this._ensureLogin()
            if (isAdding) {
                let html = await this._getGbk(
                    this._base + "/modules/article/addbookcase.php?bid=" + bookId,
                    this._base + "/book/" + bookId + ".htm"
                )
                return html.includes("处理成功") || html.includes("已经在书架")
            }
            if (!favId) return false
            let html = await this._getGbk(
                this._base + "/modules/article/bookcase.php?delid=" + favId
            )
            return html.includes("bookcase.php") || html.includes("书架")
        },
    }

    comic = {
        loadInfo: async (id) => {
            // 章节正文/目录仍在原生侧导航，这里只提供详情页能拿到的基础信息。
            let html = await this._getGbk(this._base + "/book/" + id + ".htm")
            let doc = new HTMLDocument(html)
            let title = doc.querySelector("#title")?.text?.trim() ||
                doc.querySelector("title")?.text?.split("-")[0]?.trim() || ""
            let cover = doc.querySelector("#content img")?.attributes["src"] || ""
            return {
                id: id,
                title: title,
                cover: cover,
                description: "",
                tags: [],
                chapters: null,
                subId: null,
            }
        },
        loadEp: async (comicId, epId) => ({ images: [] }),
    }
}
