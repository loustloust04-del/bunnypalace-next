import Foundation

public enum CCMemorySync {
    /// 与 hub（isPrivateName）、种子（CatalogSeed）同一条：去掉路径后的文件名以 private_ 开头（不分大小写）就是私人文件，
    /// 不同步、不打开；只是中间带 private_ 的（project_private_repo.md）是普通文件。名单由 hub 端挡，不按内容里的字样整份扔
    public static func isExcluded(name: String) -> Bool {
        (name as NSString).lastPathComponent.lowercased().hasPrefix("private_")
    }
}
