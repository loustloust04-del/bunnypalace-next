#if os(iOS)
import UIKit

@MainActor
final class Page2DragRefresh {
    private static let writer = DispatchQueue(label: "page2.drag-metrics", qos: .utility)
    private let link: UIUpdateLink
    private weak var view: UIView?
    private weak var layer: CALayer?
    private let location: Page2DragLocation
    private let measures = ProcessInfo.processInfo.environment["PAGE2_UI_DRAG_METRICS"] == "1"
    private var rows: [[Double]] = []
    private var lastInput: TimeInterval?
    private var appliedAt: TimeInterval?
    private var maximumFPS = 0
    private var stopped = false

    init(view: UIView, layer: CALayer, location: Page2DragLocation) {
        self.view = view
        self.layer = layer
        self.location = location
        link = UIUpdateLink(view: view)
        if measures {
            rows.reserveCapacity(7200)
            link.addAction(to: .afterUpdateComplete) { [weak self] _, info in self?.record(info) }
        }
        link.isEnabled = true
    }

    func moved() {
        guard !stopped else { return }
        if measures, lastInput != location.eventTime {
            lastInput = location.eventTime
            appliedAt = lastInput == nil ? nil : CACurrentMediaTime()
        }
        guard let screen = view?.window?.windowScene?.screen,
              screen.maximumFramesPerSecond > 0, maximumFPS != screen.maximumFramesPerSecond else { return }
        maximumFPS = screen.maximumFramesPerSecond
        let rate = Float(maximumFPS)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
    }

    private func record(_ info: UIUpdateInfo) {
        guard !stopped, measures, rows.count < 7200, let layer else { return }
        let point = layer.position
        let shown = layer.presentation()?.position
        rows.append([info.modelTime, info.estimatedPresentationTime, info.completionDeadlineTime, CACurrentMediaTime(),
                     location.eventTime ?? .nan, appliedAt ?? .nan,
                     Double(point.x), Double(point.y), Double(shown?.x ?? .nan), Double(shown?.y ?? .nan),
                     location.isLanding ? 1 : 0])
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        link.isEnabled = false
        guard measures, !rows.isEmpty else { return }
        let unlocked = Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool ?? false
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let maximumFPS = self.maximumFPS
        let samples = rows
        rows.removeAll()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page2-drag-metrics.csv")
        Self.writer.async {
            let header = "# maxFPS=\(maximumFPS),promotionUnlocked=\(unlocked),lowPowerAtStop=\(lowPower),samplePhase=afterUpdateComplete,missing=nan\n" +
                "modelTime,estimatedPresentation,deadline,sampledAt,inputTime,appliedAt,modelX,modelY,presentationX,presentationY,landing\n"
            let locale = Locale(identifier: "en_US_POSIX")
            let text = header + samples.map { $0.map { String(format: "%.6f", locale: locale, $0) }.joined(separator: ",") }.joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif
