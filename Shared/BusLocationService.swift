import Foundation

/// バスロケーションシステムが返す、対象停留所への接近状況。
enum BusApproachState: Equatable {
    /// 直近のバスが `minutes` 分後に到着見込み。`nearStopName` は現在バスがいる停留所。
    /// `isAtLeast` が true のときは「あと約N分以上」という下限のみの見込みで、
    /// 正確な到着時刻ではないため秒単位のカウントダウンには使わない。
    case approaching(minutes: Int, isAtLeast: Bool, nearStopName: String?)
    /// まもなく到着（分数が出ないほど接近している）
    case imminent
    /// バスが対象停留所に到着した
    case arrived
    /// バスが対象停留所を発車した
    case departed
    /// 路線の運行がまだ始まっていない（始発前）。バスロケーション情報がないため、
    /// 時刻表ベースの到着見込み時刻（絶対時刻）だけが返る。
    case notStarted(estimatedTime: BusTime?)
    /// 運行中だが、この停留所に停車するバスが1時間以上ない（間引き運行など）。
    /// バスロケーション情報がないため、時刻表ベースの到着見込み時刻（絶対時刻）だけが返る。
    case longWait(estimatedTime: BusTime?)
    /// 本日の運行が終了している
    case finished
    /// 解析できないメッセージ（運行時間外など）。生メッセージをそのまま保持する。
    case unknown(String)
}

struct BusApproach: Equatable {
    let state: BusApproachState
    /// メッセージ取得時刻。ここに残り分数を足すと到着予測時刻になる。
    let observedAt: Date
    let rawMessage: String

    /// 到着予測時刻。ウィジェットではこの絶対時刻を使ってカウントダウン表示する。
    var predictedArrival: Date? {
        switch state {
        case .approaching(let minutes, _, _):
            return observedAt.addingTimeInterval(TimeInterval(minutes * 60))
        case .imminent, .arrived:
            return observedAt
        case .notStarted(let time), .longWait(let time):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = BusStopConfig.timeZone
            return time?.date(on: observedAt, calendar: calendar)
        case .departed, .finished, .unknown:
            return nil
        }
    }
}

enum BusLocationService {
    /// 公式サイトが5秒ごとに呼び出している案内メッセージエンドポイント。
    /// バスロケーション情報をもとにサーバー側が「あと約N分」を算出して返す。
    static func fetchApproach(stop: BusStop) async throws -> BusApproach {
        let data = try await BusAPI.fetch(
            path: "get_guide_message_v2.php",
            query: [
                "bccd": BusStopConfig.companyCode,
                "rtcd": stop.routeCode,
                "bscd": stop.code
            ]
        )

        let message = XMLRecordParser(recordElement: "get_guide_message").parse(data)
            .first?["msg"] ?? ""
        let state = parseState(from: message)
        busLogger.debug("guide message=\(message, privacy: .public) state=\(String(describing: state), privacy: .public)")
        return BusApproach(state: state, observedAt: Date(), rawMessage: message)
    }

    /// 案内メッセージ本文を状態に変換する。
    /// 実際に観測されるメッセージ例:
    ///   「現在、バスは「豊海町」付近です。あと約8分で到着します。」
    ///   「現在、バスは「勝どき駅」を通過しました。あと約13分以上かかる見込みです。」
    ///   「まもなくバスが到着します。」
    ///   「バスが到着しました。」
    ///   「バスが発車しました。」
    ///   「本日、この停留所に停車するバスの運行は終了しています。」
    ///   「この路線の運行はまだ開始されていません。この停留所への到着は07時47分頃になります。」
    ///   「この停留所に停車するバスは１時間以上ありません。次の到着は09時13分頃になります。」
    static func parseState(from message: String) -> BusApproachState {
        if message.contains("運行は終了") {
            return .finished
        }
        // 始発前はバスロケーション情報がないため、時刻表ベースの絶対時刻（07時47分など）で返ってくる
        if message.contains("運行はまだ開始") {
            return .notStarted(estimatedTime: parseScheduledTime(from: message))
        }
        // 間引き運行などで1時間以上間隔が空く場合も、バスロケーション情報がなく絶対時刻のみ返る
        if message.contains("時間以上ありません") {
            return .longWait(estimatedTime: parseScheduledTime(from: message))
        }
        // 「まもなく…到着します」は接近メッセージと語尾が似るため先に判定する
        if message.contains("まもなく") {
            return .imminent
        }
        if message.contains("到着しました") {
            return .arrived
        }
        if message.contains("発車しました") {
            return .departed
        }
        if let minutes = firstMatch(in: message, pattern: "あと約([0-9]+)分").flatMap({ Int($0) }) {
            return .approaching(
                minutes: minutes,
                // 「あと約N分以上かかる見込み」は下限のみで、到着時刻は確定していない
                isAtLeast: message.contains("分以上"),
                nearStopName: firstMatch(in: message, pattern: "「(.+?)」")
            )
        }
        return .unknown(message)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// 「07時47分」のような絶対時刻表記から時・分を取り出す
    private static func parseScheduledTime(from text: String) -> BusTime? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]{1,2})時([0-9]{1,2})分"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 2,
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              let hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange])
        else { return nil }
        return BusTime(hour: hour, minute: minute)
    }
}
