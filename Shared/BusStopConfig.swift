import Foundation

struct BusRoute: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let name: String
    var id: String { code }
}

struct BusStop: Identifiable, Hashable, Codable, Sendable {
    let routeCode: String
    let code: String
    let name: String

    /// 停留所コードは路線ごとの連番のため、路線コードと組で一意にする。
    var id: String { "\(routeCode):\(code)" }

    init(routeCode: String, code: String, name: String) {
        self.routeCode = routeCode
        self.code = code
        self.name = name
    }

    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.init(routeCode: String(parts[0]), code: String(parts[1]), name: "")
    }
}

enum BusStopConfig {
    static let companyCode = "03130003"
    static let companyName = "江戸バス"
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    /// 未設定のウィジェットで使う初期値（南循環・勝どき駅前）
    static let defaultRoute = BusRoute(code: "000002", name: "南循環")
    static let defaultStop = BusStop(routeCode: "000002", code: "037", name: "勝どき駅前")
}
