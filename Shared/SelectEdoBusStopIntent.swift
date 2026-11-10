import AppIntents

struct BusRouteEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "路線" }
    static var defaultQuery = BusRouteQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ route: BusRoute) {
        self.id = route.code
        self.name = route.name
    }
}

// このファイルのクエリ（BusRouteQuery / BusStopQuery）は EntityQuery ではなく EntityStringQuery にしている。
// 素の EntityQuery（suggestedEntities だけ）だと、ウィジェットの編集画面は選択肢をポップアップメニューで出す。
// macOS 27.2.1 ではその経路で「選んだ値が編集画面に反映されない」「編集画面を閉じたあとウィジェットの
// 右クリックメニューが出なくなる」という不具合が起きる。EntityStringQuery にすると検索つきリストになり、起きない。
struct BusRouteQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BusRouteEntity] {
        let routes = try await BusDirectoryService.fetchRoutes()
        return routes.filter { identifiers.contains($0.code) }.map(BusRouteEntity.init)
    }

    func suggestedEntities() async throws -> [BusRouteEntity] {
        try await BusDirectoryService.fetchRoutes().map(BusRouteEntity.init)
    }

    func entities(matching string: String) async throws -> [BusRouteEntity] {
        let all = try await suggestedEntities()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func defaultResult() async -> BusRouteEntity? {
        BusRouteEntity(BusStopConfig.defaultRoute)
    }
}

struct BusStopEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "バス停" }
    static var defaultQuery = BusStopQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ stop: BusStop) {
        self.id = stop.id
        self.name = stop.name
    }
}

struct BusStopQuery: EntityStringQuery {
    /// 選択中の路線に属する停留所だけを候補に出すため、同じIntentの route パラメータを参照する
    @IntentParameterDependency<SelectEdoBusStopIntent>(\.$route)
    var selection

    func entities(for identifiers: [String]) async throws -> [BusStopEntity] {
        var results: [BusStopEntity] = []
        for id in identifiers {
            if let stop = await BusDirectoryService.stop(id: id) {
                results.append(BusStopEntity(stop))
            }
        }
        return results
    }

    func suggestedEntities() async throws -> [BusStopEntity] {
        let routeCode = selection?.route.id ?? BusStopConfig.defaultRoute.code
        return try await BusDirectoryService.fetchStops(routeCode: routeCode).map(BusStopEntity.init)
    }

    /// suggestedEntities() と同じく、選択中の路線の停留所だけを対象に絞り込む
    func entities(matching string: String) async throws -> [BusStopEntity] {
        let all = try await suggestedEntities()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func defaultResult() async -> BusStopEntity? {
        let routeCode = selection?.route.id ?? BusStopConfig.defaultRoute.code
        guard routeCode != BusStopConfig.defaultRoute.code else {
            return BusStopEntity(BusStopConfig.defaultStop)
        }
        // 別路線が選ばれている場合はその路線の最初の停留所を初期値にする
        let stops = try? await BusDirectoryService.fetchStops(routeCode: routeCode)
        return stops?.first.map(BusStopEntity.init)
    }
}

struct SelectEdoBusStopIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "バス停を選択" }
    static var description: IntentDescription {
        IntentDescription("到着時刻を表示する路線とバス停を選びます。")
    }

    @Parameter(title: "路線")
    var route: BusRouteEntity?

    @Parameter(title: "バス停")
    var stop: BusStopEntity?

    init() {}

    init(route: BusRouteEntity, stop: BusStopEntity) {
        self.route = route
        self.stop = stop
    }

    /// 設定値を実際のデータ取得に使う形へ解決する。未設定なら初期値にフォールバックする。
    func resolvedStop() async -> BusStop {
        if let stop, let resolved = await BusDirectoryService.stop(id: stop.id) {
            return resolved
        }
        // 路線だけ選ばれている場合はその路線の先頭停留所
        if let route, route.id != BusStopConfig.defaultRoute.code,
           let first = try? await BusDirectoryService.fetchStops(routeCode: route.id).first {
            return first
        }
        return BusStopConfig.defaultStop
    }

    func resolvedRouteName() async -> String {
        let stop = await resolvedStop()
        return await BusDirectoryService.route(code: stop.routeCode)?.name ?? ""
    }
}
