import Foundation
import CleanerKit

/// Cleaning-scene states for `--snapshot`. Plans are built by the real modules' plan builders, but no unit
/// is ever run: progress is faked with `CleaningSession.simulate`, so nothing on disk is touched.
@MainActor
enum MockCleaning {
    /// A moment mid-sweep with dust in the air.
    static let sweepTime = 1.0

    static func junk(_ m: AppModel, fraction: Double, module: AppModule = .junk) {
        m.selection = module
        m.junk.apply(MockData.junk)
        let title = module == .smartCare ? "Умная очистка" : "Очистка системного мусора"
        let session = CleaningSession(plan: JunkModel.plan(m.junk.selectedPairs, title: title, module: module))
        session.simulate(to: fraction, failingEvery: 9)
        session.canCancel = true
        session.frozenTime = sweepTime
        if module == .smartCare { m.smartCare.phase = .cleaning } else { m.junk.phase = .cleaning }
        m.cleaning = session
    }

    static var chrome: InstalledApp {
        MockData.apps.first { $0.name == "Google Chrome" } ?? MockData.apps[0]
    }

    static var chromeRemnants: [AppRemnant] { MockData.remnants().filter { $0.confidence >= .medium } }

    static func uninstall(_ m: AppModel, fraction: Double) {
        m.selection = .uninstaller
        m.apps = MockData.apps
        m.appsState = .loaded
        m.uninstaller.phase = .cleaning
        let session = CleaningSession(plan: UninstallerModel.uninstallPlan(chrome, remnants: chromeRemnants, running: true))
        session.activate(0)
        session.simulate(to: fraction)
        session.frozenTime = sweepTime + 0.3
        m.cleaning = session
    }

    /// User-owned leftovers are gone, the root-owned ones wait for the password prompt.
    static func uninstallAdmin(_ m: AppModel) {
        uninstall(m, fraction: 0)
        guard let session = m.cleaning,
              let admin = session.stages.firstIndex(where: { $0.title == "Системные компоненты" }) else { return }
        let before = session.stages[..<admin].reduce(Int64(0)) { $0 + $1.totalBytes }
        session.simulate(to: Double(before) / Double(max(1, session.totalBytes)))
        session.simulateAdminWait(stage: admin)
    }

    static func orphans(_ m: AppModel, fraction: Double) {
        m.selection = .uninstaller
        m.uninstaller.applyOrphans(MockData.orphans)
        m.uninstaller.phase = .cleaning
        let picked = m.uninstaller.selectedOrphanRemnants
        let session = CleaningSession(plan: UninstallerModel.removalPlan(picked, title: "Удаление остатков", byApp: true,
                                                                        groups: m.uninstaller.orphans))
        session.simulate(to: fraction)
        session.canCancel = true
        session.frozenTime = 1.1
        m.cleaning = session
    }

    static func batch(_ m: AppModel, fraction: Double) {
        m.selection = .uninstaller
        m.apps = MockData.apps
        m.appsState = .loaded
        m.uninstaller.phase = .cleaning
        let picks = MockData.apps.filter { !$0.isSystemApp }.prefix(9).map { ($0, [AppRemnant]()) }
        let session = CleaningSession(plan: UninstallerModel.batchPlan(Array(picks)))
        session.simulate(to: fraction)
        session.canCancel = true
        session.frozenTime = 0.5
        m.cleaning = session
    }

    static func duplicates(_ m: AppModel, fraction: Double) {
        m.selection = .duplicates
        m.duplicates.apply(MockData.duplicates)
        m.duplicates.phase = .cleaning
        let picked = m.duplicates.markedFiles
        let session = CleaningSession(plan: DuplicatesModel.plan(picked, urls: picked.map(\.item.url)))
        session.simulate(to: fraction)
        session.canCancel = true
        session.frozenTime = 0.3
        m.cleaning = session
    }

    /// The ring is closed and the broom is mid-flourish, right before the fade into the completion screen.
    static func done(_ m: AppModel, compact: Bool = false) {
        junk(m, fraction: 1)
        guard let session = m.cleaning else { return }
        session.simulateFinish(at: 4)
        session.frozenTime = 4.62
    }
}
