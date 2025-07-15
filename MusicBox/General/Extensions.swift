//
//  Extensions.swift
//  MusicBox
//
//  Created by Elsa on 2024/4/20.
//

import Cocoa
import Foundation
import UniformTypeIdentifiers

// MARK: - String Extensions
extension String {
    func subString(from startString: String, to endString: String) -> String {
        guard let startIndex = self.range(of: startString)?.upperBound else { return "" }
        let remainingString = String(self[startIndex...])
        guard let endIndex = remainingString.range(of: endString)?.lowerBound else {
            return remainingString
        }
        return String(remainingString[..<endIndex])
    }

    func subString(from startString: String) -> String {
        guard let startIndex = self.range(of: startString)?.upperBound else { return "" }
        return String(self[startIndex...])
    }

    func subString(to endString: String) -> String {
        guard let endIndex = self.range(of: endString)?.lowerBound else { return "" }
        return String(self[..<endIndex])
    }

    var https: String {
        starts(with: "http://") ? replacingOccurrences(of: "http://", with: "https://") : self
    }
}

// MARK: - URL Extensions
extension URL {
    var https: URL? {
        URL(string: absoluteString.https)
    }
}

// MARK: - Data Extensions
extension Data {
    private static let jsonDecoder = JSONDecoder()

    func asType<T: Decodable>(_ type: T.Type, silent: Bool = false) -> T? {
        do {
            return try Self.jsonDecoder.decode(type, from: self)
        } catch {
            if !silent {
                let userFriendlyError = "Failed to decode data: \(error.localizedDescription)"

                AlertModal.showAlertWithSaveOption(
                    "Decoding Error",
                    userFriendlyError
                ) {
                    self.saveRawDataToFile()
                }
            }
            return nil
        }
    }

    private func saveRawDataToFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "raw_data_\(timestamp).json"

        // Use NSSavePanel to let user choose location
        let savePanel = NSSavePanel()
        savePanel.title = "Save Raw Data"
        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        // Run the save panel
        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try self.write(to: url)

                // Show the file in Finder
                NSWorkspace.shared.selectFile(
                    url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)

                AlertModal.showAlert("Success", "Raw data saved to: \(url.lastPathComponent)")
            } catch {
                AlertModal.showAlert(
                    "Save Failed", "Could not save raw data file: \(error.localizedDescription)")
            }
        }
    }

    func asAny() -> Any? {
        try? JSONSerialization.jsonObject(with: self, options: [])
    }

    func asJSONString() -> String {
        guard let jsonObject = asAny() else {
            return String(data: self, encoding: .utf8) ?? "Failed to decode as UTF-8"
        }

        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? "Failed to convert to string"
        } catch {
            return "Failed to serialize JSON: \(error.localizedDescription)"
        }
    }
}
