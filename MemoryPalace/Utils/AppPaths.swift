import Foundation

enum AppPaths {
    #if os(macOS)
    static var home: URL { checked(FileManager.default.homeDirectoryForCurrentUser) }
    #endif
    static var applicationSupport: URL {
        checked(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
    static var caches: URL {
        checked(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }
    static var documents: URL {
        checked(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    static var temporaryDirectory: URL {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.requested {
            guard let config = BenchIsolation.configuration else { BenchIsolation.fail("隔离安装前访问临时目录") }
            return checked(config.temporary)
        }
        #endif
        return FileManager.default.temporaryDirectory
    }

    static func checked(_ url: URL) -> URL {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        return BenchIsolation.checked(url)
        #else
        return url
        #endif
    }

    static func checkedPath(_ path: String) -> String {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.requested { return checked(URL(fileURLWithPath: path)).path }
        #endif
        return path
    }

    static func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                    options: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.requested {
            var contents = try FileManager.default.contentsOfDirectory(at: checked(url), includingPropertiesForKeys: nil, options: options)
            for index in contents.indices { contents[index] = checked(contents[index]) }
            return contents
        }
        #endif
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
    }

    static func contentsOfDirectory(atPath path: String) throws -> [String] {
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if BenchIsolation.requested {
            let directory = checked(URL(fileURLWithPath: path))
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for child in contents { _ = checked(directory.appendingPathComponent(child)) }
            return contents
        }
        #endif
        return try FileManager.default.contentsOfDirectory(atPath: path)
    }
}
