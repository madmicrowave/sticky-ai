import Foundation
import CoreGraphics

public enum HotkeyAction: String, Equatable {
    case showAndFocus = "SHOW_AND_FOCUS"
    case focus = "FOCUS"
    case hide = "HIDE"
}

public enum StickyConstants {
    public static let focusedAlpha: Double = 1.0
    /// 60% filled / 40% transparent => alpha = 0.60
    public static let defaultUnfocusedAlpha: Double = 0.60
    public static let defaultGeminiURL = "https://gemini.google.com/app"
    public static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    public static let defaultWidth: CGFloat = 420
    public static let defaultHeight: CGFloat = 560
    public static let minWidth: CGFloat = 280
    public static let minHeight: CGFloat = 320
}

/// Computes the exact state transition when Option+Space is pressed:
/// - Hidden -> Show on top of all windows, focus app, focus message input
/// - Shown & NOT focused -> Focus app (alpha 1.0), focus message input
/// - Shown & focused -> Hide app
public func computeHotkeyAction(isVisible: Bool, isFocused: Bool) -> HotkeyAction {
    if !isVisible {
        return .showAndFocus
    }
    if !isFocused {
        return .focus
    }
    return .hide
}

/// Computes window alpha for focused (1.0) vs unfocused (0.20 = 80% transparent) states.
public func getTargetAlpha(
    isFocused: Bool,
    unfocusedAlpha: Double = StickyConstants.defaultUnfocusedAlpha
) -> Double {
    if isFocused {
        return StickyConstants.focusedAlpha
    }
    let clamped = min(1.0, max(0.05, unfocusedAlpha))
    return (clamped * 100.0).rounded() / 100.0
}

/// Determines whether a URL belongs to Google Auth / Gemini domains that should remain inside
/// the persistent Sticky-AI browser session rather than opening externally.
public func isGoogleOrLocalSessionURL(_ url: URL) -> Bool {
    let scheme = (url.scheme ?? "").lowercased()
    if scheme == "file" || scheme == "about" || scheme == "data" {
        return true
    }
    guard let host = url.host?.lowercased() else {
        return false
    }
    if host == "localhost" || host == "127.0.0.1" {
        return true
    }
    return host == "google.com"
        || host.hasSuffix(".google.com")
        || host.hasSuffix(".googleusercontent.com")
        || host.hasSuffix(".gstatic.com")
        || host == "youtu.be"
        || host.hasSuffix(".youtube.com")
}

public struct StoredConfig: Codable, Equatable {
    public struct RectData: Codable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    public var frame: RectData?
    public var unfocusedAlpha: Double?
    public var launchAtLogin: Bool?

    public init(frame: RectData? = nil, unfocusedAlpha: Double? = nil, launchAtLogin: Bool? = nil) {
        self.frame = frame
        self.unfocusedAlpha = unfocusedAlpha
        self.launchAtLogin = launchAtLogin
    }
}

public final class ConfigStore {
    public let fileURL: URL
    private var config: StoredConfig

    public init(directoryURL: URL? = nil) {
        let baseDir: URL
        if let directoryURL {
            baseDir = directoryURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            baseDir = appSupport.appendingPathComponent("Sticky-AI", isDirectory: true)
        }
        self.fileURL = baseDir.appendingPathComponent("sticky-ai-config.json")
        self.config = Self.load(from: self.fileURL)
    }

    private static func load(from url: URL) -> StoredConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StoredConfig.self, from: data) else {
            return StoredConfig()
        }
        return decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence
        }
    }

    public func resolvedWindowFrame(visibleScreenFrames: [CGRect], primaryVisibleFrame: CGRect) -> CGRect {
        let defaultX = (primaryVisibleFrame.maxX - StickyConstants.defaultWidth - 24).rounded()
        let defaultY = (primaryVisibleFrame.maxY - StickyConstants.defaultHeight - 32).rounded()
        let defaultRect = CGRect(
            x: defaultX,
            y: defaultY,
            width: StickyConstants.defaultWidth,
            height: StickyConstants.defaultHeight
        )

        guard let saved = config.frame else {
            return defaultRect
        }

        let width = max(StickyConstants.minWidth, CGFloat(saved.width).rounded())
        let height = max(StickyConstants.minHeight, CGFloat(saved.height).rounded())
        let candidate = CGRect(x: CGFloat(saved.x).rounded(), y: CGFloat(saved.y).rounded(), width: width, height: height)

        let isOnAnyScreen = visibleScreenFrames.contains { screenFrame in
            let intersection = candidate.intersection(screenFrame)
            return !intersection.isNull && intersection.width >= 100 && intersection.height >= 60
        }

        if !isOnAnyScreen {
            let safeX = max(primaryVisibleFrame.minX, (primaryVisibleFrame.maxX - width - 24).rounded())
            let safeY = max(primaryVisibleFrame.minY, (primaryVisibleFrame.maxY - height - 32).rounded())
            return CGRect(x: safeX, y: safeY, width: width, height: height)
        }
        return candidate
    }

    public func setWindowFrame(_ rect: CGRect) {
        config.frame = StoredConfig.RectData(
            x: Double(rect.origin.x.rounded()),
            y: Double(rect.origin.y.rounded()),
            width: Double(rect.size.width.rounded()),
            height: Double(rect.size.height.rounded())
        )
        save()
    }

    public func resetWindowFrame() {
        config.frame = nil
        save()
    }

    public var unfocusedAlpha: Double {
        get {
            if let envStr = ProcessInfo.processInfo.environment["STICKY_AI_UNFOCUSED_OPACITY"],
               let envVal = Double(envStr), envVal >= 0.05, envVal <= 1.0 {
                return envVal
            }
            if let stored = config.unfocusedAlpha {
                return min(1.0, max(0.05, stored))
            }
            return StickyConstants.defaultUnfocusedAlpha
        }
        set {
            config.unfocusedAlpha = min(1.0, max(0.05, newValue))
            save()
        }
    }

    public var launchAtLogin: Bool? {
        get { config.launchAtLogin }
        set {
            config.launchAtLogin = newValue
            save()
        }
    }
}
