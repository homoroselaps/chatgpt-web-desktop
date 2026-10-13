import AppKit

extension AppDelegate {
    @objc func restoreSavedDraftAction(_ sender: Any?) {
        guard !profileMutationInProgress, ProfileStore.pendingDataMutation == nil else { return }
        (BrowserWindowController.keyWindowController() ?? mainController)?.restoreSavedDraft(sender)
    }

    @objc func clearSavedDraftAction(_ sender: Any?) {
        guard !profileMutationInProgress, ProfileStore.pendingDataMutation == nil else { return }
        BrowserWindowController.clearProfileDrafts(profileID: ProfileStore.currentProfileID())
        refreshNativeUtilityWindows()
    }

    @objc func focusPromptAction(_ sender: Any?) {
        guard !profileMutationInProgress,
              ProfileStore.pendingDataMutation == nil,
              !ProfileStore.metadataRecoveryRequired else { return }
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        controller.focusPromptComposer()
    }

    @objc func insertNotesContextAction(_ sender: Any?) {
        guard !profileMutationInProgress,
              ProfileStore.pendingDataMutation == nil,
              !ProfileStore.metadataRecoveryRequired else { return }
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        guard BrowserWindowController.canInjectPromptContent(into: controller.currentURL()) else {
            presentNotesContextError("To protect note content, open a ChatGPT page in the current window first.", for: controller)
            return
        }
        controller.setStatus("Reading note…", showsProgress: false)
        NotesContextReader.readSelectedNote { result in
            DispatchQueue.main.async {
                guard !self.profileMutationInProgress,
                      ProfileStore.pendingDataMutation == nil,
                      !controller.isDisposing else {
                    return
                }
                switch result {
                case .success(let context):
                    controller.insertTextIntoPrompt(context) { errorText in
                        if let errorText {
                            controller.setStatus("Context insertion failed", showsProgress: false)
                            self.presentNotesContextError(errorText, for: controller)
                        } else {
                            controller.setStatus("Note context inserted", showsProgress: false)
                        }
                    }
                case .failure(let error):
                    controller.setStatus("Note context insertion failed", showsProgress: false)
                    self.presentNotesContextError(error, for: controller)
                }
            }
        }
    }

    private func presentNotesContextError(_ error: Error, for controller: BrowserWindowController) {
        presentNotesContextError(error.localizedDescription, for: controller)
    }

    private func presentNotesContextError(_ message: String, for controller: BrowserWindowController) {
        controller.showToast("Could not insert note: " + message, actionTitle: "Retry", action: { [weak self] in self?.insertNotesContextAction(nil) }, duration: 12)
    }
}
