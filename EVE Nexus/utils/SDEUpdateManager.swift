import Foundation
import SwiftUI

/// SDE 更新管理器
/// 负责协调 SDE 数据包和图标包的检查、下载、验证和更新流程
@MainActor
class SDEUpdateManager: ObservableObject {
    static let shared = SDEUpdateManager()

    // MARK: - Published Properties

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadLogs: [String] = []
    @Published var hasError = false
    @Published var isCompleted = false

    // MARK: - Private Properties

    private let updateChecker = SDEUpdateChecker.shared
    private let downloader = SDEDownloader()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// 开始更新流程
    func startUpdate() {
        isDownloading = true
        downloadProgress = 0.0
        downloadLogs = []
        hasError = false
        isCompleted = false
        progressBarIndices = [:]

        Task {
            await performUpdate()
        }
    }

    /// 重置状态
    func reset() {
        isDownloading = false
        downloadProgress = 0.0
        downloadLogs = []
        hasError = false
        isCompleted = false
        progressBarIndices = [:]
    }

    // MARK: - Private Methods

    /// 执行更新流程
    private func performUpdate() async {
        do {
            // [+] 清空下载目录
            await addLog("Clearing download directory...")
            try downloader.clearDownloadDirectory()

            // [+] 检查哪些组件需要更新
            let needsSDEUpdate = updateChecker.currentSDEVersion != updateChecker.latestSDEVersion
            let needsIconsUpdate = !updateChecker.currentIconsHash.isEmpty &&
                !updateChecker.latestIconsHash.isEmpty &&
                updateChecker.currentIconsHash != updateChecker.latestIconsHash

            await addLog("Checking update requirements...")
            await addLog("SDE needs update: \(needsSDEUpdate)")
            await addLog("Icons need update: \(needsIconsUpdate)")

            // [+] 下载 icons.zip（如果需要）
            if needsIconsUpdate {
                try await downloadAndInstallIcons()
            } else {
                await addLog("Icons already up to date, skipping download")
            }

            // [+] 下载 sde.zip（如果需要）
            if needsSDEUpdate {
                try await downloadAndInstallSDE()
            } else {
                await addLog("SDE already up to date, skipping download")
            }

            // [+] 更新完成
            isCompleted = true

            // 重新加载数据以使用新的SDE数据
            reloadDataWithNewSDE()

        } catch {
            await addLog("Update failed: \(error.localizedDescription)")
            hasError = true
        }
    }

    /// 下载并安装图标包
    private func downloadAndInstallIcons() async throws {
        // 获取下载 URL
        let iconsURL = updateChecker.latestIconsURL
        guard !iconsURL.isEmpty else {
            throw NSError(domain: "SDEUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Icons download URL not available"])
        }

        // 获取文件大小
        let iconsSize = try await downloader.getFileSize(from: iconsURL)
        let formattedSize = FormatUtil.formatFileSize(iconsSize)
        await addLog("Download icons.zip (\(formattedSize)):")
        await addLog("") // 为下载进度条预留空行

        // 下载
        try await downloader.downloadIcons(from: iconsURL) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.updateProgressBar(progress: progress, label: "icons_download")
            }
        }
        await addLog("Download icons.zip Successfully!")

        // 验证
        await addLog("Verifying icons.zip SHA256...")
        let expectedHash = updateChecker.latestIconsHashFull
        let iconsValid = try await downloader.verifyIconsHash(expectedHash: expectedHash)
        if !iconsValid {
            await addLog("[x] SHA256 verification failed")
            throw NSError(domain: "SDEUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Icons SHA256 verification failed"])
        }
        await addLog("[+] SHA256 verified")

        // 解压
        await addLog("Extracting icons.zip...")
        await addLog("") // 为解压进度条预留空行
        try await downloader.extractIcons { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.updateProgressBar(progress: progress, label: "icons_extract")
            }
        }
        await addLog("Extract icons.zip Successfully!")

        // 更新图标包哈希值到缓存
        downloader.updateIconsHash(expectedHash)
        await addLog("[+] Icons hash updated")
    }

    /// 下载并安装SDE数据包
    private func downloadAndInstallSDE() async throws {
        // 获取下载 URL
        let sdeURL = updateChecker.latestSDEURL
        guard !sdeURL.isEmpty else {
            throw NSError(domain: "SDEUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDE download URL not available"])
        }

        // 获取文件大小
        let sdeSize = try await downloader.getFileSize(from: sdeURL)
        let formattedSize = FormatUtil.formatFileSize(sdeSize)
        await addLog("Download sde.zip (\(formattedSize)):")
        await addLog("") // 为下载进度条预留空行

        // 下载
        try await downloader.downloadSDE(from: sdeURL) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.updateProgressBar(progress: progress, label: "sde_download")
            }
        }
        await addLog("Download sde.zip Successfully!")

        // 验证
        await addLog("Verifying sde.zip SHA256...")
        let expectedHash = updateChecker.latestSDEHashFull
        let sdeValid = try await downloader.verifySDEHash(expectedHash: expectedHash)
        if !sdeValid {
            await addLog("[x] SHA256 verification failed")
            throw NSError(domain: "SDEUpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDE SHA256 verification failed"])
        }
        await addLog("[+] SHA256 verified")

        // 解压
        await addLog("Extracting sde.zip...")
        await addLog("") // 为解压进度条预留空行
        try await downloader.extractSDE { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.updateProgressBar(progress: progress, label: "sde_extract")
            }
        }
        await addLog("Extract sde.zip Successfully!")
    }

    /// 添加日志
    private func addLog(_ message: String) async {
        downloadLogs.append(message)
    }

    // 存储每个阶段进度条的索引
    private var progressBarIndices: [String: Int] = [:]

    /// 更新进度条
    private func updateProgressBar(progress: Double, label: String) {
        let barLength = 24
        let filledLength = Int(progress * Double(barLength))
        let bar = String(repeating: "=", count: filledLength) +
            String(repeating: " ", count: barLength - filledLength)
        let percentage = String(format: "%.1f%%", progress * 100)
        let progressBar = "[\(bar)] \(percentage)"

        // 如果这个标签的进度条还没有创建，找到最后一个空行并记录索引
        if progressBarIndices[label] == nil {
            // 找到最后一个空行的索引
            if let lastIndex = downloadLogs.indices.last,
               downloadLogs[lastIndex].isEmpty
            {
                progressBarIndices[label] = lastIndex
            }
        }

        // 更新对应标签的进度条
        if let index = progressBarIndices[label], index < downloadLogs.count {
            downloadLogs[index] = progressBar
        }
    }

    /// 重新加载数据以使用新的SDE数据
    private func reloadDataWithNewSDE() {
        Logger.info("Reloading data with new SDE...")

        // 重新加载本地化数据
        LocalizationManager.shared.loadAccountingEntryTypes()

        // 重新加载数据库
        DatabaseManager.shared.loadDatabase()

        // 重新检查更新状态
        Task {
            await updateChecker.forceCheckForUpdates()
        }

        Logger.info("Data reload completed with new SDE")
    }
}
