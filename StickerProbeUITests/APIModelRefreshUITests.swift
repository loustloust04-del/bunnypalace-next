import XCTest
import Network

@MainActor
final class APIModelRefreshUITests: RegressionTestCase {
    func testRefreshUsesEditedAddressAndKeyWithoutSaving() throws {
        let server = try ModelListFixture()
        defer { server.stop() }
        launch(["--ui-regression-seed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        swipeToPrev()
        let gear = app.buttons["gearshape"]
        waitFor(gear, "设置入口")
        gear.tap()
        let api = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "API", "模型（API）")).firstMatch
        reveal(api)
        api.tap()
        let add = app.buttons["plus.circle.fill"].firstMatch
        waitFor(add, "添加 API")
        add.tap()

        let name = "模型刷新回归-\(UUID().uuidString.prefix(8))"
        replace(app.textFields["给这把 key 起个名字"], with: name)
        replace(app.textFields["https://api.example.com/v1"], with: server.baseURL + "/saved/v1")
        replace(app.secureTextFields["sk-..."], with: "sk-saved")
        app.buttons["保存"].tap()
        dismissPasswordPrompt()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        waitFor(card, "保存的 API 卡")
        card.tap()
        dismissPasswordPrompt()
        replace(app.textFields["https://api.example.com/v1"], with: server.baseURL + "/draft/v1", clearExisting: true)
        let showKey = app.buttons["eye"]
        reveal(showKey)
        showKey.tap()
        replace(app.textFields["sk-..."], with: "sk-draft", clearExisting: true)
        let refresh = app.buttons["刷新模型"]
        reveal(refresh)
        refresh.tap()

        let model = app.staticTexts["[route] gemini-draft"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 15), "[product] 刷新未使用输入框里的地址和 Key：\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["saved-model"].exists, "[product] 刷新仍在请求旧地址")
        snap("api-model-refresh-draft")
        let delete = app.buttons["删除这张 API 卡"]
        reveal(delete)
        delete.tap()
    }

    private func dismissPasswordPrompt() {
        for application in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = application.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) {
                notNow.tap()
                return
            }
        }
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "[setup] 找不到 \(element)")
    }

    private func replace(_ field: XCUIElement, with value: String, clearExisting: Bool = false) {
        reveal(field)
        field.tap()
        if clearExisting {
            field.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"].exists
                ? app.menuItems["Select All"]
                : app.buttons["Select All"].firstMatch
            waitFor(selectAll, "全选输入内容")
            selectAll.tap()
        }
        field.typeText(value)
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        else if app.keyboards.buttons["完成"].exists { app.keyboards.buttons["完成"].tap() }
    }
}

private final class ModelListFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "APIModelRefreshUITests.server")
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw NSError(domain: "ModelListFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "[setup] 模型列表服务未启动"])
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            let bytes = accumulated + (data ?? Data())
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil { connection.cancel() }
                else { self?.receive(connection, accumulated: bytes) }
                return
            }
            let request = String(data: bytes, encoding: .utf8) ?? ""
            let draft = request.hasPrefix("GET /draft/v1/models ")
                && request.lowercased().contains("authorization: bearer sk-draft")
            let id = draft ? "[route] gemini-draft" : "saved-model"
            let body = "{\"data\":[{\"id\":\"\(id)\"}]}"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}
