import Foundation
import WebKit

public enum FocusInput {
    public static let script: String = """
    (() => {
      const selectors = [
        'rich-textarea .ql-editor[contenteditable="true"]',
        'rich-textarea [contenteditable="true"]',
        'div.ql-editor[contenteditable="true"]',
        'div[contenteditable="true"][role="textbox"]',
        '[data-testid="message-input"]',
        '#message-input',
        'textarea[aria-label*="prompt" i]',
        'textarea[aria-label*="message" i]',
        'textarea[aria-label*="gemini" i]',
        'textarea[aria-label*="ask" i]',
        'div[contenteditable="true"]',
        'textarea:not([disabled]):not([readonly])',
        'input#identifierId:not([disabled]):not([readonly])',
        'input[name="identifier"]:not([disabled]):not([readonly])',
        'input[type="email"]:not([disabled]):not([readonly])',
        'input[type="password"]:not([disabled]):not([readonly])',
        'input[type="text"]:not([disabled]):not([readonly])'
      ];

      const isVisible = (el) => {
        if (!el) return false;
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
          return false;
        }
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };

      for (const selector of selectors) {
        const candidates = document.querySelectorAll(selector);
        for (const el of candidates) {
          if (!isVisible(el)) continue;
          const alreadyActive = document.activeElement === el;
          el.focus({ preventScroll: false });

          if (!alreadyActive) {
            if (el.isContentEditable) {
              try {
                const selection = window.getSelection();
                if (selection) {
                  const range = document.createRange();
                  range.selectNodeContents(el);
                  range.collapse(false);
                  selection.removeAllRanges();
                  selection.addRange(range);
                }
              } catch (_) {}
            } else if (typeof el.setSelectionRange === 'function' && typeof el.value === 'string') {
              try {
                const end = el.value.length;
                el.setSelectionRange(end, end);
              } catch (_) {}
            }
          }

          return {
            focused: document.activeElement === el,
            selector: selector,
            id: el.id || ''
          };
        }
      }
      return { focused: false, selector: '', id: '' };
    })();
    """

    /// Focuses the WKWebView as first responder in its window and focuses the Gemini prompt input,
    /// retrying briefly to account for macOS WindowServer key-window transition timing.
    public static func focusMessageInput(
        in webView: WKWebView,
        in window: NSWindow?,
        completion: (([String: Any]?) -> Void)? = nil
    ) {
        window?.makeFirstResponder(webView)

        webView.evaluateJavaScript(script) { [weak webView, weak window] result, _ in
            let dict = result as? [String: Any]
            let didFocus = (dict?["focused"] as? Bool) == true

            if didFocus {
                // Re-confirm after macOS finishes activating the key window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    guard let webView, let window, window.isVisible, window.isKeyWindow else { return }
                    window.makeFirstResponder(webView)
                    webView.evaluateJavaScript(script, completionHandler: nil)
                }
                completion?(dict)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard let webView else {
                    completion?(nil)
                    return
                }
                window?.makeFirstResponder(webView)
                webView.evaluateJavaScript(script) { secondRes, _ in
                    completion?(secondRes as? [String: Any])
                }
            }
        }
    }
}
