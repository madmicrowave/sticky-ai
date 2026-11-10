import Foundation
import Darwin
import AppKit
import WebKit
#if canImport(StickyAICore)
import StickyAICore
#endif

private final class LocalTestHTTPServer {
    let port: UInt16
    private let listenFD: Int32
    private var isStopped = false
    private let handler: (String) -> (status: String, headers: [(String, String)], body: Data)

    init(handler: @escaping (String) -> (status: String, headers: [(String, String)], body: Data)) throws {
        self.handler = handler
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0, listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while !isStopped {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                break
            }
            var yes: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                defer { close(clientFD) }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(clientFD, &buf, buf.count)
                guard n > 0 else { return }
                let req = String(decoding: buf[0..<n], as: UTF8.self)
                let firstLine = req.split(separator: "\r\n", maxSplits: 1).first ?? ""
                let parts = firstLine.split(separator: " ")
                let path = parts.count >= 2 ? String(parts[1]) : "/"

                let resp = handler(path)
                var headerBlock = "HTTP/1.1 \(resp.status)\r\n"
                for (k, v) in resp.headers {
                    headerBlock += "\(k): \(v)\r\n"
                }
                headerBlock += "Content-Length: \(resp.body.count)\r\n"
                headerBlock += "Connection: close\r\n\r\n"

                var payload = Data(headerBlock.utf8)
                payload.append(resp.body)
                payload.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress else { return }
                    var sent = 0
                    while sent < rawBuf.count {
                        let written = write(clientFD, base.advanced(by: sent), rawBuf.count - sent)
                        if written <= 0 { break }
                        sent += written
                    }
                }
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        close(listenFD)
    }
}

private var passedCount = 0
private var failedCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition() {
        fputs("  ✗ FAILED (\(file):\(line)): \(message)\n", stderr)
        failedCount += 1
    }
}

private func runTest(_ name: String, _ block: () throws -> Void) {
    let beforeFailures = failedCount
    do {
        try block()
        if failedCount == beforeFailures {
            print("  ✓ \(name)")
            passedCount += 1
        }
    } catch {
        fputs("  ✗ FAILED (\(name)): threw \(error)\n", stderr)
        failedCount += 1
    }
}

private func spinRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

private func evaluateString(_ webView: WKWebView, _ js: String) -> String? {
    var output: String?
    var done = false
    webView.evaluateJavaScript(js) { res, _ in
        if let str = res as? String {
            output = str
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(5.0)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return output
}

@main
struct StickyAITestRunner {
    static func main() {
        setenv("STICKY_AI_DISABLE_AUTO_LAUNCH_AGENT", "1", 1)
        setenv("STICKY_AI_HEADLESS_TEST", "1", 1)
        print("Running Sticky-AI Test Suite...\n")

        runTest("1. Option+Space state machine transitions match all rules") {
            check(computeHotkeyAction(isVisible: false, isFocused: false) == .showAndFocus, "Hidden -> showAndFocus")
            check(computeHotkeyAction(isVisible: false, isFocused: true) == .showAndFocus, "Hidden(true) -> showAndFocus")
            check(computeHotkeyAction(isVisible: true, isFocused: false) == .focus, "Shown unfocused -> focus")
            check(computeHotkeyAction(isVisible: true, isFocused: true) == .hide, "Shown focused -> hide")
        }

        runTest("2. Transparency rule: 1.0 when focused, 0.60 alpha when unfocused") {
            check(abs(StickyConstants.defaultUnfocusedAlpha - 0.60) < 0.001, "Default unfocused alpha is 0.60")
            check(abs(getTargetAlpha(isFocused: true) - 1.0) < 0.001, "Focused alpha is 1.0")
            check(abs(getTargetAlpha(isFocused: false) - 0.60) < 0.001, "Unfocused alpha is 0.60")
            check(abs(getTargetAlpha(isFocused: false, unfocusedAlpha: 0.40) - 0.40) < 0.001, "Custom unfocused alpha")
        }

        runTest("3. Google & Gemini auth URLs stay inside persistent browser session") {
            check(isGoogleOrLocalSessionURL(URL(string: "https://gemini.google.com/app")!), "Gemini URL stays internal")
            check(isGoogleOrLocalSessionURL(URL(string: "https://accounts.google.com/v3/signin/identifier")!), "Google Accounts stays internal")
            check(!isGoogleOrLocalSessionURL(URL(string: "https://github.com/apple/swift")!), "External link opens in system browser")
        }

        runTest("4. Compact resizable/movable window bounds persist and recover off-screen") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-unit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)
            let store = ConfigStore(directoryURL: tempDir)

            let initial = store.resolvedWindowFrame(visibleScreenFrames: [screen], primaryVisibleFrame: screen)
            check(initial.width == StickyConstants.defaultWidth && initial.height == StickyConstants.defaultHeight, "Compact default 420x560")

            let movedAndResized = CGRect(x: 200, y: 150, width: 510, height: 630)
            store.setWindowFrame(movedAndResized)

            let reloaded = ConfigStore(directoryURL: tempDir)
            check(
                reloaded.resolvedWindowFrame(visibleScreenFrames: [screen], primaryVisibleFrame: screen) == movedAndResized,
                "Persisted moved & resized bounds reload accurately"
            )

            reloaded.setWindowFrame(CGRect(x: 9000, y: 9000, width: 490, height: 605))
            let recovered = reloaded.resolvedWindowFrame(visibleScreenFrames: [screen], primaryVisibleFrame: screen)
            check(recovered.width == 490 && recovered.height == 605, "Keeps resized dimensions on recovery")
            check(recovered.minX >= 0 && recovered.maxX < 1512, "Recovers onto visible display")
        }

        runTest("5. Live macOS NSPanel + WKWebView: global Option+Space, always-on-top, 80% transparency, focus/hide & message input focus") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let mockHTML = """
            <!DOCTYPE html>
            <html>
            <body>
              <button id="other-btn" type="button">New Chat</button>
              <rich-textarea>
                <div id="gemini-prompt" class="ql-editor" contenteditable="true" role="textbox">Draft text</div>
              </rich-textarea>
            </body>
            </html>
            """
            let htmlURL = tempDir.appendingPathComponent("gemini-mock.html")
            try mockHTML.write(to: htmlURL, atomically: true, encoding: .utf8)

            let store = ConfigStore(directoryURL: tempDir)
            let controller = StickyAppController(
                configStore: store,
                websiteDataStore: .nonPersistent(),
                initialURL: htmlURL,
                enableStatusItem: false,
                registerGlobalHotKey: true
            )
            defer {
                controller.hotKeyManager.unregister()
                controller.panel.close()
            }

            check(controller.hotKeyManager.isRegistered, "Global Option+Space registered via Carbon RegisterEventHotKey")
            check(controller.panel.level == .floating, "Panel floats always on top of all windows")
            check(!controller.panel.hidesOnDeactivate, "Panel stays visible when unfocused")
            check(controller.panel.styleMask.contains(.resizable), "Panel is resizable")
            check(controller.panel.isMovable, "Panel is movable")

            controller.start()
            let loadDeadline = Date().addingTimeInterval(3.0)
            while Date() < loadDeadline {
                spinRunLoop(0.1)
                if evaluateString(controller.webView, "document.activeElement ? document.activeElement.id : ''") == "gemini-prompt" {
                    break
                }
            }

            check(controller.isWindowVisible, "Panel is visible on start")
            check(abs(controller.currentAlpha - 1.0) < 0.02, "Initial focused alpha is 1.0")
            check(evaluateString(controller.webView, "document.activeElement ? document.activeElement.id : ''") == "gemini-prompt", "Initial prompt focused")

            // Hide cycle (Rule 4)
            if controller.isWindowFocused {
                let hideAct = controller.handleOptionSpaceHotkey()
                check(hideAct == .hide, "Option+Space while shown & focused hides app")
            } else {
                controller.hideWindow()
            }
            spinRunLoop(0.12)
            check(!controller.isWindowVisible, "Panel is hidden")

            // Blur prompt inside DOM, then press Option+Space while hidden (Rule 2 & 5)
            _ = evaluateString(controller.webView, "(() => { document.getElementById('other-btn').focus(); return 'ok'; })()")
            let showAct = controller.handleOptionSpaceHotkey()
            check(showAct == .showAndFocus, "Option+Space while hidden shows and focuses app")
            spinRunLoop(0.25)

            check(controller.isWindowVisible, "Panel visible after Option+Space")
            check(abs(controller.currentAlpha - 1.0) < 0.02, "Alpha restored to 1.0")
            check(evaluateString(controller.webView, "document.activeElement ? document.activeElement.id : ''") == "gemini-prompt", "Gemini message input focused on Option+Space")
            check(evaluateString(controller.webView, "document.getElementById('gemini-prompt').textContent") == "Draft text", "Background session preserved draft text")

            // Unfocus -> 0.60 alpha (60% filled / 40% transparent) while staying visible on top (Rule 2)
            _ = evaluateString(controller.webView, "(() => { document.getElementById('other-btn').focus(); return 'ok'; })()")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.panel)
            spinRunLoop(0.1)

            check(controller.isWindowVisible, "Panel remains visible when unfocused")
            check(controller.panel.level == .floating, "Panel remains always-on-top when unfocused")
            check(abs(controller.currentAlpha - 0.60) < 0.02, "Panel becomes 0.60 alpha when unfocused")

            // Focus from unfocused via Option+Space (Rule 3 & 5)
            controller.showAndFocusWindow(focusInput: true)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.panel)
            spinRunLoop(0.25)
            check(abs(controller.currentAlpha - 1.0) < 0.02, "Alpha restored to 1.0 on Option+Space focus")
            check(evaluateString(controller.webView, "document.activeElement ? document.activeElement.id : ''") == "gemini-prompt", "Gemini message input re-focused")

            // Mouse focus restores 1.0 from 0.60 (Rule 2)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: controller.panel)
            check(abs(controller.currentAlpha - 0.60) < 0.02, "Unfocused 0.60")
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.panel)
            check(abs(controller.currentAlpha - 1.0) < 0.02, "Mouse focus restores 1.0")
        }

        runTest("6. Live Google Account Sign-In loads cleanly with native Safari WebKit engine") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-google-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let signInURL = URL(
                string: "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fgemini.google.com%2Fapp&flowName=GlifWebSignIn&flowEntry=ServiceLogin"
            )!

            let controller = StickyAppController(
                configStore: ConfigStore(directoryURL: tempDir),
                websiteDataStore: .nonPersistent(),
                initialURL: signInURL,
                enableStatusItem: false,
                registerGlobalHotKey: false
            )
            defer { controller.panel.close() }

            controller.start()
            let deadline = Date().addingTimeInterval(6.0)
            var foundInput = false
            while Date() < deadline {
                spinRunLoop(0.2)
                if evaluateString(controller.webView, "document.querySelector('input[type=\"email\"], input#identifierId, input[name=\"identifier\"]') ? 'YES' : 'NO'") == "YES" {
                    foundInput = true
                    break
                }
            }

            let ua = evaluateString(controller.webView, "navigator.userAgent") ?? ""
            let bodyText = evaluateString(controller.webView, "document.body ? document.body.innerText : ''") ?? ""

            check(foundInput, "Google Sign-In email input rendered cleanly")
            check(ua.contains("Safari/605.1.15") && !ua.contains("Electron"), "Uses native macOS Safari User-Agent")
            check(!bodyText.contains("This browser or app may not be secure"), "Google Sign-In shows no insecure browser warning")
        }

        runTest("7. DownloadHelper defaults to ~/Downloads, sanitizes filenames, and deduplicates collisions") {
            let expectedDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            check(
                DownloadHelper.defaultDownloadsDirectory().standardizedFileURL == expectedDownloads.standardizedFileURL,
                "Default downloads folder resolves to user's ~/Downloads"
            )

            check(DownloadHelper.isAttachmentContentDisposition("attachment; filename=\"Gemini_Generated_Image.png\""), "Detects attachment header")
            check(DownloadHelper.isAttachmentContentDisposition("Attachment"), "Detects bare Attachment header")
            check(!DownloadHelper.isAttachmentContentDisposition("inline; filename=\"preview.png\""), "Ignores inline header")

            let pngURL = URL(string: "https://lh3.googleusercontent.com/rd-gg-dl/sample=d")!
            let attachmentResp = HTTPURLResponse(
                url: pngURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "image/jpeg",
                    "Content-Disposition": "attachment; filename=\"Gemini_Image.jpg\""
                ]
            )!
            check(
                DownloadHelper.shouldDownloadResponse(attachmentResp, canShowMIMEType: true),
                "Attachment image response triggers download even when WebKit can display MIME type"
            )

            let inlineResp = HTTPURLResponse(
                url: pngURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            check(
                !DownloadHelper.shouldDownloadResponse(inlineResp, canShowMIMEType: true),
                "Normal inline image navigation is not forced into download"
            )
            check(
                DownloadHelper.shouldDownloadResponse(inlineResp, canShowMIMEType: false),
                "Non-displayable MIME type triggers download"
            )

            let jpegSynth = URLResponse(url: pngURL, mimeType: "image/jpeg", expectedContentLength: 100, textEncodingName: nil)
            check(
                DownloadHelper.sanitizeFilename("Gemini_Generated_Image", response: jpegSynth) == "Gemini_Generated_Image.jpg",
                "Appends inferred .jpg extension when filename has none"
            )
            check(
                DownloadHelper.sanitizeFilename("../../2026:11:03.png", response: nil) == "2026_11_03.png",
                "Strips directory traversal and replaces colons"
            )
            check(
                DownloadHelper.sanitizeFilename(".png", response: nil) == "download.png",
                "Prevents hidden dotfile names"
            )

            let tempDownloads = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-dl-unit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDownloads) }

            let first = try DownloadHelper.resolveUniqueDestinationURL(
                in: tempDownloads,
                suggestedFilename: "Gemini_Generated_Image.png"
            )
            check(first.lastPathComponent == "Gemini_Generated_Image.png", "First download keeps exact filename")
            try Data("img1".utf8).write(to: first)

            let second = try DownloadHelper.resolveUniqueDestinationURL(
                in: tempDownloads,
                suggestedFilename: "Gemini_Generated_Image.png"
            )
            check(second.lastPathComponent == "Gemini_Generated_Image (1).png", "Existing file increments to (1)")

            let third = try DownloadHelper.resolveUniqueDestinationURL(
                in: tempDownloads,
                suggestedFilename: "Gemini_Generated_Image.png",
                reservedURLs: [second]
            )
            check(third.lastPathComponent == "Gemini_Generated_Image (2).png", "In-flight reserved URL increments to (2)")
        }

        runTest("8. Live WKWebView automatically saves blob, data, attachment, and popup downloads to Downloads folder") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-dl-e2e-\(UUID().uuidString)", isDirectory: true)
            let configDir = tempRoot.appendingPathComponent("config", isDirectory: true)
            let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let samplePNGBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04])
            let sampleJPEGBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x20, 0x30, 0xFF, 0xD9])

            let server = try LocalTestHTTPServer { path in
                switch path {
                case "/attachment-image":
                    return (
                        status: "200 OK",
                        headers: [
                            ("Content-Type", "image/jpeg"),
                            ("Content-Disposition", "attachment; filename=\"Gemini_Chat_Attachment.jpg\"")
                        ],
                        body: sampleJPEGBytes
                    )
                case "/popup-download":
                    return (
                        status: "200 OK",
                        headers: [
                            ("Content-Type", "image/png"),
                            ("Content-Disposition", "attachment; filename=\"Gemini_Popup_Image.png\"")
                        ],
                        body: samplePNGBytes
                    )
                default:
                    let html = """
                    <!DOCTYPE html>
                    <html>
                    <body>
                      <div id="gemini-prompt" contenteditable="true" role="textbox">Hello</div>
                      <button id="blob-btn" type="button" onclick="triggerBlobDownload()">Download Blob</button>
                      <a id="data-link" href="data:image/png;base64,\(samplePNGBytes.base64EncodedString())" download="Gemini_Data_Image.png">Download Data</a>
                      <a id="attachment-link" href="/attachment-image">Download Attachment</a>
                      <button id="popup-btn" type="button" onclick="window.open('/popup-download', '_blank')">Download Popup</button>
                      <script>
                        function triggerBlobDownload() {
                          const bytes = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04]);
                          const blob = new Blob([bytes], { type: 'image/png' });
                          const url = URL.createObjectURL(blob);
                          const a = document.createElement('a');
                          a.href = url;
                          a.download = 'Gemini_Generated_Image.png';
                          document.body.appendChild(a);
                          a.click();
                          document.body.removeChild(a);
                          setTimeout(() => URL.revokeObjectURL(url), 1000);
                        }
                        function triggerImmediateRevokeBlobDownload() {
                          const bytes = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04]);
                          const blob = new Blob([bytes], { type: 'image/png' });
                          const url = URL.createObjectURL(blob);
                          const a = document.createElement('a');
                          a.href = url;
                          a.download = 'Gemini_Generated_Image.png';
                          document.body.appendChild(a);
                          a.click();
                          document.body.removeChild(a);
                          URL.revokeObjectURL(url);
                        }
                      </script>
                    </body>
                    </html>
                    """
                    return (
                        status: "200 OK",
                        headers: [("Content-Type", "text/html; charset=utf-8")],
                        body: Data(html.utf8)
                    )
                }
            }
            defer { server.stop() }

            let pageURL = URL(string: "http://127.0.0.1:\(server.port)/")!
            let controller = StickyAppController(
                configStore: ConfigStore(directoryURL: configDir),
                websiteDataStore: .nonPersistent(),
                initialURL: pageURL,
                downloadsDirectoryURL: downloadsDir,
                enableStatusItem: false,
                registerGlobalHotKey: false
            )
            defer { controller.panel.close() }

            var finishedURLs: [URL] = []
            var downloadErrors: [Error] = []
            controller.onDownloadFinished = { url in
                finishedURLs.append(url)
            }
            controller.onDownloadFailed = { err in
                downloadErrors.append(err)
            }

            controller.start()
            let loadDeadline = Date().addingTimeInterval(4.0)
            while Date() < loadDeadline {
                spinRunLoop(0.05)
                if evaluateString(controller.webView, "document.getElementById('blob-btn') ? 'READY' : ''") == "READY" {
                    break
                }
            }

            func waitForDownloadCount(_ targetCount: Int, timeout: TimeInterval = 4.0) {
                let deadline = Date().addingTimeInterval(timeout)
                while finishedURLs.count < targetCount && downloadErrors.isEmpty && Date() < deadline {
                    spinRunLoop(0.05)
                }
            }

            // 8a. Blob <a download>
            _ = evaluateString(controller.webView, "(() => { triggerBlobDownload(); return 'ok'; })()")
            waitForDownloadCount(1)
            check(finishedURLs.count == 1, "Blob download completed without error (\(downloadErrors))")
            if let firstURL = finishedURLs.first {
                check(firstURL.lastPathComponent == "Gemini_Generated_Image.png", "Saved Gemini_Generated_Image.png")
                check((try? Data(contentsOf: firstURL)) == samplePNGBytes, "Blob PNG bytes match exactly")
            }

            // 8b. Blob <a download> with immediate synchronous URL.revokeObjectURL + duplicate filename numbering
            _ = evaluateString(controller.webView, "(() => { triggerImmediateRevokeBlobDownload(); return 'ok'; })()")
            waitForDownloadCount(2)
            check(finishedURLs.count == 2, "Immediate-revoke blob duplicate download completed (\(downloadErrors))")
            if finishedURLs.count >= 2 {
                let secondURL = finishedURLs[1]
                check(secondURL.lastPathComponent == "Gemini_Generated_Image (1).png", "Duplicate saved as Gemini_Generated_Image (1).png")
                check((try? Data(contentsOf: secondURL)) == samplePNGBytes, "Second blob PNG bytes match exactly")
            }

            // 8c. Data URI <a download>
            _ = evaluateString(controller.webView, "(() => { document.getElementById('data-link').click(); return 'ok'; })()")
            waitForDownloadCount(3)
            check(finishedURLs.count == 3, "Data URI download completed (\(downloadErrors))")
            if finishedURLs.count >= 3 {
                let dataURL = finishedURLs[2]
                check(dataURL.lastPathComponent == "Gemini_Data_Image.png", "Saved Gemini_Data_Image.png")
                check((try? Data(contentsOf: dataURL)) == samplePNGBytes, "Data URI PNG bytes match exactly")
            }

            // 8d. HTTP Content-Disposition: attachment (even with image/jpeg MIME type)
            _ = evaluateString(controller.webView, "(() => { document.getElementById('attachment-link').click(); return 'ok'; })()")
            waitForDownloadCount(4)
            check(finishedURLs.count == 4, "HTTP Content-Disposition attachment download completed (\(downloadErrors))")
            if finishedURLs.count >= 4 {
                let attURL = finishedURLs[3]
                check(attURL.lastPathComponent == "Gemini_Chat_Attachment.jpg", "Saved Gemini_Chat_Attachment.jpg")
                check((try? Data(contentsOf: attURL)) == sampleJPEGBytes, "Attachment JPEG bytes match exactly")
            }
            check(
                evaluateString(controller.webView, "document.getElementById('gemini-prompt') ? 'STILL_ON_CHAT' : 'LEFT'") == "STILL_ON_CHAT",
                "Gemini chat page stays intact after attachment download"
            )

            // 8e. Popup window.open('/popup-download', '_blank') download
            _ = evaluateString(controller.webView, "(() => { document.getElementById('popup-btn').click(); return 'ok'; })()")
            waitForDownloadCount(5)
            check(finishedURLs.count == 5, "Popup window.open download completed (\(downloadErrors))")
            if finishedURLs.count >= 5 {
                let popURL = finishedURLs[4]
                check(popURL.lastPathComponent == "Gemini_Popup_Image.png", "Saved Gemini_Popup_Image.png")
                check((try? Data(contentsOf: popURL)) == samplePNGBytes, "Popup PNG bytes match exactly")
            }
            check(downloadErrors.isEmpty, "Zero download errors across all 5 download flows")
        }

        runTest("9. Soft-hide keeps WKWebView GPU surface & DOM warm (no orderOut black screen) and auto-recovers terminated WebContent") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-keepalive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let html = """
            <!DOCTYPE html>
            <html>
            <body>
              <div id="gemini-prompt" contenteditable="true" role="textbox">Live conversation state</div>
              <script>
                window.__bootToken = 'session-' + Math.random().toString(36).slice(2);
              </script>
            </body>
            </html>
            """
            let htmlURL = tempDir.appendingPathComponent("keepalive.html")
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)

            let store = ConfigStore(directoryURL: tempDir)
            let launchDir = tempDir.appendingPathComponent("LaunchAgents", isDirectory: true)
            let launchMgr = LaunchAtLoginManager(
                launchAgentsDirectory: launchDir,
                executablePathProvider: { "/Applications/sticky-ai.app/Contents/MacOS/StickyAI" }
            )
            let customFrame = CGRect(x: 180, y: 140, width: 460, height: 590)
            store.setWindowFrame(customFrame)

            let controller = StickyAppController(
                configStore: store,
                launchAtLoginManager: launchMgr,
                websiteDataStore: .nonPersistent(),
                initialURL: htmlURL,
                enableStatusItem: false,
                registerGlobalHotKey: false
            )
            defer { controller.panel.close() }

            controller.start()
            let loadDeadline = Date().addingTimeInterval(3.0)
            while Date() < loadDeadline {
                spinRunLoop(0.05)
                if evaluateString(controller.webView, "window.__bootToken || ''")?.hasPrefix("session-") == true {
                    break
                }
            }

            let initialBootToken = evaluateString(controller.webView, "window.__bootToken || ''") ?? ""
            check(!initialBootToken.isEmpty, "Captured initial DOM boot token")
            let visibleFrameBeforeHide = controller.panel.frame

            // Soft-hide window
            controller.hideWindow()
            spinRunLoop(0.15)

            check(!controller.isWindowVisible, "Controller reports logically hidden")
            check(controller.panel.isVisible, "Underlying NSPanel stays ordered-in so WebKit never purges GPU tiles")
            check(controller.panel.ignoresMouseEvents, "Parked hidden panel is 100% click-through")
            check(!controller.panel.canBecomeKey, "Parked hidden panel cannot steal keyboard focus")
            check(!controller.panel.hasShadow, "Parked hidden panel casts zero shadow")
            check(controller.panel.frame.size == visibleFrameBeforeHide.size, "Viewport width x height stays identical while hidden")
            if !NSScreen.screens.isEmpty {
                check(controller.panel.occlusionState.contains(.visible), "WindowServer keeps occlusionState .visible to prevent WebKit suspension")
            }
            check(
                evaluateString(controller.webView, "document.visibilityState") == "visible",
                "WebKit WebContent process keeps document.visibilityState == 'visible' while soft-hidden"
            )

            // Re-open via Option+Space: exact frame restored, exact same live JS/DOM instance (zero reload / zero black flash)
            let act = controller.handleOptionSpaceHotkey()
            check(act == .showAndFocus, "Option+Space from hidden triggers showAndFocus")
            spinRunLoop(0.15)

            check(controller.isWindowVisible, "Controller visible again")
            check(!controller.panel.ignoresMouseEvents, "Mouse interaction restored")
            check(controller.panel.canBecomeKey, "Key focus capability restored")
            check(controller.panel.hasShadow, "Shadow restored")
            check(controller.panel.frame == visibleFrameBeforeHide, "Exact visible window position & size restored")
            check(
                evaluateString(controller.webView, "window.__bootToken || ''") == initialBootToken,
                "Exact live DOM & JS heap preserved without re-rendering page"
            )

            // Simulate OS-level WebContent termination while hidden -> auto-recovers in background
            controller.hideWindow()
            spinRunLoop(0.1)
            controller.webViewWebContentProcessDidTerminate(controller.webView)
            check(controller.processTerminationRecoveryCount == 1, "Recorded background WebContent termination recovery")

            let recoverDeadline = Date().addingTimeInterval(3.0)
            while Date() < recoverDeadline {
                spinRunLoop(0.05)
                if evaluateString(controller.webView, "document.getElementById('gemini-prompt') ? 'READY' : ''") == "READY" {
                    break
                }
            }
            check(
                evaluateString(controller.webView, "document.getElementById('gemini-prompt') ? 'READY' : ''") == "READY",
                "WebContent reloaded silently in background while hidden so next open is already rendered"
            )

            // Verify Menu Bar Dropdown 'Start Automatically at Login' & 'About' options
            var dropdownMenu = controller.buildStatusMenu()
            let initialLaunchItem = dropdownMenu.items.first(where: { $0.title == "Start Automatically at Login" })
            check(initialLaunchItem != nil, "Status menu bar dropdown contains 'Start Automatically at Login' item")
            check(initialLaunchItem?.state == .off, "Launch at login initially off in isolated test directory")

            // Enable autostart via toggleLaunchAtLogin()
            let enabledNow = controller.toggleLaunchAtLogin()
            check(enabledNow && launchMgr.isEnabled, "toggleLaunchAtLogin() creates LaunchAgent plist")
            check(store.launchAtLogin == true, "ConfigStore persists launchAtLogin == true")
            if let plistData = try? Data(contentsOf: launchMgr.plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                check(plist["Label"] as? String == "com.domonk.sticky-ai", "LaunchAgent Label is com.domonk.sticky-ai")
                check(plist["RunAtLoad"] as? Bool == true, "LaunchAgent RunAtLoad == true")
                check(
                    plist["ProgramArguments"] as? [String] == ["/Applications/sticky-ai.app/Contents/MacOS/StickyAI"],
                    "LaunchAgent ProgramArguments points to sticky-ai.app binary"
                )
            } else {
                check(false, "Expected valid XML LaunchAgent plist at \(launchMgr.plistURL.path)")
            }
            dropdownMenu = controller.buildStatusMenu()
            check(
                dropdownMenu.items.first(where: { $0.title == "Start Automatically at Login" })?.state == .on,
                "Menu bar checkmark updates to .on when autostart is enabled"
            )

            // Disable autostart via toggleLaunchAtLogin()
            let disabledNow = controller.toggleLaunchAtLogin()
            check(!disabledNow && !launchMgr.isEnabled, "Second toggleLaunchAtLogin() removes LaunchAgent plist")
            check(store.launchAtLogin == false, "ConfigStore persists launchAtLogin == false")
            dropdownMenu = controller.buildStatusMenu()
            check(
                dropdownMenu.items.first(where: { $0.title == "Start Automatically at Login" })?.state == .off,
                "Menu bar checkmark updates to .off when autostart is disabled"
            )

            let aboutItem = dropdownMenu.items.first(where: { $0.title == "About" })
            check(aboutItem != nil, "Status menu bar dropdown contains 'About' item")
            controller.showAboutWindow()
            check(controller.aboutWindow != nil && controller.aboutWindow?.isVisible == true, "About window opens when triggered")
            check(controller.aboutWindow?.title.contains("DOMONK Factory") == true, "About window displays DOMONK Factory")
            check(StickyAppController.domonkFactoryURL.absoluteString == "https://domonk.com", "About window links to https://domonk.com")
            if let aboutWin = controller.aboutWindow {
                _ = controller.windowShouldClose(aboutWin)
            }
            check(controller.aboutWindow?.isVisible == false, "About window closes cleanly without quitting Sticky-AI")
        }

        runTest("10. LaunchAtLoginManager syncOnLaunch enables autostart by default on first run and respects saved false preference") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticky-ai-autostart-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cfgDir = tempDir.appendingPathComponent("cfg", isDirectory: true)
            let launchDir = tempDir.appendingPathComponent("LaunchAgents", isDirectory: true)
            var currentExec = "/Users/test/code/sticky-ai/Sticky-AI.app/Contents/MacOS/StickyAI"
            let mgr = LaunchAtLoginManager(
                launchAgentsDirectory: launchDir,
                executablePathProvider: { currentExec }
            )
            let store = ConfigStore(directoryURL: cfgDir)

            unsetenv("STICKY_AI_DISABLE_AUTO_LAUNCH_AGENT")
            defer { setenv("STICKY_AI_DISABLE_AUTO_LAUNCH_AGENT", "1", 1) }

            // First launch with nil preference -> enables automatically
            check(store.launchAtLogin == nil && !mgr.isEnabled, "Initially unconfigured")
            mgr.syncOnLaunch(configStore: store)
            check(mgr.isEnabled && store.launchAtLogin == true, "First launch enables LaunchAgent automatically")

            // Simulate app rename/move to sticky-ai.app -> syncOnLaunch refreshes ProgramArguments path
            currentExec = "/Applications/sticky-ai.app/Contents/MacOS/StickyAI"
            mgr.syncOnLaunch(configStore: store)
            if let data = try? Data(contentsOf: mgr.plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                check(
                    plist["ProgramArguments"] as? [String] == ["/Applications/sticky-ai.app/Contents/MacOS/StickyAI"],
                    "syncOnLaunch refreshes executable path after rename to sticky-ai.app"
                )
            } else {
                check(false, "Expected refreshed LaunchAgent plist")
            }

            // Explicit false preference is respected on subsequent launches
            store.launchAtLogin = false
            mgr.syncOnLaunch(configStore: store)
            check(!mgr.isEnabled, "syncOnLaunch removes plist and keeps autostart off when user disabled it")
        }

        print("\nResults: \(passedCount) passed, \(failedCount) failed")
        exit(failedCount == 0 ? 0 : 1)
    }
}
