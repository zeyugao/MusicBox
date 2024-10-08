//
//  Extensions.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import Cocoa

extension String {
    func subString(from startString: String, to endString: String) -> String {
        var str = self
        if let startIndex = self.range(of: startString)?.upperBound {
            str.removeSubrange(str.startIndex..<startIndex)
            if let endIndex = str.range(of: endString)?.lowerBound {
                str.removeSubrange(endIndex..<str.endIndex)
                return str
            }
        }
        return ""
    }

    func subString(from startString: String) -> String {
        var str = self
        if let startIndex = self.range(of: startString)?.upperBound {
            str.removeSubrange(self.startIndex..<startIndex)
            return str
        }
        return ""
    }

    func subString(to endString: String) -> String {
        var str = self
        if let endIndex = self.range(of: endString)?.lowerBound {
            str.removeSubrange(endIndex..<str.endIndex)
            return str
        }
        return ""
    }

    var https: String {
        if starts(with: "http://") {
            return replacingOccurrences(of: "http://", with: "https://")
        } else {
            return self
        }
    }
}

extension URL {
    var https: URL? {
        return URL(string: absoluteString.https)
    }
}

extension Data {
    func asType<T: Decodable>(_ type: T.Type) -> T? {
        do {
            return try JSONDecoder().decode(type, from: self)
        } catch {
            let callStack = Thread.callStackSymbols.joined(separator: "\n")
            let errorMessage =
                "Error: \(error.localizedDescription)\n\n\(callStack)"
            AlertModal.showAlert("Error", errorMessage)
            return nil
        }
    }

    func asAny() -> Any? {
        return try? JSONSerialization.jsonObject(with: self, options: [])
    }
}
