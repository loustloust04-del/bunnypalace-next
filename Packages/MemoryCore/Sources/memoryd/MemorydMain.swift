import Foundation
import Dispatch

@main
enum MemorydMain {
    static func main() async {
        // 输出到文件 / 管道时 Swift 的 stdout 是块缓冲，`synchronizeFile()` 刷不出来：E-6 脚本靠 grep 启动行判断就绪
        setvbuf(stdout, nil, _IOLBF, 0)
        let options: MemorydOptions
        do {
            options = try MemorydOptions.parse(CommandLine.arguments)
        } catch MemorydOptions.ParseError.help {
            print(MemorydOptions.usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((MemorydOptions.usage + "\n\n错误：\(error.localizedDescription)\n").utf8))
            exit(2)
        }

        var model = MemorydModel.fromEnvironment(modelId: options.model)
        // 带思考的模型（DeepSeek 这类）思考也算在输出上限里，4096 容易只剩思考、没正文
        if model?.wire == .openai { model?.maxTokens = 64000 }
        var judge = MemorydModel.fromEnvironment(modelId: options.judgeModel, variables: .judge)
        judge?.maxTokens = 16000
        let service: MemorydService
        do {
            service = try MemorydService(
                config: .init(floor: options.floor, profileId: options.profileId,
                              allowUnmounted: options.allowUnmounted, model: model, judge: judge),
                webRoot: MemorydResources.webRoot
            )
        } catch {
            FileHandle.standardError.write(Data("memoryd 拒绝挂载：\(error.localizedDescription)\n".utf8))
            exit(2)
        }
        let server: HTTPServer
        do {
            server = try HTTPServer(port: options.port, service: service)
            let port = try server.start()
            print("memoryd 挂在 http://127.0.0.1:\(port)/")
            print("楼层：\(options.floor.path)（profileId \(options.profileId)）")
            if let judge { print("裁判：\(judge.modelId)") }
            if let model {
                print("模型：\(model.modelId)")
            } else if options.model != nil {
                print("没接模型：环境里没有 \(MemorydModel.keyVariable)")
            }
        } catch {
            FileHandle.standardError.write(Data("memoryd 起不来：\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let stop: @Sendable () -> Void = {
            print("\nmemoryd 退出")
            server.stop()
            exit(0)
        }
        sigint.setEventHandler(handler: stop)
        sigterm.setEventHandler(handler: stop)
        sigint.resume()
        sigterm.resume()

        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
