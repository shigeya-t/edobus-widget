import Foundation

/// 路線・停留所の一覧を取得する。設定パネルの選択肢に使う。
enum BusDirectoryService {
    /// 一覧はほとんど変化しないため、プロセス内で短時間キャッシュして
    /// 設定パネルを開くたびに何度も取得しないようにする。
    private static let cache = DirectoryCache()

    static func fetchRoutes() async throws -> [BusRoute] {
        if let cached = await cache.routes() { return cached }

        let data = try await BusAPI.fetch(
            path: "get_route_info3.php",
            query: ["bccd": BusStopConfig.companyCode]
        )
        let routes = XMLRecordParser(recordElement: "get_route_info").parse(data).compactMap { record -> BusRoute? in
            guard let code = record["route_code"], let name = record["name"], !name.isEmpty else { return nil }
            return BusRoute(code: code, name: name)
        }
        // 空の一覧は異常。キャッシュすると復旧しなくなるため、エラーとして扱う。
        guard !routes.isEmpty else { throw BusAPIError.emptyResponse }
        await cache.setRoutes(routes)
        return routes
    }

    static func fetchStops(routeCode: String) async throws -> [BusStop] {
        if let cached = await cache.stops(routeCode: routeCode) { return cached }

        let data = try await BusAPI.fetch(
            path: "get_bus_stop_info3.php",
            query: ["bccd": BusStopConfig.companyCode, "rtcd": routeCode]
        )
        let stops = XMLRecordParser(recordElement: "get_bus_stop_info").parse(data).compactMap { record -> BusStop? in
            guard let code = record["bus_stop_code"], let name = record["name"], !name.isEmpty else { return nil }
            // 公式サイトと同様、回送区間は選択肢に出さない
            guard !name.hasPrefix("回送") else { return nil }
            return BusStop(routeCode: routeCode, code: code, name: name)
        }
        guard !stops.isEmpty else { throw BusAPIError.emptyResponse }
        await cache.setStops(stops, routeCode: routeCode)
        return stops
    }

    /// IDから停留所を復元する（名称を埋めるために一覧を引き直す）
    static func stop(id: String) async -> BusStop? {
        guard let partial = BusStop(id: id) else { return nil }
        guard let stops = try? await fetchStops(routeCode: partial.routeCode) else { return nil }
        return stops.first { $0.code == partial.code }
    }

    static func route(code: String) async -> BusRoute? {
        guard let routes = try? await fetchRoutes() else { return nil }
        return routes.first { $0.code == code }
    }
}

private actor DirectoryCache {
    private var cachedRoutes: (value: [BusRoute], at: Date)?
    private var cachedStops: [String: (value: [BusStop], at: Date)] = [:]
    private let lifetime: TimeInterval = 60 * 60

    private func isFresh(_ date: Date) -> Bool { Date().timeIntervalSince(date) < lifetime }

    func routes() -> [BusRoute]? {
        guard let cachedRoutes, isFresh(cachedRoutes.at) else { return nil }
        return cachedRoutes.value
    }

    func setRoutes(_ routes: [BusRoute]) {
        cachedRoutes = (routes, Date())
    }

    func stops(routeCode: String) -> [BusStop]? {
        guard let entry = cachedStops[routeCode], isFresh(entry.at) else { return nil }
        return entry.value
    }

    func setStops(_ stops: [BusStop], routeCode: String) {
        cachedStops[routeCode] = (stops, Date())
    }
}
