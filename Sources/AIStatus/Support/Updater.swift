import AppKit
import Foundation

/// 检查更新：读 GitHub 上最新的 Release，版本号比本机新就提示。
/// 点「更新」时下载 Release 里的 dmg，替换掉正在运行的应用再重新打开。
/// 应用自己下载的文件不带「来自互联网」的隔离标记，所以更新后不用再去「隐私与安全性」里点「仍要打开」。
/// 应用所在的文件夹没有写权限（或者应用是直接从 dmg 里打开的）时，改成打开下载页
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// 发布新版本：改 Info.plist 的版本号，运行 ./build.sh --release
    static let repo = "Lenka0605/AIStatus"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    private static let interval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    var phase: Phase = .idle
    var latest: Release?
    var lastChecked: Date?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var available: Release? {
        latest.flatMap { Self.isNewer($0.version, than: Self.currentVersion) ? $0 : nil }
    }

    var isBusy: Bool { [.checking, .downloading, .installing].contains(phase) }

    private var loop: Task<Void, Never>?

    /// 启动后过一会儿查一次，之后每 6 小时查一次
    func startAutomaticChecks() {
        guard loop == nil, Bundle.main.bundleIdentifier != nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                if Preferences.autoCheckUpdates { await self?.check() }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// manual：用户在设置里点的「检查更新」，查到新版本不再另发通知
    func check(manual: Bool = false) async {
        guard !isBusy else { return }
        phase = .checking
        defer { lastChecked = Date() }
        do {
            var req = URLRequest(url: Self.apiURL, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 还没发布过 Release
            if status == 404 { latest = nil; phase = .upToDate; return }
            guard status == 200 else { throw FetchError.http(status) }
            guard let release = Self.parse(data) else { throw FetchError.badResponse }
            latest = release
            phase = available == nil ? .upToDate : .idle
            if let new = available, !manual { Notifier.shared.updateAvailable(version: new.version) }
        } catch {
            phase = .failed(L("检查更新失败：\(error.localizedDescription)"))
        }
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return Release(version: version, page: page, dmg: dmg)
    }

    /// 「1.10.0」比「1.9.2」新；位数不同时缺的按 0 算
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 下载、校验、替换并重启。中途出错就停下来提示，原来的应用不动
    func install() async {
        guard let release = available else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard let dmg = release.dmg, app.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: folder.path) else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .downloading
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AIStatus-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: dmg)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw FetchError.http(status) }
            let image = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: image)

            phase = .installing
            let staged = try await Task.detached { try Self.stage(image: image, in: work) }.value
            try Self.relaunch(replacing: app, with: staged, cleanup: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            phase = .failed(L("更新失败：\(error.localizedDescription)"))
        }
    }

    /// 挂载 dmg，确认里面是本应用的新版本，拷出来后卸载
    nonisolated private static func stage(image: URL, in work: URL) throws -> URL {
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let found = items.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: found),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw UpdateError.invalidPackage }
        let staged = work.appendingPathComponent(found.lastPathComponent)
        try run("/usr/bin/ditto", [found.path, staged.path])
        return staged
    }

    /// 交给一个小脚本：等本进程退出后换上新版本并打开；换失败就把旧版本放回去
    private static func relaunch(replacing app: URL, with staged: URL, cleanup work: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else rm -rf "$2"; mv "$2.old" "$2"; fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             app.path, staged.path, work.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent) }
        return process.terminationStatus
    }

    enum UpdateError: LocalizedError {
        case invalidPackage
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPackage: return L("下载的安装包不对")
            case .toolFailed(let tool): return L("\(tool) 执行失败")
            }
        }
    }
}
