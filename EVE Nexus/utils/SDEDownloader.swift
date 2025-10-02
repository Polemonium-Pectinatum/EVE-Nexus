import Alamofire
import CommonCrypto
import Foundation
import Zip

class SDEDownloader {
    // 获取应用版本号
    private var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "Tritanium_v\(version)"
    }

    // 获取下载目录
    private func getDownloadDirectory() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadDir = documentsPath.appendingPathComponent("SDEDownload")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        return downloadDir
    }

    // 清空下载目录
    func clearDownloadDirectory() throws {
        let downloadDir = getDownloadDirectory()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: downloadDir.path) {
            try fileManager.removeItem(at: downloadDir)
        }
        try fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    }

    // 获取文件大小
    func getFileSize(from url: String) async throws -> Int64 {
        let headers: HTTPHeaders = [
            "User-Agent": userAgent,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            AF.request(url, method: .head, headers: headers)
                .response { response in
                    if let contentLength = response.response?.allHeaderFields["Content-Length"] as? String,
                       let size = Int64(contentLength)
                    {
                        continuation.resume(returning: size)
                    } else {
                        continuation.resume(throwing: NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to get file size"]))
                    }
                }
        }
    }

    // 下载icons.zip
    func downloadIcons(from url: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destination = getDownloadDirectory().appendingPathComponent("icons.zip")

        try await downloadFile(
            from: url,
            to: destination,
            progressCallback: progressCallback
        )
    }

    // 下载sde.zip
    func downloadSDE(from url: String, progressCallback: @escaping (Double) -> Void) async throws {
        let destination = getDownloadDirectory().appendingPathComponent("sde.zip")

        try await downloadFile(
            from: url,
            to: destination,
            progressCallback: progressCallback
        )
    }

    // 验证icons.zip的SHA256
    func verifyIconsHash(expectedHash: String) async throws -> Bool {
        let localFile = getDownloadDirectory().appendingPathComponent("icons.zip")

        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            Logger.error("Icons.zip file not found at: \(localFile.path)")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Icons.zip file not found"])
        }

        // 检查文件大小
        let fileSize = try FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64 ?? 0
        Logger.info("Icons.zip file size: \(fileSize) bytes")

        let localHash = try calculateSHA256(fileURL: localFile)
        Logger.info("Local icons.zip SHA256: \(localHash)")
        Logger.info("Expected icons.zip SHA256: \(expectedHash)")

        let isValid = localHash == expectedHash
        Logger.info("Icons.zip SHA256 verification: \(isValid ? "PASSED" : "FAILED")")

        return isValid
    }

    // 验证sde.zip的SHA256
    func verifySDEHash(expectedHash: String) async throws -> Bool {
        let localFile = getDownloadDirectory().appendingPathComponent("sde.zip")

        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: localFile.path) else {
            Logger.error("SDE.zip file not found at: \(localFile.path)")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDE.zip file not found"])
        }

        // 检查文件大小
        let fileSize = try FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64 ?? 0
        Logger.info("SDE.zip file size: \(fileSize) bytes")

        let localHash = try calculateSHA256(fileURL: localFile)
        Logger.info("Local sde.zip SHA256: \(localHash)")
        Logger.info("Expected sde.zip SHA256: \(expectedHash)")

        let isValid = localHash == expectedHash
        Logger.info("SDE.zip SHA256 verification: \(isValid ? "PASSED" : "FAILED")")

        if !isValid {
            Logger.error("SHA256 comparison failed:")
            Logger.error("Local:    '\(localHash)'")
            Logger.error("Expected: '\(expectedHash)'")
        }

        return isValid
    }

    // 计算文件SHA256
    private func calculateSHA256(fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        _ = data.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // 解压SDE数据包
    func extractSDE(progressCallback: @escaping (Double) -> Void) async throws {
        let sdeZipFile = getDownloadDirectory().appendingPathComponent("sde.zip")
        let sdeDestination = getDocumentsDirectory().appendingPathComponent("sde")

        Logger.info("Starting SDE extraction from: \(sdeZipFile.path)")
        Logger.info("SDE extraction destination: \(sdeDestination.path)")

        // 检查源文件是否存在
        guard FileManager.default.fileExists(atPath: sdeZipFile.path) else {
            Logger.error("SDE.zip file not found for extraction: \(sdeZipFile.path)")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDE.zip file not found for extraction"])
        }

        // 检查源文件大小
        let sourceFileSize = try FileManager.default.attributesOfItem(atPath: sdeZipFile.path)[.size] as? Int64 ?? 0
        Logger.info("SDE.zip source file size: \(sourceFileSize) bytes")

        // 确保目标目录存在
        try FileManager.default.createDirectory(at: sdeDestination, withIntermediateDirectories: true)
        Logger.info("Created SDE destination directory: \(sdeDestination.path)")

        try await withCheckedThrowingContinuation { continuation in
            do {
                try Zip.unzipFile(sdeZipFile, destination: sdeDestination, overwrite: true, password: nil) { progress in
                    progressCallback(progress)
                }
                Logger.info("SDE extraction completed successfully")
                continuation.resume()
            } catch {
                Logger.error("SDE extraction failed: \(error)")
                continuation.resume(throwing: error)
            }
        }

        // 验证解压是否成功
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: sdeDestination.path),
           !contents.isEmpty
        {
            Logger.info("SDE extraction verification: SUCCESS - \(contents.count) files extracted")
            Logger.info("SDE extracted files: \(contents.prefix(10).joined(separator: ", "))")

            // 更新SDE版本信息到UserDefaults
            updateSDEVersionInfo()
        } else {
            Logger.error("SDE extraction verification: FAILED - directory is empty")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "SDE extraction failed: directory is empty"])
        }
    }

    // 解压图标包
    func extractIcons(progressCallback: @escaping (Double) -> Void) async throws {
        let iconsZipFile = getDownloadDirectory().appendingPathComponent("icons.zip")
        let iconsDestination = getDocumentsDirectory().appendingPathComponent("Icons")

        Logger.info("Starting Icons extraction from: \(iconsZipFile.path)")
        Logger.info("Icons extraction destination: \(iconsDestination.path)")

        // 检查源文件是否存在
        guard FileManager.default.fileExists(atPath: iconsZipFile.path) else {
            Logger.error("Icons.zip file not found for extraction: \(iconsZipFile.path)")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Icons.zip file not found for extraction"])
        }

        // 检查源文件大小
        let sourceFileSize = try FileManager.default.attributesOfItem(atPath: iconsZipFile.path)[.size] as? Int64 ?? 0
        Logger.info("Icons.zip source file size: \(sourceFileSize) bytes")

        // 清空现有图标目录
        if FileManager.default.fileExists(atPath: iconsDestination.path) {
            Logger.info("Removing existing Icons directory: \(iconsDestination.path)")
            try FileManager.default.removeItem(at: iconsDestination)
        }

        // 创建新的图标目录
        try FileManager.default.createDirectory(at: iconsDestination, withIntermediateDirectories: true)
        Logger.info("Created Icons destination directory: \(iconsDestination.path)")

        // 重置图标解压状态
        IconManager.shared.isExtractionComplete = false
        Logger.info("Reset IconManager extraction state")

        try await withCheckedThrowingContinuation { continuation in
            do {
                try Zip.unzipFile(iconsZipFile, destination: iconsDestination, overwrite: true, password: nil) { progress in
                    progressCallback(progress)
                }
                Logger.info("Icons extraction completed successfully")
                continuation.resume()
            } catch {
                Logger.error("Icons extraction failed: \(error)")
                continuation.resume(throwing: error)
            }
        }

        // 验证解压是否成功
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: iconsDestination.path),
           !contents.isEmpty
        {
            Logger.info("Icons extraction verification: SUCCESS - \(contents.count) files extracted")
            // 设置解压完成状态
            IconManager.shared.isExtractionComplete = true
        } else {
            Logger.error("Icons extraction verification: FAILED - directory is empty")
            throw NSError(domain: "SDEDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Icon extraction failed: directory is empty"])
        }
    }

    // 更新图标包哈希值
    func updateIconsHash(_ hash: String) {
        UserDefaults.standard.set(hash, forKey: "IconsZipHash")
        Logger.info("Icons hash updated to: \(hash)")
    }

    // 获取Documents目录
    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // 更新SDE版本信息到UserDefaults
    private func updateSDEVersionInfo() {
        // 获取应用版本号作为SDE数据版本
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

        // 设置本地SDE版本信息
        StaticResourceManager.shared.setLocalSDEVersion(appVersion)

        Logger.info("SDE version info updated - new SDE data is now available (v\(appVersion))")

        // 清理下载的临时文件
        StaticResourceManager.shared.cleanupDownloadFiles()

        // 可以添加通知，让应用知道SDE数据已更新
        NotificationCenter.default.post(name: NSNotification.Name("SDEDataUpdated"), object: nil)
    }

    // 通用下载方法
    private func downloadFile(
        from url: String,
        to destination: URL,
        progressCallback: @escaping (Double) -> Void
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let headers: HTTPHeaders = [
                "User-Agent": userAgent,
            ]

            // 确保目标文件不存在
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }

            AF.download(url, headers: headers, to: { _, _ in
                (destination, [.removePreviousFile, .createIntermediateDirectories])
            })
            .downloadProgress { progress in
                progressCallback(progress.fractionCompleted)
            }
            .response { response in
                if let error = response.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
