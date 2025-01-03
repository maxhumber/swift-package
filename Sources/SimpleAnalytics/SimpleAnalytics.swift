import Foundation
import WebKit

/// SimpleAnalytics allows you to send events and pageviews from Swift to Simple Analytics
///
/// - Important: Make sure the hostname matches the website domain name in Simple Analytics (without `http://` or `https://`).
///
/// ```
/// let simpleAnalytics = SimpleAnalytics(hostname: "mobileapp.yourdomain.com")
/// ```
///
/// You can create an instance where you need it, or you can make an extension and use it as a static class.
/// ```
/// import SimpleAnalytics
///
/// extension SimpleAnalytics {
///    static let shared: SimpleAnalytics = SimpleAnalytics(hostname: "mobileapp.yourdomain.com")
/// }
/// ```
public class SimpleAnalytics {
    /// The hostname of the website in Simple Analytics the tracking should be send to. Without `https://`
    let hostname: String
    private var userAgent: String?
    private let userLanguage = Locale.current.identifier
    private let userTimezone = TimeZone.current.identifier
    /// The last date a unique visit was tracked.
    private var visitDate: Date?
    private var sharedDefaultsSuiteName: String?
    
    /// Defines if the user is opted out. When set to `true`, all tracking will be skipped. This is persisted between sessions.
    public var isOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.optedOutKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: Keys.optedOutKey) }
    }
    
    /// Create the SimpleAnalytics instance that can be used to trigger events and pageviews.
    /// - Parameters:
    ///   - hostname: The hostname as found in SimpleAnalytics, without `https://`
    ///   - sharedDefaultsSuiteName: Optional. When extensions (such as a main app and widget) have a set of sharedDefaults (using an App Group) that unique users can be counted once.
    public init(hostname: String, sharedDefaultsSuiteName suiteName: String? = nil) {
        self.hostname = hostname
        if let suiteName {
            self.sharedDefaultsSuiteName = suiteName
            self.visitDate = UserDefaults(suiteName: suiteName)?.object(forKey: Keys.visitDateKey) as? Date
        } else {
            self.visitDate = UserDefaults.standard.object(forKey: Keys.visitDateKey) as? Date
        }
    }
    
    /// Track a pageview or event
    /// - Parameters:
    ///   - event: Optional event name. If `nil`, tracks a pageview.
    ///   - path: Path of the page or event as a string array, e.g., `["list", "detailview", "edit"]`.
    ///   - metadata: Optional metadata dictionary, e.g., `["plan": "premium", "referrer": "landing_page"]`.
    public func track(event: String? = nil, path: [String] = [], metadata: [String: CustomStringConvertible]? = nil) {
        Task {
            do {
                try await trackRaw(event: event, path: path, metadata: metadata)
            } catch {
                debugPrint("SimpleAnalytics: Error tracking pageview: \(error.localizedDescription)")
            }
        }
    }
    
    func trackRaw(event: String? = nil, path: [String] = [], metadata: [String: CustomStringConvertible]? = nil) async throws {
        let formattedPath = pathToString(path: path)
        let formattedMetadata = metadataToJsonString(metadata: metadata)
        if let event {
            try await trackEvent(event: event, path: formattedPath, metadata: formattedMetadata)
        } else {
            try await trackPageView(path: formattedPath, metadata: formattedMetadata)
        }
    }
    
    func trackPageView(path: String, metadata: String? = nil) async throws {
        guard !isOptedOut else { return }
        let userAgent = try await getUserAgent()
        let event = Event(
            type: .pageview,
            hostname: hostname,
            event: "pageview",
            ua: userAgent,
            path: path,
            language: userLanguage,
            timezone: userTimezone,
            unique: isUnique(),
            metadata: metadata
        )
        try await send(event: event)
    }
    
    func trackEvent(event: String, path: String = "", metadata: String? = nil) async throws {
        guard !isOptedOut else { return }
        let userAgent = try await getUserAgent()
        let event = Event(
            type: .event,
            hostname: hostname,
            event: event,
            ua: userAgent,
            path: path,
            language: userLanguage,
            timezone: userTimezone,
            unique: isUnique(),
            metadata: metadata
        )
        try await send(event: event)
    }
    
    /// Converts an array of strings to a slug structure
    /// - Parameter path: The array of paths, for example `["list", "detailview"]`.
    /// - Returns: a slug of the path, for the example `"/list/detailview"`
    func pathToString(path: [String]) -> String {
        "/" + path.compactMap { convertToSlug(string: $0) }.joined(separator: "/")
    }
    
    func convertToSlug(string: String) -> String? {
        let slugSafeCharacters = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-")
        if let latin = string.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Lower;"), reverse: false) {
            let urlComponents = latin.components(separatedBy: slugSafeCharacters.inverted)
            let result = urlComponents.filter { $0 != "" }.joined(separator: "-")
            if result.count > 0 { return result }
        }
        return nil
    }
    
    /// Serializes metadata dictionary into a JSON string.
    /// - Parameter metadata: The metadata dictionary, which is optional.
    /// - Returns: A JSON string representation of the metadata or nil if serialization fails or metadata is nil/empty.
    func metadataToJsonString(metadata: [String: CustomStringConvertible]?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [])
            return String(data: data, encoding: .utf8)
        } catch {
            print("Error serializing metadata to JSON string: \(error)")
            return nil
        }
    }
    
    /// Simple Analytics uses the `isUnique` flag to determine visitors from pageviews. The first event/pageview for the day
    /// should get this `isUnique` flag.
    /// - Returns: if this is a unique first visit for today
    func isUnique() -> Bool {
        if let visitDate, Calendar.current.isDateInToday(visitDate) {
            return false
        }
        visitDate = Date()
        let defaults = UserDefaults(suiteName: sharedDefaultsSuiteName) ?? UserDefaults.standard
        defaults.set(visitDate, forKey: Keys.visitDateKey)
        return true
    }
    
    /// Get the cached userAgent or fetch a new one
    @MainActor
    func getUserAgent() async throws -> String {
        if let userAgent { return userAgent }
        let webView = WKWebView(frame: .zero)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        let result = try await webView.evaluateJavaScript("navigator.userAgent")
        let newUserAgent = result as! String
        userAgent = newUserAgent
        return newUserAgent
    }
    
    func send(event: Event) async throws {
        guard let url = URL(string: "https://queue.simpleanalyticscdn.com/events") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jsonData = try JSONEncoder().encode(event)
        request.httpBody = jsonData
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(httpResponse.statusCode) else { throw URLError(URLError.Code(rawValue: httpResponse.statusCode)) }
    }
}

extension SimpleAnalytics {
    struct Keys {
        static let visitDateKey = "simpleanalytics.visitdate"
        static let optedOutKey = "simpleanalytics.isoptedout"
    }
    
    struct Event: Encodable {
        let type: EventType
        let hostname: String
        let event: String
        var ua: String? = nil
        var path: String? = nil
        var language: String? = nil
        var timezone: String? = nil
        var viewportWidth: Int? = nil
        var viewportHeight: Int? = nil
        var screenWidth: Int? = nil
        var screenHeight: Int? = nil
        var unique: Bool? = nil
        var metadata: String? = nil
        
        enum CodingKeys: String, CodingKey {
            case type
            case hostname
            case event
            case ua
            case path
            case language
            case timezone
            case viewportWidth = "viewport_width"
            case viewportHeight = "viewport_height"
            case screenWidth = "screen_width"
            case screenHeight = "screen_height"
            case unique
            case metadata
        }
    }
    
    enum EventType: String, Encodable {
        case event
        case pageview
    }
}
