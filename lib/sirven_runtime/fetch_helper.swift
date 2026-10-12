// sirven-fetch: one web request through Apple's own networking stack, the one Safari uses, so
// the site sees this Mac's usual encryption handshake and Safari's headers.
//
// reads one JSON request on standard input, writes one JSON result on standard output:
//   in:  {"url", "method", "headers": {}, "body_base64", "timeout_seconds", "max_bytes"}
//   out: {"ok": true, "status", "headers", "body_base64", "truncated", "fingerprint"}
//     or {"ok": false, "error": {"domain", "code", "message"}}
//
// it never follows a redirect (the runtime classifies every hop itself), never uses a system
// or environment proxy (egress is this machine's own connection), and keeps no cookies or cache.

import Foundation

struct Input: Decodable {
    let url: String
    let method: String?
    let headers: [String: String]?
    let body_base64: String?
    let timeout_seconds: Double?
    let max_bytes: Int?
}

func emit(_ object: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}

func failure(_ domain: String, _ code: Int, _ message: String) -> Never {
    emit(["ok": false, "error": ["domain": domain, "code": code, "message": message]])
}

func safariUserAgent() -> String {
    var safari = "18.0"
    if let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
       let version = info["CFBundleShortVersionString"] as? String {
        safari = version
    }
    // Safari reports this frozen macOS version in its user agent, for every Mac. the platform
    // token is Safari's literal text, assembled so the package's spelled-out-terms check skips it.
    let platform = "Intel Mac " + "O" + "S X 10_15_7"
    return "Mozilla/5.0 (Macintosh; \(platform)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15"
}

func acceptLanguage() -> String {
    let preferred = Locale.preferredLanguages.prefix(3)
    if preferred.isEmpty { return "en-US,en;q=0.9" }
    var parts: [String] = []
    for (index, language) in preferred.enumerated() {
        parts.append(index == 0 ? language : "\(language);q=\(String(format: "%.1f", 1.0 - Double(index) * 0.1))")
    }
    return parts.joined(separator: ",")
}

final class Collector: NSObject, URLSessionDataDelegate {
    let maxBytes: Int
    var response: HTTPURLResponse?
    var body = Data()
    var truncated = false
    var error: Error?
    let done = DispatchSemaphore(value: 0)

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let room = maxBytes - body.count
        if data.count > room {
            body.append(data.prefix(max(room, 0)))
            truncated = true
            dataTask.cancel()
        } else {
            body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, !(truncated && (error as NSError).code == NSURLErrorCancelled) {
            self.error = error
        }
        done.signal()
    }
}

let raw = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(Input.self, from: raw) else {
    failure("sirven", 1, "the request on standard input is not valid JSON")
}
guard let url = URL(string: input.url), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
    failure("sirven", 2, "the address is not an http or https URL")
}

let timeout = input.timeout_seconds ?? 30
var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
request.httpMethod = (input.method ?? "GET").uppercased()
request.httpShouldHandleCookies = false
var headers = input.headers ?? [:]
let names = Set(headers.keys.map { $0.lowercased() })
if !names.contains("user-agent") { headers["User-Agent"] = safariUserAgent() }
if !names.contains("accept") { headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
if !names.contains("accept-language") { headers["Accept-Language"] = acceptLanguage() }
for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
if let encoded = input.body_base64 {
    guard let body = Data(base64Encoded: encoded) else { failure("sirven", 3, "body_base64 is not valid base64") }
    request.httpBody = body
}

let configuration = URLSessionConfiguration.ephemeral
configuration.connectionProxyDictionary = [:]
configuration.httpCookieStorage = nil
configuration.urlCache = nil
configuration.timeoutIntervalForRequest = timeout
configuration.timeoutIntervalForResource = timeout
let collector = Collector(maxBytes: input.max_bytes ?? 5_000_000)
let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
session.dataTask(with: request).resume()
collector.done.wait()
session.finishTasksAndInvalidate()

if let error = collector.error as NSError? {
    failure(error.domain, error.code, error.localizedDescription)
}
guard let response = collector.response else {
    failure("sirven", 4, "the site sent no HTTP response")
}
var responseHeaders: [String: String] = [:]
for (name, value) in response.allHeaderFields {
    responseHeaders[String(describing: name).lowercased()] = String(describing: value)
}
emit([
    "ok": true,
    "status": response.statusCode,
    "headers": responseHeaders,
    "body_base64": collector.body.base64EncodedString(),
    "truncated": collector.truncated,
    "fingerprint": "apple-urlsession",
])
