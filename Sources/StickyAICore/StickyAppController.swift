import AppKit
import WebKit

public final class StickyPanel: NSPanel {
    public var allowBecomingKey: Bool = true
    public override var canBecomeKey: Bool { allowBecomingKey }
    public override var canBecomeMain: Bool { allowBecomingKey }

    /// Always report `.visible` while the panel is ordered-in so Apple WebKit (`WKWebView`)
    /// never purges GPU `IOSurface` tiles or suspends/evicts the `WebContent` process when
    /// Sticky-AI is soft-hidden, behind another Space, or across display sleep.
    public override var occlusionState: NSWindow.OcclusionState {
        isVisible ? [.visible] : super.occlusionState
    }
}

public final class StickyAppController: NSObject, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public static let domonkFactoryName = "DOMONK Factory"
    public static let domonkFactoryURL = URL(string: "https://domonk.com")!

    public let configStore: ConfigStore
    public let launchAtLoginManager: LaunchAtLoginManager
    public let downloadsDirectoryURL: URL
    public let panel: StickyPanel
    public let webView: WKWebView
    public private(set) var hotKeyManager: HotKeyManager!
    public private(set) var processTerminationRecoveryCount: Int = 0
    public var onDownloadFinished: ((URL) -> Void)?
    public var onDownloadFailed: ((Error) -> Void)?

    private struct ActiveDownloadContext {
        let download: WKDownload
        var destinationURL: URL?
        weak var temporaryPopupWebView: WKWebView?
    }

    /// Tiny non-zero alpha used while parked on a 1x1 corner pixel so WindowServer keeps the
    /// backing surface allocated while remaining 100% invisible to the user.
    private static let parkedKeepAliveAlpha: CGFloat = 0.005

    private let contentContainerView: NSView
    private let snapshotShieldView: NSImageView
    private var lastSnapshotImage: NSImage?
    private var lastCommittedURL: URL?
    private var lastVisibleFrame: CGRect

    private var statusItem: NSStatusItem?
    public private(set) var statusMenu: NSMenu?
    public private(set) var aboutWindow: NSPanel?
    private var childWindows: [ObjectIdentifier: NSPanel] = [:]
    private var committedChildWebViews: Set<ObjectIdentifier> = []
    private var activeDownloads: [ObjectIdentifier: ActiveDownloadContext] = [:]
    private var previousExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var appNapActivity: NSObjectProtocol?
    private var keepAliveTimer: Timer?

    private var isQuitting = false
    private var isHiding = false
    private var isLogicallyHidden = false
    private var isTransitioningVisibility = false
    private let initialURL: URL

    public init(
        configStore: ConfigStore = ConfigStore(),
        launchAtLoginManager: LaunchAtLoginManager = LaunchAtLoginManager(),
        websiteDataStore: WKWebsiteDataStore = .default(),
        initialURL: URL = URL(string: StickyConstants.defaultGeminiURL)!,
        downloadsDirectoryURL: URL? = nil,
        enableStatusItem: Bool = true,
        registerGlobalHotKey: Bool = true
    ) {
        self.configStore = configStore
        self.launchAtLoginManager = launchAtLoginManager
        self.initialURL = initialURL
        self.lastCommittedURL = initialURL
        self.downloadsDirectoryURL = DownloadHelper.defaultDownloadsDirectory(override: downloadsDirectoryURL)

        let screens = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.main?.visibleFrame
            ?? screens.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let startFrame = configStore.resolvedWindowFrame(
            visibleScreenFrames: screens,
            primaryVisibleFrame: primaryFrame
        )
        self.lastVisibleFrame = startFrame

        self.panel = StickyPanel(
            contentRect: startFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let containerRect = CGRect(origin: .zero, size: startFrame.size)
        self.contentContainerView = NSView(frame: containerRect)
        self.contentContainerView.autoresizingMask = [.width, .height]

        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = websiteDataStore
        webConfig.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.webView = WKWebView(frame: containerRect, configuration: webConfig)
        self.webView.customUserAgent = StickyConstants.safariUserAgent
        self.webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

        self.snapshotShieldView = NSImageView(frame: containerRect)
        self.snapshotShieldView.autoresizingMask = [.width, .height]
        self.snapshotShieldView.imageScaling = .scaleAxesIndependently
        self.snapshotShieldView.isHidden = true

        self.contentContainerView.addSubview(self.webView)
        self.contentContainerView.addSubview(self.snapshotShieldView)

        super.init()

        // Prevent macOS App Nap from suspending Sticky-AI or starving WebKit XPC processes while idle,
        // while still allowing normal idle system sleep when the Mac is unused.
        self.appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Sticky-AI Google Gemini WebView warm for instant Option+Space open"
        )

        configurePanel()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.panel.contentView = self.contentContainerView

        observeExternalActiveAppAndSystemWake()
        startWebContentKeepAliveTimer()
        setupMainMenu()

        if enableStatusItem {
            launchAtLoginManager.syncOnLaunch(configStore: configStore)
            setupStatusItem()
        }

        self.hotKeyManager = HotKeyManager { [weak self] in
            self?.handleOptionSpaceHotkey()
        }
        if registerGlobalHotKey {
            self.hotKeyManager.registerOptionSpace()
        }
    }

    deinit {
        keepAliveTimer?.invalidate()
        if let appNapActivity {
            ProcessInfo.processInfo.endActivity(appNapActivity)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let workspaceObserver {
            wsCenter.removeObserver(workspaceObserver)
        }
        if let wakeObserver {
            wsCenter.removeObserver(wakeObserver)
        }
        if let screenWakeObserver {
            wsCenter.removeObserver(screenWakeObserver)
        }
        if let screenParamsObserver {
            NotificationCenter.default.removeObserver(screenParamsObserver)
        }
        hotKeyManager?.unregister()
    }

    private func configurePanel() {
        panel.title = "Sticky-AI — Gemini (⌥Space)"
        panel.minSize = NSSize(width: StickyConstants.minWidth, height: StickyConstants.minHeight)
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.08, alpha: 1.0)
        panel.alphaValue = CGFloat(StickyConstants.focusedAlpha)
        panel.delegate = self
    }

    private func observeExternalActiveAppAndSystemWake() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != myPID {
            previousExternalApp = front
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        workspaceObserver = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != myPID else {
                return
            }
            self.previousExternalApp = app
        }

        wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.warmUpWebViewAfterIdleOrWake()
        }

        screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.warmUpWebViewAfterIdleOrWake()
        }

        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isLogicallyHidden else { return }
            self.repositionParkedPanel()
        }
    }

    private func startWebContentKeepAliveTimer() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.warmUpWebViewAfterIdleOrWake()
        }
        keepAliveTimer?.tolerance = 10.0
    }

    /// Ensures the WKWebView WebContent & GPU processes remain warm and recovers silently in the
    /// background if macOS ever terminated WebContent during deep sleep or extreme memory pressure.
    private func warmUpWebViewAfterIdleOrWake() {
        if webView.url == nil && !webView.isLoading {
            showSnapshotShieldIfAvailable()
            webView.load(URLRequest(url: lastCommittedURL ?? initialURL))
            return
        }
        webView.evaluateJavaScript("void 0", completionHandler: nil)
    }

    private func captureSnapshotForFallback() {
        guard !webView.isLoading, webView.bounds.width > 10, webView.bounds.height > 10 else {
            return
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image {
                self?.lastSnapshotImage = image
            }
        }
    }

    private func showSnapshotShieldIfAvailable() {
        guard let lastSnapshotImage else { return }
        snapshotShieldView.image = lastSnapshotImage
        snapshotShieldView.isHidden = false
    }

    private func hideSnapshotShield() {
        snapshotShieldView.isHidden = true
    }

    private func parkedHiddenFrame(preservingSize size: NSSize) -> CGRect {
        let allScreens = NSScreen.screens
        if let rightmost = allScreens.max(by: { $0.frame.maxX < $1.frame.maxX }) {
            let rf = rightmost.frame
            return CGRect(
                x: rf.maxX - 1.0,
                y: rf.minY - size.height + 1.0,
                width: size.width,
                height: size.height
            )
        }
        return CGRect(x: 1439.0, y: -size.height + 1.0, width: size.width, height: size.height)
    }

    private func repositionParkedPanel() {
        isTransitioningVisibility = true
        let parked = parkedHiddenFrame(preservingSize: lastVisibleFrame.size)
        panel.setFrame(parked, display: true, animate: false)
        isTransitioningVisibility = false
    }

    public func start() {
        webView.load(URLRequest(url: initialURL))
        showAndFocusWindow(focusInput: true)
    }

    public var isWindowVisible: Bool {
        panel.isVisible && !isLogicallyHidden
    }

    public var isWindowFocused: Bool {
        isWindowVisible && panel.isKeyWindow
    }

    public var currentAlpha: Double {
        if isLogicallyHidden {
            return 0.0
        }
        return (Double(panel.alphaValue) * 100.0).rounded() / 100.0
    }

    // MARK: - Option+Space State Machine

    @discardableResult
    public func handleOptionSpaceHotkey(completion: ((HotkeyAction) -> Void)? = nil) -> HotkeyAction {
        let action = computeHotkeyAction(
            isVisible: isWindowVisible,
            isFocused: isWindowFocused
        )

        switch action {
        case .showAndFocus, .focus:
            showAndFocusWindow(focusInput: true) {
                completion?(action)
            }
        case .hide:
            hideWindow()
            completion?(action)
        }
        return action
    }

    public func showAndFocusWindow(
        focusInput: Bool = true,
        overrideFrame: CGRect? = nil,
        completion: (() -> Void)? = nil
    ) {
        let wasLogicallyHidden = isLogicallyHidden
        isTransitioningVisibility = true
        isHiding = false
        isLogicallyHidden = false

        let targetFrame: CGRect
        if let overrideFrame {
            targetFrame = overrideFrame
        } else if wasLogicallyHidden {
            let screens = NSScreen.screens.map(\.visibleFrame)
            let primaryFrame = NSScreen.main?.visibleFrame
                ?? screens.first
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            targetFrame = configStore.resolvedWindowFrame(
                visibleScreenFrames: screens,
                primaryVisibleFrame: primaryFrame
            )
        } else {
            targetFrame = panel.frame
        }
        lastVisibleFrame = targetFrame

        panel.allowBecomingKey = true
        panel.ignoresMouseEvents = false
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
        }

        panel.alphaValue = CGFloat(StickyConstants.focusedAlpha)
        panel.level = .floating
        isTransitioningVisibility = false

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if webView.url == nil && !webView.isLoading {
            showSnapshotShieldIfAvailable()
            webView.load(URLRequest(url: lastCommittedURL ?? initialURL))
        }

        if focusInput {
            FocusInput.focusMessageInput(in: webView, in: panel) { _ in
                completion?()
            }
        } else {
            completion?()
        }
    }

    /// Soft-hides Sticky-AI without calling `panel.orderOut(nil)` or `NSApp.hide(nil)`.
    /// Keeping a 1pt click-through edge strip ordered in at near-zero alpha keeps WindowServer
    /// occlusion `.visible`, so WebKit retains its GPU IOSurfaces and live DOM indefinitely —
    /// opening instantly with zero black flash even hours later.
    public func hideWindow() {
        if !isLogicallyHidden {
            lastVisibleFrame = panel.frame
            configStore.setWindowFrame(panel.frame)
            captureSnapshotForFallback()
        }

        isTransitioningVisibility = true
        isHiding = true
        isLogicallyHidden = true

        panel.allowBecomingKey = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = Self.parkedKeepAliveAlpha

        let parked = parkedHiddenFrame(preservingSize: lastVisibleFrame.size)
        panel.setFrame(parked, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.resignKey()
        isTransitioningVisibility = false

        if let prev = previousExternalApp, !prev.isTerminated {
            if #available(macOS 14.0, *) {
                prev.activate()
            } else {
                prev.activate(options: [.activateIgnoringOtherApps])
            }
        } else if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  !finder.isTerminated {
            if #available(macOS 14.0, *) {
                finder.activate()
            } else {
                finder.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            NSApp.deactivate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isHiding = false
        }
    }

    public func syncOpacity() {
        guard isWindowVisible else { return }
        let target = getTargetAlpha(
            isFocused: isWindowFocused,
            unfocusedAlpha: configStore.unfocusedAlpha
        )
        panel.alphaValue = CGFloat(target)
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isLogicallyHidden, !isTransitioningVisibility else { return }
        panel.alphaValue = CGFloat(StickyConstants.focusedAlpha)
        panel.level = .floating
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isQuitting, !isHiding, !isLogicallyHidden, !isTransitioningVisibility, panel.isVisible else { return }
        let target = getTargetAlpha(
            isFocused: false,
            unfocusedAlpha: configStore.unfocusedAlpha
        )
        panel.alphaValue = CGFloat(target)
        panel.level = .floating
    }

    public func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isLogicallyHidden, !isTransitioningVisibility else { return }
        lastVisibleFrame = panel.frame
        configStore.setWindowFrame(panel.frame)
    }

    public func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isLogicallyHidden, !isTransitioningVisibility else { return }
        lastVisibleFrame = panel.frame
        configStore.setWindowFrame(panel.frame)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel && !isQuitting {
            hideWindow()
            return false
        }
        if sender === aboutWindow && !isQuitting {
            aboutWindow?.orderOut(nil)
            return false
        }
        return true
    }

    // MARK: - WKNavigationDelegate, WKUIDelegate & WKDownloadDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.option) {
            decisionHandler(.download, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if DownloadHelper.shouldDownloadResponse(
            navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType
        ) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === self.webView {
            if let currentURL = webView.url {
                lastCommittedURL = currentURL
            }
        } else {
            committedChildWebViews.insert(ObjectIdentifier(webView))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if let currentURL = webView.url {
            lastCommittedURL = currentURL
        }
        hideSnapshotShield()
        captureSnapshotForFallback()
        if isWindowVisible && currentAlpha > 0.9 {
            FocusInput.focusMessageInput(in: self.webView, in: panel)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        hideSnapshotShield()
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        hideSnapshotShield()
    }

    /// Automatically recovers in the background if macOS ever kills the WebKit WebContent process
    /// under extreme kernel memory pressure, displaying the cached snapshot shield instead of black.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            closeChildPopup(for: webView)
            return
        }
        processTerminationRecoveryCount += 1
        showSnapshotShieldIfAvailable()
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: lastCommittedURL ?? initialURL))
        }
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        registerDownload(download, originatingWebView: webView)
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        registerDownload(download, originatingWebView: webView)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           !navigationAction.shouldPerformDownload,
           !isGoogleOrLocalSessionURL(url) {
            NSWorkspace.shared.open(url)
            return nil
        }

        // Open Google Sign-In / OAuth popups (or popup-initiated downloads) in a native child panel
        // sharing the exact WKWebViewConfiguration
        let popupRect = CGRect(x: 0, y: 0, width: 480, height: 640)
        let popupPanel = StickyPanel(
            contentRect: popupRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupPanel.title = "Google Account Sign-In — Sticky-AI"
        popupPanel.level = .floating
        popupPanel.hidesOnDeactivate = false
        popupPanel.center()

        let popupWebView = WKWebView(frame: popupRect, configuration: configuration)
        popupWebView.customUserAgent = StickyConstants.safariUserAgent
        popupWebView.autoresizingMask = [.width, .height]
        popupWebView.uiDelegate = self
        popupWebView.navigationDelegate = self

        popupPanel.contentView = popupWebView
        childWindows[ObjectIdentifier(popupWebView)] = popupPanel
        if !navigationAction.shouldPerformDownload {
            popupPanel.makeKeyAndOrderFront(nil)
        }
        return popupWebView
    }

    private func closeChildPopup(for webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        committedChildWebViews.remove(key)
        if let popupPanel = childWindows.removeValue(forKey: key) {
            popupPanel.close()
        }
    }

    public func webViewDidClose(_ webView: WKWebView) {
        closeChildPopup(for: webView)
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = parameters.allowsDirectories
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.level = .modalPanel
        openPanel.begin { response in
            completionHandler(response == .OK ? openPanel.urls : nil)
        }
    }

    private func registerDownload(_ download: WKDownload, originatingWebView webView: WKWebView) {
        var tempPopup: WKWebView?
        let webViewKey = ObjectIdentifier(webView)
        if webView !== self.webView,
           let popupPanel = childWindows[webViewKey],
           !committedChildWebViews.contains(webViewKey) {
            popupPanel.orderOut(nil)
            tempPopup = webView
        }

        download.delegate = self
        activeDownloads[ObjectIdentifier(download)] = ActiveDownloadContext(
            download: download,
            destinationURL: nil,
            temporaryPopupWebView: tempPopup
        )
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)
        let reserved = Set(activeDownloads.values.compactMap(\.destinationURL))

        do {
            let destinationURL = try DownloadHelper.resolveUniqueDestinationURL(
                in: downloadsDirectoryURL,
                suggestedFilename: suggestedFilename,
                response: response,
                reservedURLs: reserved
            )
            if var context = activeDownloads[key] {
                context.destinationURL = destinationURL
                activeDownloads[key] = context
            } else {
                activeDownloads[key] = ActiveDownloadContext(
                    download: download,
                    destinationURL: destinationURL,
                    temporaryPopupWebView: nil
                )
            }
            completionHandler(destinationURL)
        } catch {
            completionHandler(nil)
        }
    }

    public func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let context = activeDownloads.removeValue(forKey: key)

        if let tempPopup = context?.temporaryPopupWebView {
            closeChildPopup(for: tempPopup)
        }

        if let destinationURL = context?.destinationURL {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.apple.DownloadFileFinished"),
                object: destinationURL.path,
                userInfo: nil,
                deliverImmediately: false
            )
            onDownloadFinished?(destinationURL)
        }
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        let key = ObjectIdentifier(download)
        let context = activeDownloads.removeValue(forKey: key)

        if let tempPopup = context?.temporaryPopupWebView {
            closeChildPopup(for: tempPopup)
        }

        onDownloadFailed?(error)
    }

    // MARK: - Menus & Menu Bar Tray

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Sticky-AI", action: #selector(menuAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Toggle Sticky-AI (⌥Space)", action: #selector(menuToggle), keyEquivalent: "").target = self
        let appLaunchItem = NSMenuItem(
            title: "Start Automatically at Login",
            action: #selector(menuToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        appLaunchItem.target = self
        appLaunchItem.state = launchAtLoginManager.isEnabled ? .on : .off
        appMenu.addItem(appLaunchItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sticky-AI", action: #selector(menuHide), keyEquivalent: "h").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sticky-AI", action: #selector(menuQuit), keyEquivalent: "q").target = self

        // Edit Menu (enables Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z inside WKWebView)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Reload Gemini", action: #selector(menuReload), keyEquivalent: "r").target = self
        viewMenu.addItem(withTitle: "Open Gemini Home", action: #selector(menuHome), keyEquivalent: "H").target = self

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close (Hide to Background)", action: #selector(menuHide), keyEquivalent: "w").target = self

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            var iconImage: NSImage?
            if let imagePath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png") {
                iconImage = NSImage(contentsOfFile: imagePath)
            } else if let appIcon = NSImage(named: "MenuBarIcon") {
                iconImage = appIcon
            }

            if let icon = iconImage {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            } else if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sticky-AI") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "SAI"
            }
            button.toolTip = "Sticky-AI (SAI) — Press Option+Space anywhere"
        }
        statusItem = item
        rebuildStatusMenu()
    }

    @discardableResult
    public func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Toggle Sticky-AI (⌥Space)", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Focus Message Input", action: #selector(menuFocusInput), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Gemini Home", action: #selector(menuHome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Page", action: #selector(menuReload), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reset Window Size & Position", action: #selector(menuResetBounds), keyEquivalent: "").target = self

        let alphaMenu = NSMenu()
        let presets: [(String, Double)] = [
            ("80% Opacity / 20% Transparent", 0.80),
            ("60% Opacity / 40% Transparent (Default)", 0.60),
            ("40% Opacity / 60% Transparent", 0.40),
            ("20% Opacity / 80% Transparent", 0.20)
        ]
        let current = configStore.unfocusedAlpha
        for (title, alpha) in presets {
            let sub = NSMenuItem(title: title, action: #selector(menuSelectAlpha(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = alpha
            sub.state = abs(current - alpha) < 0.03 ? .on : .off
            alphaMenu.addItem(sub)
        }
        let alphaParent = NSMenuItem(title: "Unfocused Transparency", action: nil, keyEquivalent: "")
        alphaParent.submenu = alphaMenu
        menu.addItem(alphaParent)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "Start Automatically at Login",
            action: #selector(menuToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = launchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(withTitle: "About", action: #selector(menuAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sticky-AI", action: #selector(menuQuit), keyEquivalent: "q").target = self

        self.statusMenu = menu
        return menu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(menuToggleLaunchAtLogin) {
            item.state = launchAtLoginManager.isEnabled ? .on : .off
        }
    }

    @discardableResult
    public func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let updated = (try? launchAtLoginManager.setEnabled(enabled)) ?? launchAtLoginManager.isEnabled
        configStore.launchAtLogin = updated
        rebuildStatusMenu()
        return updated
    }

    @discardableResult
    public func toggleLaunchAtLogin() -> Bool {
        setLaunchAtLogin(!launchAtLoginManager.isEnabled)
    }

    @objc private func menuToggleLaunchAtLogin() {
        toggleLaunchAtLogin()
    }

    private func rebuildStatusMenu() {
        let menu = buildStatusMenu()
        statusItem?.menu = menu
    }

    @objc public func showAboutWindow() {
        if aboutWindow == nil {
            let winRect = NSRect(x: 0, y: 0, width: 390, height: 290)
            let win = NSPanel(
                contentRect: winRect,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "About Sticky-AI — \(Self.domonkFactoryName)"
            win.level = .modalPanel
            win.hidesOnDeactivate = false
            win.isReleasedWhenClosed = false
            win.delegate = self

            let container = NSView(frame: winRect)

            let iconView = NSImageView(frame: NSRect(x: (390 - 68) / 2, y: 196, width: 68, height: 68))
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let iconImg = NSImage(contentsOf: iconURL) {
                iconView.image = iconImg
            } else {
                iconView.image = NSApp.applicationIconImage
            }
            iconView.imageScaling = .scaleProportionallyUpOrDown
            container.addSubview(iconView)

            let titleField = NSTextField(labelWithString: "Sticky-AI")
            titleField.font = NSFont.systemFont(ofSize: 16.5, weight: .bold)
            titleField.alignment = .center
            titleField.frame = NSRect(x: 20, y: 164, width: 350, height: 24)
            container.addSubview(titleField)

            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.1.0"
            let versionField = NSTextField(labelWithString: "Version \(version)")
            versionField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            versionField.textColor = .secondaryLabelColor
            versionField.alignment = .center
            versionField.frame = NSRect(x: 20, y: 142, width: 350, height: 18)
            container.addSubview(versionField)

            let descField = NSTextField(labelWithString: "Always-on-top Google Gemini companion for macOS (⌥Space)")
            descField.font = NSFont.systemFont(ofSize: 11.5)
            descField.textColor = .secondaryLabelColor
            descField.alignment = .center
            descField.frame = NSRect(x: 20, y: 118, width: 350, height: 18)
            container.addSubview(descField)

            let sep = NSBox(frame: NSRect(x: 28, y: 102, width: 334, height: 1))
            sep.boxType = .separator
            container.addSubview(sep)

            let factoryLabel = NSTextField(labelWithString: Self.domonkFactoryName)
            factoryLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            factoryLabel.alignment = .center
            factoryLabel.frame = NSRect(x: 20, y: 68, width: 350, height: 22)
            container.addSubview(factoryLabel)

            let linkButton = NSButton(
                title: "🌐 https://domonk.com ↗",
                target: self,
                action: #selector(openDomonkWebsite)
            )
            linkButton.bezelStyle = .rounded
            linkButton.keyEquivalent = "\r"
            linkButton.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            linkButton.frame = NSRect(x: (390 - 210) / 2, y: 26, width: 210, height: 32)
            container.addSubview(linkButton)

            win.contentView = container
            win.center()
            self.aboutWindow = win
        } else {
            aboutWindow?.center()
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        aboutWindow?.orderFrontRegardless()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func menuAbout() {
        showAboutWindow()
    }

    @objc private func openDomonkWebsite() {
        NSWorkspace.shared.open(Self.domonkFactoryURL)
    }

    @objc private func menuToggle() {
        handleOptionSpaceHotkey()
    }

    @objc private func menuFocusInput() {
        showAndFocusWindow(focusInput: true)
    }

    @objc private func menuHome() {
        webView.load(URLRequest(url: initialURL))
        showAndFocusWindow(focusInput: true)
    }

    @objc private func menuReload() {
        webView.reload()
    }

    @objc private func menuResetBounds() {
        configStore.resetWindowFrame()
        let screens = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.main?.visibleFrame
            ?? screens.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let freshFrame = configStore.resolvedWindowFrame(
            visibleScreenFrames: screens,
            primaryVisibleFrame: primaryFrame
        )
        showAndFocusWindow(focusInput: true, overrideFrame: freshFrame)
    }

    @objc private func menuSelectAlpha(_ sender: NSMenuItem) {
        guard let alpha = sender.representedObject as? Double else { return }
        configStore.unfocusedAlpha = alpha
        syncOpacity()
        rebuildStatusMenu()
    }

    @objc private func menuHide() {
        hideWindow()
    }

    @objc private func menuQuit() {
        isQuitting = true
        if !isLogicallyHidden {
            configStore.setWindowFrame(panel.frame)
        }
        NSApp.terminate(nil)
    }
}
