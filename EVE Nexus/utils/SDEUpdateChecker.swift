import Foundation
import SwiftUI

// SDE 更新检查器
@MainActor
class SDEUpdateChecker: ObservableObject {
    static let shared = SDEUpdateChecker()

    @Published var updateStatus: SDEUpdateStatus = .notChecked
    @Published var isChecking = false
    @Published var lastCheckTime: Date?
    @Published var updateVersion: String?
    @Published var isButtonDisabled = false

    // 详细信息
    @Published var currentSDEVersion: String = "0"
    @Published var latestSDEVersion: String = "0"
    @Published var currentIconsHash: String = ""
    @Published var latestIconsHash: String = ""

    // 完整的SHA256哈希值（用于验证）
    var latestIconsHashFull: String = ""
    var latestSDEHashFull: String = ""

    // 下载 URL（从 zip_urls 中获取）
    var latestIconsURL: String = ""
    var latestSDEURL: String = ""

    private let lastCheckTimeKey = "SDE_LastCheckTime"
    private let checkInterval: TimeInterval = 60 // 1分钟

    private init() {
        loadLastCheckTime()
    }

    // 加载上次检查时间
    private func loadLastCheckTime() {
        if let timeInterval = UserDefaults.standard.object(forKey: lastCheckTimeKey) as? TimeInterval {
            lastCheckTime = Date(timeIntervalSince1970: timeInterval)
        }
    }

    // 保存检查时间
    private func saveLastCheckTime() {
        lastCheckTime = Date()
        UserDefaults.standard.set(lastCheckTime?.timeIntervalSince1970, forKey: lastCheckTimeKey)
    }

    // 检查是否需要更新检查
    private func shouldCheckForUpdate() -> Bool {
        guard let lastCheck = lastCheckTime else { return true }
        return Date().timeIntervalSince(lastCheck) > checkInterval
    }

    // 检查更新
    func checkForUpdates() async {
        await checkForUpdates(force: false)
    }

    // 强制检查更新（忽略时间间隔）
    func forceCheckForUpdates() async {
        // 如果按钮已禁用，直接返回
        guard !isButtonDisabled else { return }

        // 禁用按钮
        isButtonDisabled = true

        // 记录开始时间
        let startTime = Date()

        // 开始检查
        await checkForUpdates(force: true)

        // 计算已用时间
        let elapsedTime = Date().timeIntervalSince(startTime)
        let remainingTime = max(0, 2.0 - elapsedTime) // 确保至少显示2秒

        // 如果还有剩余时间，等待剩余时间
        if remainingTime > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
        }

        // 重新启用按钮
        isButtonDisabled = false
    }

    // 内部检查更新方法
    private func checkForUpdates(force: Bool) async {
        // 如果正在检查，直接返回
        guard !isChecking else { return }

        // 如果不是强制检查，且不需要检查（1小时内已检查过且无更新），直接返回
        if !force, !shouldCheckForUpdate(), updateStatus == .noUpdate {
            Logger.info("1小时内已检查过且无更新，跳过检查")
            return
        }

        isChecking = true
        updateStatus = .checking

        Logger.info("开始检查SDE更新...")

        do {
            guard let url = URL(string: SDEConfig.shared.versionCheckURL) else {
                throw NetworkError.invalidURL
            }

            // 使用NetworkManager获取更新信息
            let data = try await NetworkManager.shared.fetchData(from: url, forceRefresh: force)

            // 解析JSON数据
            let decoder = JSONDecoder()
            let updateInfo = try decoder.decode(SDEUpdateInfo.self, from: data)

            Logger.info("获取到远程SDE信息: 版本 \(updateInfo.sdeVersion).\(updateInfo.patchNumber), 标签: \(updateInfo.tag)")

            // 获取当前版本信息
            let currentVersion = await getCurrentSDEVersion()
            let currentIcons = getCurrentIconsHash()
            let remoteIcons = updateInfo.sha256sum["icons.zip"] ?? ""
            let remoteSDE = updateInfo.sha256sum["sde.zip"] ?? ""

            // 获取下载 URL
            let iconsRelativePath = updateInfo.zipUrls["icons.zip"] ?? ""
            let sdeRelativePath = updateInfo.zipUrls["sde.zip"] ?? ""

            // 格式化远程版本字符串
            let remoteVersion = updateInfo.patchNumber > 0 ?
                "\(updateInfo.sdeVersion).\(updateInfo.patchNumber)" :
                "\(updateInfo.sdeVersion)"

            // 更新详细信息
            currentSDEVersion = currentVersion
            latestSDEVersion = remoteVersion
            currentIconsHash = getShortHash(currentIcons)
            latestIconsHash = getShortHash(remoteIcons)

            // 存储完整的SHA256哈希值（用于下载验证）
            latestIconsHashFull = remoteIcons
            latestSDEHashFull = remoteSDE

            // 存储下载 URL
            latestIconsURL = SDEConfig.shared.buildDownloadURL(from: iconsRelativePath)
            latestSDEURL = SDEConfig.shared.buildDownloadURL(from: sdeRelativePath)

            Logger.info("Icons 下载 URL: \(latestIconsURL)")
            Logger.info("SDE 下载 URL: \(latestSDEURL)")

            // 检查是否有更新
            let hasUpdate = await checkIfUpdateAvailable(
                remoteBuild: updateInfo.sdeVersion,
                remotePatch: updateInfo.patchNumber,
                remoteSha256sum: updateInfo.sha256sum
            )

            if hasUpdate {
                updateStatus = .hasUpdate
                updateVersion = remoteVersion
                Logger.info("发现数据包更新: 远程版本 \(remoteVersion)")
            } else {
                updateStatus = .noUpdate
                updateVersion = nil
                saveLastCheckTime() // 只有无更新时才保存时间
                Logger.info("数据包已是最新版本")
            }

        } catch {
            Logger.error("检查SDE更新失败: \(error)")
            updateStatus = .checkFailed
            updateVersion = nil
        }

        isChecking = false
    }

    // 检查是否有更新可用
    private func checkIfUpdateAvailable(remoteBuild: Int, remotePatch: Int, remoteSha256sum: [String: String]) async -> Bool {
        // 一次性获取当前版本信息并比较
        let (currentBuild, currentPatch) = await getCurrentVersion()

        // 比较版本号
        let sdeHasUpdate = compareVersions(
            remoteBuild: remoteBuild,
            remotePatch: remotePatch,
            currentBuild: currentBuild,
            currentPatch: currentPatch
        )

        Logger.info("SDE版本比较: 当前 \(currentBuild).\(currentPatch) vs 远程 \(remoteBuild).\(remotePatch), 有更新: \(sdeHasUpdate)")

        // 检查icons.zip的SHA256更新
        let iconsHasUpdate = await checkIconsUpdate(remoteSha256sum: remoteSha256sum)

        Logger.info("Icons更新检查: 有更新: \(iconsHasUpdate)")

        // 只要SDE或icons任一有更新，就返回true
        return sdeHasUpdate || iconsHasUpdate
    }

    // 一次性获取当前版本（build_number 和 patch_number）
    private func getCurrentVersion() async -> (buildNumber: Int, patchNumber: Int) {
        return await Task.detached {
            let databaseManager = DatabaseManager.shared
            let query = "SELECT build_number, patch_number FROM version_info WHERE id = 1"

            if case let .success(results) = databaseManager.executeQuery(query, useCache: false),
               let row = results.first
            {
                let buildNumber = Int(self.getBuildNumber(from: row["build_number"]))
                let patchNumber = Int(self.getBuildNumber(from: row["patch_number"]))
                return (buildNumber, patchNumber)
            } else {
                Logger.warning("无法获取当前版本，使用默认值 0.0")
                return (0, 0)
            }
        }.value
    }

    // 获取当前SDE版本（字符串格式，用于UI显示）
    private func getCurrentSDEVersion() async -> String {
        let (buildNumber, patchNumber) = await getCurrentVersion()

        if patchNumber > 0 {
            return "\(buildNumber).\(patchNumber)"
        } else {
            return "\(buildNumber)"
        }
    }

    // 获取当前图标包哈希值
    private func getCurrentIconsHash() -> String {
        return UserDefaults.standard.string(forKey: "IconsZipHash") ?? ""
    }

    // 处理数值字段可能是Int、Double或String的情况
    private nonisolated func getBuildNumber(from value: Any?) -> Double {
        if let intValue = value as? Int {
            return Double(intValue)
        } else if let doubleValue = value as? Double {
            return doubleValue
        } else if let int64Value = value as? Int64 {
            return Double(int64Value)
        } else if let stringValue = value as? String, let doubleValue = Double(stringValue) {
            return doubleValue
        } else {
            Logger.warning("无法解析数值: \(String(describing: value))")
            return 0.0
        }
    }

    // 获取SHA256的前8位
    private func getShortHash(_ hash: String) -> String {
        return String(hash.prefix(8))
    }

    // 比较版本号（直接比较整数）
    private func compareVersions(remoteBuild: Int, remotePatch: Int, currentBuild: Int, currentPatch: Int) -> Bool {
        // 先比较 build_number
        if remoteBuild > currentBuild {
            return true
        } else if remoteBuild < currentBuild {
            return false
        }

        // build_number 相同，再比较 patch_number
        return remotePatch > currentPatch
    }

    // 检查icons.zip是否有更新
    private func checkIconsUpdate(remoteSha256sum: [String: String]) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 获取本地存储的icons.zip SHA256
                let localIconsHash = UserDefaults.standard.string(forKey: "IconsZipHash")

                // 获取远程icons.zip SHA256
                let remoteIconsHash = remoteSha256sum["icons.zip"]

                Logger.info("本地Icons SHA256: \(localIconsHash ?? "无")")
                Logger.info("远程Icons SHA256: \(remoteIconsHash ?? "无")")

                // 比较SHA256
                if let local = localIconsHash, let remote = remoteIconsHash {
                    let hasUpdate = local != remote
                    Logger.info("Icons SHA256比较: \(hasUpdate ? "有更新" : "无更新")")
                    continuation.resume(returning: hasUpdate)
                } else {
                    // 如果本地或远程SHA256不存在，认为有更新
                    Logger.info("Icons SHA256缺失，认为有更新")
                    continuation.resume(returning: true)
                }
            }
        }
    }

    // 获取状态描述文本
    func getStatusText() -> String {
        // 如果按钮被禁用（在动画过程中），显示"正在检查更新"
        if isButtonDisabled {
            return NSLocalizedString("Main_Setting_Checking_Updates", comment: "")
        }

        switch updateStatus {
        case .notChecked:
            return NSLocalizedString("Main_Setting_No_Updates", comment: "")
        case .checking:
            return NSLocalizedString("Main_Setting_Checking_Updates", comment: "")
        case .noUpdate:
            return NSLocalizedString("Main_Setting_No_Updates", comment: "")
        case .hasUpdate:
            if let version = updateVersion {
                return String(format: NSLocalizedString("Main_Setting_Updates_Available_With_Version", comment: ""), version)
            } else {
                return NSLocalizedString("Main_Setting_Updates_Available", comment: "")
            }
        case .checkFailed:
            return NSLocalizedString("Main_Setting_Check_Failed", comment: "")
        }
    }

    // 获取状态图标
    func getStatusIcon() -> String? {
        switch updateStatus {
        case .notChecked, .noUpdate:
            return "checkmark.circle.fill"
        case .checking:
            return nil // 显示加载指示器
        case .hasUpdate:
            return "exclamationmark.triangle.fill"
        case .checkFailed:
            return "xmark.circle.fill"
        }
    }

    // 获取状态颜色
    func getStatusColor() -> Color {
        switch updateStatus {
        case .notChecked, .noUpdate:
            return .green
        case .checking:
            return .blue
        case .hasUpdate:
            return .red
        case .checkFailed:
            return .orange
        }
    }
}

// SDE 更新状态枚举
enum SDEUpdateStatus {
    case notChecked // 未检查
    case checking // 正在检查
    case noUpdate // 无更新
    case hasUpdate // 有更新
    case checkFailed // 检查失败
}

// 远程更新信息结构
struct SDEUpdateInfo: Codable {
    let tag: String
    let sdeVersion: Int
    let patchNumber: Int
    let sha256sum: [String: String]
    let zipUrls: [String: String]
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case tag
        case sdeVersion = "sde_version"
        case patchNumber = "patch_number"
        case sha256sum
        case zipUrls = "zip_urls"
        case updatedAt = "updated_at"
    }
}
