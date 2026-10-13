import Foundation
import WebKit

extension BrowserWindowController {
    func focusPromptComposer(completion: ((String?) -> Void)? = nil) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else {
            completion?("Open a ChatGPT page first")
            return
        }
        show()
        setStatus("Focusing input…", showsProgress: true)
        focusPromptComposer(attemptsRemaining: 8, completion: completion)
    }

    func insertTextIntoPrompt(_ text: String, completion: @escaping (String?) -> Void) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else {
            completion("To protect local content, text can only be inserted into ChatGPT pages")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("No text to insert")
            return
        }

        show()
        setStatus("Inserting context…", showsProgress: false)
        insertTextIntoPrompt(trimmed, attemptsRemaining: 8, completion: completion)
    }

    private func insertTextIntoPrompt(
        _ text: String,
        attemptsRemaining: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else {
            completion("Insertion canceled because the page has left ChatGPT")
            return
        }
        webView.evaluateJavaScript(Self.insertPromptTextScript(text: text)) { [weak self] result, error in
            guard let self else {
                return
            }
            guard !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                completion("Insertion canceled while the profile is being cleared")
                return
            }
            if let error {
                if attemptsRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.insertTextIntoPrompt(text, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                completion("Insertion failed: \(error.localizedDescription)")
                return
            }

            guard let report = result as? [String: Any],
                  Self.promptBoolValue(report["ok"]) else {
                if attemptsRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.insertTextIntoPrompt(text, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                completion("ChatGPT input box not found")
                return
            }

            completion(nil)
        }
    }

    private func focusPromptComposer(attemptsRemaining: Int, completion: ((String?) -> Void)? = nil) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else {
            setStatus("Open a ChatGPT page first", showsProgress: false)
            completion?("Open a ChatGPT page first")
            return
        }
        webView.evaluateJavaScript(Self.focusPromptComposerScript) { [weak self] result, error in
            guard let self else {
                return
            }
            guard !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                completion?("Focus canceled while the profile is being cleared")
                return
            }
            if let error {
                if attemptsRemaining > 0 {
                    self.setStatus("Waiting for ChatGPT input…", showsProgress: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.focusPromptComposer(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                self.setStatus("Could not focus input", showsProgress: false)
                completion?("Could not focus input: \(error.localizedDescription)")
                return
            }
            guard let report = result as? [String: Any],
                  Self.promptBoolValue(report["ok"]) else {
                if attemptsRemaining > 0 {
                    self.setStatus("Waiting for ChatGPT input…", showsProgress: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.focusPromptComposer(attemptsRemaining: attemptsRemaining - 1, completion: completion)
                    }
                    return
                }
                self.setStatus("Input box not found", showsProgress: false)
                completion?("ChatGPT input box not found")
                return
            }
            self.setStatus("Input focused", showsProgress: false)
            completion?(nil)
        }
    }

    static let focusPromptComposerScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      if (!isChatGPTPage) {
        return { ok: false, reason: 'untrusted origin' };
      }

      const visible = (element) => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
      const composer =
        firstVisible('textarea[data-testid="prompt-textarea"]') ||
        firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
        firstVisible('#prompt-textarea') ||
        firstVisible('textarea') ||
        firstVisible('[role="textbox"]') ||
        firstVisible('div[contenteditable="true"]');

      if (!composer) {
        return { ok: false };
      }
      composer.focus();
      if (typeof composer.scrollIntoView === 'function') {
        composer.scrollIntoView({ block: 'center', inline: 'nearest' });
      }
      return { ok: true };
    })()
    """

    static func insertPromptTextScript(text: String) -> String {
        let textLiteral = promptJavaScriptStringLiteral(text)
        return """
        (() => {
          const host = String(location.hostname || '').toLowerCase();
          const isChatGPTPage = location.protocol === 'https:' && (
            host === 'chatgpt.com' ||
            host.endsWith('.chatgpt.com') ||
            host === 'chat.openai.com' ||
            host.endsWith('.chat.openai.com')
          );
          if (!isChatGPTPage) {
            return { ok: false, reason: 'untrusted origin' };
          }

          const text = \(textLiteral);
          const visible = (element) => {
            if (!element) return false;
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const placeCaretAtEnd = (element) => {
            const selection = window.getSelection();
            if (!selection) return;
            const range = document.createRange();
            range.selectNodeContents(element);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
          };
          const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
          const composer =
            firstVisible('textarea[data-testid="prompt-textarea"]') ||
            firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
            firstVisible('#prompt-textarea') ||
            firstVisible('textarea') ||
            firstVisible('[role="textbox"]') ||
            firstVisible('div[contenteditable="true"]');

          if (!composer) {
            return { ok: false };
          }

          composer.focus();
          if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
            const prefix = composer.value && !composer.value.endsWith('\\n') ? '\\n\\n' : '';
            const nextValue = composer.value + prefix + text;
            const descriptor = Object.getOwnPropertyDescriptor(
              composer instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
              'value'
            );
            if (descriptor?.set) {
              descriptor.set.call(composer, nextValue);
            } else {
              composer.value = nextValue;
            }
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            composer.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            const existingText = composer.textContent || '';
            placeCaretAtEnd(composer);
            if (existingText.trim().length > 0) {
              document.execCommand('insertText', false, '\\n\\n' + text);
            } else {
              document.execCommand('insertText', false, text);
            }
            composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            composer.dispatchEvent(new Event('change', { bubbles: true }));
          }
          return { ok: true };
        })()
        """
    }

    private static func promptBoolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return string == "true" || string == "1"
        }
        return false
    }

    private static func promptJavaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }
}
