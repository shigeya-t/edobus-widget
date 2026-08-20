import AppIntents
import WidgetKit

/// ウィジェット上のリロードボタン（macOS 14 以降の操作可能ウィジェット）。
/// 一時停止中でも、明示的な操作なのでこのときだけは取得を許可する。
struct RefreshEdoBusIntent: AppIntent {
    static var title: LocalizedStringResource { "更新" }
    static var description: IntentDescription {
        IntentDescription("バスの到着見込みを取得し直します。")
    }

    /// ウィジェットの操作なのでアプリを前面に出さない
    static var openAppWhenRun: Bool { false }

    /// 押されたウィジェットが表示している停留所。
    /// ウィジェットは複数配置できるため、更新要求はこの単位で記録する。
    @Parameter(title: "バス停")
    var stopID: String?

    init() {}

    init(stopID: String?) {
        self.stopID = stopID
    }

    func perform() async throws -> some IntentResult {
        AppSettings.requestManualRefresh(stopID: stopID)
        // 到着見込みの取得はAppに一本化しているため、ウィジェット自身は通信せずAppに依頼する。
        AppSettings.notifyManualRefreshRequested()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// ウィジェット上で自動更新の停止／再開を切り替える。
struct ToggleEdoBusPauseIntent: AppIntent {
    static var title: LocalizedStringResource { "自動更新の停止と再開" }
    static var description: IntentDescription {
        IntentDescription("バス情報の自動更新を一時停止、または再開します。")
    }

    static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        let paused = !AppSettings.isPaused
        AppSettings.isPaused = paused
        // 再開した直後は待たずに最新を取りに行く（対象を限定しない）
        if !paused {
            AppSettings.requestManualRefresh(stopID: nil)
        }
        AppSettings.notifyPauseStateChanged()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
