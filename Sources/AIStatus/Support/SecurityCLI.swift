import Foundation

/// 通过 /usr/bin/security 读写钥匙串。
/// Claude Code 用同一个工具写入凭证，所以经由它读取不会弹出授权框；
/// 我们自己的 Admin Key 也这样存，避免每次重新编译后（签名变化）反复弹窗。
enum SecurityCLI {
    static func read(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        guard let result = run(args), result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        run(["add-generic-password", "-U", "-s", service, "-a", account, "-w", value])?.status == 0
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        run(["delete-generic-password", "-s", service, "-a", account])?.status == 0
    }

    private static func run(_ args: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
