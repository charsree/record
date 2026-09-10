import AppKit
import SwiftUI

/// A tidy menu button next to the paperclip that lists saved prompt
/// templates, injects one into the input on selection, and opens a manager
/// sheet for creating / editing / deleting templates.
struct PromptLibraryMenu: View {
    @ObservedObject private var library = PromptLibrary.shared
    let onSelect: (PromptTemplate) -> Void
    @State private var managerOpen = false

    var body: some View {
        Menu {
            if library.prompts.isEmpty {
                Text("No saved prompts")
            } else {
                ForEach(library.prompts) { template in
                    Button(template.name) { onSelect(template) }
                }
            }
            Divider()
            Button {
                managerOpen = true
            } label: {
                Label("Manage prompts…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a saved prompt template or manage the library")
        .sheet(isPresented: $managerOpen) {
            PromptLibraryManager()
        }
    }
}

private struct PromptLibraryManager: View {
    @ObservedObject private var library = PromptLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PromptTemplate.ID?
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var showRestoreConfirmation = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.prompts) { template in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(.headline)
                        Text(template.body).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(template.id)
                }
            }
            .frame(minWidth: 260)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        let new = PromptTemplate(name: "New prompt", body: "")
                        library.append(new)
                        selection = new.id
                        draftName = new.name
                        draftBody = new.body
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a new prompt")
                    Button {
                        if let id = selection {
                            library.remove(id)
                            selection = nil
                            draftName = ""
                            draftBody = ""
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    .help("Delete the selected prompt")
                    Menu {
                        Button("Restore defaults", role: .destructive) {
                            showRestoreConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                if selection == nil {
                    ContentUnavailableView(
                        "Pick a prompt on the left",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Or hit + to create a new one.")
                    )
                } else {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                    Text("Prompt body")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draftBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                        )
                    HStack {
                        Spacer()
                        Button("Revert") { syncDraftFromSelection() }
                            .disabled(!hasUnsavedChanges)
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!hasUnsavedChanges || draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding()
            .frame(minWidth: 460, minHeight: 360)
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle("Prompt library")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onChange(of: selection, initial: true) { _, _ in syncDraftFromSelection() }
        .confirmationDialog(
            "Restore the built-in defaults?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                library.restoreDefaults()
                selection = library.prompts.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces your current prompt library with the built-in templates.")
        }
    }

    private var hasUnsavedChanges: Bool {
        guard let id = selection,
              let template = library.prompts.first(where: { $0.id == id }) else { return false }
        return draftName != template.name || draftBody != template.body
    }

    private func syncDraftFromSelection() {
        guard let id = selection,
              let template = library.prompts.first(where: { $0.id == id }) else {
            draftName = ""; draftBody = ""
            return
        }
        draftName = template.name
        draftBody = template.body
    }

    private func save() {
        guard let id = selection,
              let index = library.prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = library.prompts[index]
        updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        library.update(updated)
    }
}
