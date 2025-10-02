import Foundation

/// SDE 更新配置管理器
/// 集中管理所有 SDE 相关的 URL 配置
class SDEConfig {
    static let shared = SDEConfig()

    // MARK: - 基础配置

    /// 基础 URL（可在此处修改以切换到不同的服务器）
    private let baseURL = "https://vanquisher.online"

    /// sha256sum.json 的相对路径
    private let sha256Path = "/sha256sum.json"

    // MARK: - 公共属性

    /// 获取版本信息的完整 URL
    var versionCheckURL: String {
        return baseURL + sha256Path
    }

    /// 获取基础 URL（用于拼接相对路径）
    var baseDownloadURL: String {
        return baseURL
    }

    // MARK: - URL 构造方法

    /// 构造完整的下载 URL
    /// - Parameter relativePath: 相对路径（如 "/sde-build-3049853.03/sde.zip"）
    /// - Returns: 完整的下载 URL
    func buildDownloadURL(from relativePath: String) -> String {
        // 确保相对路径以 / 开头
        let path = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
        return baseURL + path
    }

    private init() {}
}
