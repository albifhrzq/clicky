//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading optional runtime configuration from the built app bundle.
//  Keychain and UserDefaults values managed by ClickyConfiguration remain authoritative.
//

import Foundation

nonisolated public enum AppBundleConfiguration {
    /// Reads an optional non-empty string value from `Bundle.main` Info.plist
    /// (falling back to embedded `Info.plist` or `ClickyBuildInfo.plist` resources).
    /// Unexpanded Xcode build placeholders such as `$(VAR)` are treated as absent.
    public static func stringValue(forKey key: String) -> String? {
        if let infoDictionaryValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let normalized = normalizedBundleString(infoDictionaryValue) {
            return normalized
        }

        for resourceName in ["Info", "ClickyBuildInfo"] {
            if let resourcePath = Bundle.main.path(forResource: resourceName, ofType: "plist"),
               let resourceDictionary = NSDictionary(contentsOfFile: resourcePath),
               let rawValue = resourceDictionary[key] as? String,
               let normalized = normalizedBundleString(rawValue) {
                return normalized
            }
        }

        return nil
    }

    /// Reads an optional boolean value from the app bundle Info.plist.
    public static func boolValue(forKey key: String) -> Bool? {
        if let boolVal = Bundle.main.object(forInfoDictionaryKey: key) as? Bool {
            return boolVal
        }
        if let stringVal = stringValue(forKey: key)?.lowercased() {
            switch stringVal {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    /// Reads an optional URL value from the app bundle Info.plist.
    public static func urlValue(forKey key: String) -> URL? {
        guard let raw = stringValue(forKey: key) else { return nil }
        return URL(string: raw)
    }

    /// Resolves a configuration value where Keychain/UserDefaults (`configurationOverride`)
    /// takes precedence over any optional bundle Info.plist fallback.
    public static func resolvedStringValue(
        forKey bundleKey: String,
        configurationOverride: String?
    ) -> String? {
        if let override = configurationOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return stringValue(forKey: bundleKey)
    }

    private static func normalizedBundleString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("$(") && trimmed.hasSuffix(")") {
            return nil
        }
        return trimmed
    }
}
