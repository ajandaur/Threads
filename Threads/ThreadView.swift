//
//  ThreadView.swift
//  Threads
//
//  Minimal UI to exercise ThreadOrchestrator.send(): a scrolling list of
//  Message objects for one Workstream plus a text field and send action.
//  Styling deliberately absent — rules/ui.md governs that pass, later.
//

import SwiftUI
import SwiftData

struct ThreadView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workstream.updatedAt, order: .reverse) private var workstreams: [Workstream]

    let orchestrator: ThreadOrchestrator

    @State private var workstreamID: UUID?
    @State private var draftText = ""
    @State private var isSending = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .padding(8)
            }

            if let workstreamID {
                MessageListView(workstreamID: workstreamID)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(alignment: .bottom) {
                TextField("Message", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSending)
                    .onSubmit(send)

                Button("Send", action: send)
                    .disabled(isSending || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .task {
            ensureWorkstream()
        }
    }

    private func ensureWorkstream() {
        guard workstreamID == nil else { return }
        if let existing = workstreams.first {
            workstreamID = existing.id
            return
        }
        let created = Workstream(title: "New Thread")
        modelContext.insert(created)
        try? modelContext.save()
        workstreamID = created.id
    }

    private func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let workstreamID else { return }

        draftText = ""
        errorText = nil
        isSending = true

        Task {
            do {
                for try await _ in orchestrator.send(text, workstreamID: workstreamID) {
                    // Persisted messages arrive via the MessageListView's own
                    // @Query once ThreadOrchestrator saves; nothing to do
                    // with each chunk here beyond draining the stream.
                }
            } catch {
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }
}

private struct MessageListView: View {
    @Query private var messages: [Message]

    init(workstreamID: UUID) {
        let predicate = #Predicate<Message> { $0.workstream?.id == workstreamID }
        _messages = Query(filter: predicate, sort: \Message.createdAt)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: messages.count) {
                if let lastID = messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.roleValue == .user ? "You" : "Assistant")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
