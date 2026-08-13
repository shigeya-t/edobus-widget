import Foundation
import os

let busLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "EdoBusWidget",
    category: "BusData"
)

enum BusAPIError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URLを組み立てられません"
        case .httpStatus(let code): return "サーバーがエラーを返しました（HTTP \(code)）"
        case .emptyResponse: return "サーバーの応答が空です"
        }
    }
}

/// BusGO!バスロケーションシステム（中央区・江戸バス）のエンドポイント。
/// 公式APIやオープンデータではなく、公開サイトが内部で使っているXMLエンドポイントを利用している。
/// HTTPSに対応していないためHTTP通信（Info.plistにATS例外が必要）。
enum BusAPI {
    static let host = "edobus.bus-go.com"

    static func url(path: String, query: [String: String]) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/" + path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    static func fetch(path: String, query: [String: String]) async throws -> Data {
        guard let url = url(path: path, query: query) else { throw BusAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 通信の有無を追跡できるよう、すべてのリクエストを記録する
        busLogger.debug("API request: \(path, privacy: .public)")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // エラーページのHTMLをXMLとして解析してしまわないよう、ステータスを確認する
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw BusAPIError.httpStatus(http.statusCode)
            }
            guard !data.isEmpty else { throw BusAPIError.emptyResponse }
            return data
        } catch {
            busLogger.error("\(path, privacy: .public) の取得に失敗: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// 繰り返し要素を持つXMLを `[要素名: 値]` の配列に変換する。
///
/// このAPIのXMLは要素間に改行とインデントが入るため、値をそのまま連結すると
/// 末尾に空白が混じって数値変換に失敗する。ここで一括してトリムしている。
final class XMLRecordParser: NSObject, XMLParserDelegate {
    private let recordElement: String
    private var records: [[String: String]] = []
    private var current: [String: String]?
    private var currentKey: String?
    private var buffer = ""

    init(recordElement: String) {
        self.recordElement = recordElement
    }

    func parse(_ data: Data) -> [[String: String]] {
        records = []
        current = nil
        currentKey = nil
        buffer = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return records
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == recordElement {
            current = [:]
            currentKey = nil
            buffer = ""
        } else if current != nil {
            currentKey = elementName
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil, currentKey != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == recordElement {
            if let current { records.append(current) }
            current = nil
            currentKey = nil
            buffer = ""
        } else if let key = currentKey, key == elementName {
            current?[key] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            currentKey = nil
            buffer = ""
        }
    }
}
