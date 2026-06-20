import ComposableArchitecture
import SwiftUI

struct RenameBranchView: View {
  @Bindable var store: StoreOf<RenameBranchFeature>
  @FocusState private var isNameFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("\(store.vocab.bookmarkNoun) Name", text: $store.newName, prompt: Text(store.currentName))
          .focused($isNameFocused)
          .disabled(store.isSubmitting)
          .onSubmit { submit() }
      } header: {
        Text(store.vocab.renameTitle)
        Text(
          store.vocab.isJJ
            ? "Rename `\(store.currentName)` to a new bookmark name."
            : "Rename `\(store.currentName)` to a new local branch name."
        )
      } footer: {
        if let validationMessage = store.validationMessage, !validationMessage.isEmpty {
          Text(validationMessage)
            .foregroundStyle(.red)
        }
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isSubmitting {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSubmitting)
        .help("Cancel (Esc)")
        Button("Rename") {
          submit()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canSubmit)
        .help("Rename (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isNameFocused = true }
  }

  private func submit() {
    guard store.canSubmit else { return }
    store.send(.renameButtonTapped)
  }
}
