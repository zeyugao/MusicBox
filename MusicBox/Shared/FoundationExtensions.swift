import Foundation

extension String {
    var https: String {
        hasPrefix("http://") ? replacingOccurrences(of: "http://", with: "https://") : self
    }
}

extension URL {
    var https: URL? {
        URL(string: absoluteString.https)
    }
}

extension Data {
    func asType<T: Decodable>(_ type: T.Type, silent: Bool = false) -> T? {
        do {
            return try JSONDecoder().decode(type, from: self)
        } catch {
            if !silent {
                print("Failed to decode \(T.self): \(error.localizedDescription)")
            }
            return nil
        }
    }

    func asAny() -> Any? {
        try? JSONSerialization.jsonObject(with: self)
    }

    func asJSONString() -> String {
        guard let object = asAny(),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        else {
            return String(data: self, encoding: .utf8) ?? "<non-UTF8 data>"
        }
        return String(data: data, encoding: .utf8) ?? "<unprintable JSON>"
    }
}
