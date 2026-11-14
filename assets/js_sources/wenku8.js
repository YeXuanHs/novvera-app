// 轻小说文库 (wenku8) — 补丁源：只补「登录」和「网络收藏」。
// 搜索 / 发现 / 详情 / 目录 / 正文 全部沿用 Dart 内置实现，这里不重复实现。
// URL 与 DOM 均为 wenku8.net 实测结果：
//   登录  POST /login.php?do=submit  usecookie=315360000（保存一年，最长档）
//   书架  GET  /modules/article/bookcase.php   table.grid
//   加入  GET  /modules/article/addbookcase.php?bid={aid}
//   移出  GET  /modules/article/bookcase.php?delid={书架项bid}
class Wenku8Patch extends BookSource {
    name = "轻小说文库"
    key = "wenku8"
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = "https://www.wenku8.net"

    base = "https://www.wenku8.net"

    headers(referer) {
        return {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Referer": referer || (this.base + "/index.php"),
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
    }

    async getGbk(url, referer) {
        let res = await Network.fetchBytes("GET", url, this.headers(referer))
        return Convert.decodeGbk(res.body)
    }

    async login(user, pwd) {
        let body = "username=" + encodeURIComponent(user) +
            "&password=" + encodeURIComponent(pwd) +
            "&usecookie=315360000&action=login&submit=" + encodeURIComponent("登 录")
        let headers = this.headers(this.base + "/login.php")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let res = await Network.fetchBytes(
            "POST",
            this.base + "/login.php?do=submit",
            headers,
            body,
        )
        let html = Convert.decodeGbk(res.body)
        return html.includes("欢迎您") || html.includes("用户面板")
    }

    // 每次加载源都重新登录一次，拿最新 cookie；账密没问题就不会“失效”。
    init() {
        this.refresh().catch(() => {})
    }

    async refresh() {
        let user = this.loadData("user")
        let pwd = this.loadData("pwd")
        if (user && pwd) {
            if (await this.login(user, pwd)) return true
        }
        let au = this.loadData("auto_user")
        let ap = this.loadData("auto_pwd")
        if (au && ap) return await this.login(au, ap)
        return false
    }

    account = {
        login: async (account, pwd) => {
            let ok = await this.login(account, pwd)
            if (!ok) return null
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
            await this.refresh()
            let html = await this.getGbk(this.base + "/modules/article/bookcase.php")
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
            return { comics: books, maxPage: 1 }
        },
        addOrDelFavorite: async (bookId, folder, isAdding, favId) => {
            await this.refresh()
            if (isAdding) {
                let html = await this.getGbk(
                    this.base + "/modules/article/addbookcase.php?bid=" + bookId,
                    this.base + "/book/" + bookId + ".htm",
                )
                return html.includes("处理成功") || html.includes("已经在书架")
            }
            if (!favId) return false
            let html = await this.getGbk(
                this.base + "/modules/article/bookcase.php?delid=" + favId,
            )
            return html.includes("bookcase.php") || html.includes("书架")
        },
    }
}
