import SwiftUI
import HealthEngine

/// «Здоровье Mac»: one read-only check on demand. Nothing runs in the background between checks.
@MainActor @Observable
final class HealthModel {
    enum Phase: Equatable { case idle, checking, results }

    var phase: Phase = .idle
    private(set) var report: MacHealthReport?
    /// Cards whose «Подробнее» is open.
    var expanded: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?

    func startCheck() {
        guard phase != .checking else { return }
        phase = .checking
        task = Task { [weak self] in
            let report = await MacHealthCheck.run()
            guard let self, !Task.isCancelled else { return }
            self.apply(report)
        }
    }

    func apply(_ report: MacHealthReport) {
        self.report = report
        withAnimation(Theme.spring) { phase = .results }
        task = nil
    }

    func toggle(_ card: String) {
        withAnimation(Theme.quick) {
            if expanded.contains(card) { expanded.remove(card) } else { expanded.insert(card) }
        }
    }
}
