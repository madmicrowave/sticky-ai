import AppKit
import WebKit

public final class StickyPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}

public final class StickyAppController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public let configStore: ConfigStore
    public let downloadsDirectoryURL: URL
    public let panel: StickyPanel
    public let webView: WKWebView
    public private(set) var hotKeyManager: HotKeyManager!
    public var onDownloadFinished: ((URL) -> Void)?
    public var onDownloadFailed: ((Error) -> Void)?

    private struct ActiveDownloadContext {
        let download: WKDownload
        var destinationURL: URL?
        weak var temporaryPopupWebView: WKWebView?
    }

    private var statusItem: NSStatusItem?
    private var childWindows: [ObjectIdentifier: NSPanel] = [:]
    private var committedChildWebViews: Set<ObjectIdentifier> = []
    private var activeDownloads: [ObjectIdentifier: ActiveDownloadContext] = [:]
    private var previousExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var isQuitting = false
    private var isHiding = false
    private let initialURL: URL

    public init(
        configStore: ConfigStore = ConfigStore(),
        websiteDataStore: WKWebsiteDataStore = .default(),
        initialURL: URL = URL(string: StickyConstants.defaultGeminiURL)!,
        downloadsDirectoryURL: URL? = nil,
        enableStatusItem: Bool = true,
        registerGlobalHotKey: Bool = true
    ) {
        self.configStore = configStore
        self.initialURL = initialURL
        self.downloadsDirectoryURL = DownloadHelper.defaultDownloadsDirectory(override: downloadsDirectoryURL)

        let screens = NSScreen.screens.map(\.visibleFrame)
        let primaryFrame = NSScreen.main?.visibleFrame
            ?? screens.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let startFrame = configStore.resolvedWindowFrame(
            visibleScreenFrames: screens,
            primaryVisibleFrame: primaryFrame
        )

        self.panel = StickyPanel(
            contentRect: startFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = websiteDataStore
        webConfig.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.webView = WKWebView(frame: CGRect(origin: .zero, size: startFrame.size), configuration: webConfig)
        self.webView.customUserAgent = StickyConstants.safariUserAgent
        self.webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

        super.init()

        configurePanel()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.panel.contentView = self.webView

        observeExternalActiveApp()
        setupMainMenu()

        if enableStatusItem {
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
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
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

    private func observeExternalActiveApp() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != myPID {
            previousExternalApp = front
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
    }

    public func start() {
        webView.load(URLRequest(url: initialURL))
        showAndFocusWindow(focusInput: true)
    }

    public var isWindowVisible: Bool {
        panel.isVisible
    }

    public var isWindowFocused: Bool {
        panel.isVisible && panel.isKeyWindow
    }

    public var currentAlpha: Double {
        (Double(panel.alphaValue) * 100.0).rounded() / 100.0
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

    public func showAndFocusWindow(focusInput: Bool = true, completion: (() -> Void)? = nil) {
        isHiding = false
        panel.alphaValue = CGFloat(StickyConstants.focusedAlpha)
        panel.level = .floating

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if focusInput {
            FocusInput.focusMessageInput(in: webView, in: panel) { _ in
                completion?()
            }
        } else {
            completion?()
        }
    }

    public func hideWindow() {
        isHiding = true
        configStore.setWindowFrame(panel.frame)
        panel.orderOut(nil)

        if let prev = previousExternalApp, !prev.isTerminated {
            if #available(macOS 14.0, *) {
                prev.activate()
            } else {
                prev.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            NSApp.hide(nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isHiding = false
        }
    }

    public func syncOpacity() {
        let target = getTargetAlpha(
            isFocused: isWindowFocused,
            unfocusedAlpha: configStore.unfocusedAlpha
        )
        panel.alphaValue = CGFloat(target)
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        panel.alphaValue = CGFloat(StickyConstants.focusedAlpha)
        panel.level = .floating
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isQuitting, !isHiding, panel.isVisible else { return }
        let target = getTargetAlpha(
            isFocused: false,
            unfocusedAlpha: configStore.unfocusedAlpha
        )
        panel.alphaValue = CGFloat(target)
        panel.level = .floating
    }

    public func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        configStore.setWindowFrame(panel.frame)
    }

    public func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        configStore.setWindowFrame(panel.frame)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel && !isQuitting {
            hideWindow()
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
        if webView !== self.webView {
            committedChildWebViews.insert(ObjectIdentifier(webView))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if isWindowVisible && currentAlpha > 0.9 {
            FocusInput.focusMessageInput(in: self.webView, in: panel)
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
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Toggle Sticky-AI (⌥Space)", action: #selector(menuToggle), keyEquivalent: "").target = self
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

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

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
        menu.addItem(withTitle: "Quit Sticky-AI", action: #selector(menuQuit), keyEquivalent: "q").target = self

        statusItem.menu = menu
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
        panel.setFrame(freshFrame, display: true, animate: true)
        showAndFocusWindow(focusInput: true)
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
        configStore.setWindowFrame(panel.frame)
        NSApp.terminate(nil)
    }
}
