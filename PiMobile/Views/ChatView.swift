import PhotosUI
import SwiftUI
import UIKit

struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let mimeType: String
    let data: Data
}

struct ChatView: View {
    @Environment(APIClient.self) private var api
    let workspace: Workspace
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var sessions: [ChatSession] = []
    @State private var session: ChatSession?
    @State private var showDiff = false
    @State private var diffStat: DiffStat?
    private var sessionId: String? { session?.id }
    @State private var running = false
    @State private var activity = ""
    @State private var model: String?   // Pi "provider/model" id; nil = session default
    @State private var thinking: String? = nil  // nil = Pi default
    @State private var approvalMode: ApprovalMode = .auto
    @State private var pendingImages: [PendingImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var cameraImage: UIImage?
    @State private var dictation = SpeechDictation()
    @State private var alertMessage: String?
    @State private var showInstallApproval = false
    @State private var pendingUI: PendingUI?
    @State private var showApprovalPrompt = false
    @State private var showModelPicker = false
    /// Active turn starts at this user message; a stable "active-turn" frame
    /// keeps it at the top while the reply grows underneath.
    @State private var pinnedMessageId: String?
    @State private var pinnedContent: String?
    /// Server message ids present when the current send started — used so
    /// optimistic rows / image pins don't latch onto an older same-text turn.
    @State private var turnBaselineIds: Set<String> = []
    /// Image-only sends have no optimistic row; pin once a *new* user message appears.
    @State private var awaitingNewUserPin = false
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var viewportHeight: CGFloat = 560
    @State private var isAtBottom = true

    private static let activeTurnID = "active-turn"
    private static let chatBottomID = "chat-bottom"

    private var turnStartIndex: Int? {
        guard let pinnedMessageId else { return nil }
        return messages.firstIndex(where: { $0.id == pinnedMessageId })
    }

    private var selectedModelId: String? { model ?? session?.model }
    private var selectedModelInfo: ModelInfo? {
        HarnessModels.info(for: selectedModelId, in: api.modelGroups)
    }
    private var modelSupportsThinking: Bool { selectedModelInfo?.supportsThinking == true }
    private var modelSupportsImages: Bool { selectedModelInfo?.images ?? true }

    var body: some View {
        chatBody
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { chatToolbar }
            .sheet(isPresented: $showDiff) { DiffView(workspace: workspace) }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    groups: api.modelGroups ?? HarnessModels.fallback,
                    model: $model,
                    thinking: $thinking,
                    sessionModel: session?.model
                )
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 6, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(image: $cameraImage).ignoresSafeArea()
            }
            .modifier(ChatOverlays(
                alertMessage: $alertMessage,
                showInstallApproval: $showInstallApproval,
                showApprovalPrompt: $showApprovalPrompt,
                pendingUI: pendingUI,
                onInstallApproval: installApprovalExtension,
                onAnswerUI: answerUI
            ))
            .onChange(of: photoItems) { _, items in
                Task { await ingestPhotoItems(items) }
            }
            .onChange(of: cameraImage) { _, img in
                if let img { addImage(img); cameraImage = nil }
            }
            .onChange(of: dictation.transcript) { _, text in
                // Keep draft in sync even for the final recognition result,
                // which may land in the same turn that flips isListening off.
                if dictation.isListening { draft = text }
            }
            .onChange(of: dictation.isListening) { _, listening in
                if !listening { draft = dictation.transcript }
            }
            .onChange(of: dictation.errorMessage) { _, msg in
                if let msg { alertMessage = msg }
            }
            .task { await load() }
            .task { await api.loadModelGroups() }
            .refreshable { await load() }
            // Drop the top-pin when leaving so re-entering lands at the bottom.
            .onDisappear { endTurnPin() }
    }

    private var chatBody: some View {
        ScrollView {
            // Eager stack: LazyVStack + scrollPosition frequently lands on the
            // wrong row while cells are still estimated.
            VStack(alignment: .leading, spacing: 14) {
                if let idx = turnStartIndex {
                    // History above the turn (scroll up to read).
                    ForEach(Array(messages.prefix(idx))) { message in
                        MessageRow(message: message, sessionId: sessionId)
                    }

                    // Stable turn frame: user message at the top, reply grows
                    // down into the remaining viewport.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(messages.suffix(from: idx))) { message in
                            MessageRow(message: message, sessionId: sessionId)
                        }
                        if running {
                            HStack {
                                Spacer(minLength: 60)
                                Text(activity.isEmpty ? "Working…" : activity)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            .padding(.trailing, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: max(viewportHeight, 1), alignment: .top)
                    .id(Self.activeTurnID)
                } else {
                    ForEach(messages) { message in
                        MessageRow(message: message, sessionId: sessionId)
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.chatBottomID)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
            viewportHeight = height
        }
        .onScrollGeometryChange(for: Bool.self, of: { geo in
            // visibleRect survives composer safeAreaInset; contentOffset math
            // does not (it looks "above bottom" even when settled there).
            let slack: CGFloat = 64
            let viewable = geo.containerSize.height
                - geo.contentInsets.top
                - geo.contentInsets.bottom
            if geo.contentSize.height <= viewable + slack { return true }
            return geo.visibleRect.maxY >= geo.contentSize.height - slack
        }, action: { _, atBottom in
            isAtBottom = atBottom
        })
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom, !messages.isEmpty {
                Button(action: jumpToBottom) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 12)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Scroll to bottom")
            }
        }
        .animation(.easeOut(duration: 0.15), value: isAtBottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
                .background(Theme.bg)
        }
    }

    private func jumpToBottom() {
        let hadPin = pinnedMessageId != nil
        endTurnPin()
        Task { @MainActor in
            // Let the turn frame collapse before scrolling, otherwise "bottom"
            // is still the empty filler under the pinned turn.
            if hadPin {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(30))
            }
            scrollPosition.scrollTo(edge: .bottom)
            await Task.yield()
            scrollPosition.scrollTo(id: Self.chatBottomID, anchor: .bottom)
        }
    }

    private func beginTurn(pinning messageId: String, content: String?) {
        pinnedMessageId = messageId
        pinnedContent = content
        // Jump once to the stable turn frame (not a per-message id).
        scrollPosition.scrollTo(id: Self.activeTurnID, anchor: .top)
    }

    /// Clears the ChatGPT-style top pin. Call when leaving the chat (or on
    /// send failure) — not when a turn finishes, or short replies jump down.
    private func endTurnPin() {
        pinnedMessageId = nil
        pinnedContent = nil
        awaitingNewUserPin = false
        turnBaselineIds = []
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let branch = workspace.branch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let stat = diffStat, !stat.isEmpty {
                Button { showDiff = true } label: {
                    HStack(spacing: 4) {
                        Text("+\(compactCount(stat.insertions))").foregroundStyle(Theme.green)
                        Text("−\(compactCount(stat.deletions))").foregroundStyle(Color(red: 0.95, green: 0.57, blue: 0.56))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            StatusBadge(status: workspace.status)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func installApprovalExtension() {
        Task {
            do {
                try await api.installApprovalExtension()
                approvalMode = .ask
            } catch {
                alertMessage = error.localizedDescription
                approvalMode = .auto
            }
        }
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) && !running
    }

    private var composerPlaceholder: String {
        "Ask \(prettyModel(selectedModelId))"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img.image)
                                    .resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Button {
                                    pendingImages.removeAll { $0.id == img.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                }
            }

            TextField(composerPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 4)
                .onSubmit { send() }

            HStack(spacing: 14) {
                plusButton
                approvalButton
                modelButton
                Spacer(minLength: 0)
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var plusButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            .disabled(!modelSupportsImages)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!modelSupportsImages)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
        }
    }

    private var approvalButton: some View {
        Menu {
            Picker("Approval", selection: $approvalMode) {
                ForEach(ApprovalMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } label: {
            Image(systemName: approvalMode == .ask ? "exclamationmark.shield.fill" : "checkmark.shield")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(approvalMode == .ask
                    ? Color(red: 0.95, green: 0.72, blue: 0.45)
                    : Theme.textTertiary)
                .frame(width: 28, height: 28)
        }
        .onChange(of: approvalMode) { _, mode in
            guard mode == .ask else { return }
            Task {
                let installed = (try? await api.approvalExtensionStatus())?.installed ?? false
                // Ask already works via bundled -e for phone turns; offer optional
                // install so desktop `pi` sessions get the same gate.
                if !installed { showInstallApproval = true }
            }
        }
    }

    private var modelButton: some View {
        Button { showModelPicker = true } label: {
            HStack(spacing: 5) {
                Text(prettyModel(selectedModelId))
                    .foregroundStyle(Theme.text)
                if let thinking, modelSupportsThinking {
                    Text(ThinkingLevel(rawValue: thinking)?.label ?? thinking.capitalized)
                        .foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
        }
        .onChange(of: model) { _, newValue in
            let info = HarnessModels.info(for: newValue ?? session?.model, in: api.modelGroups)
            if info?.supportsThinking != true {
                thinking = nil
            } else if let thinking, !info!.thinkingLevels.contains(thinking) {
                self.thinking = nil
            }
        }
    }

    private var micButton: some View {
        Button {
            dictation.toggle(into: &draft)
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(dictation.isListening ? Theme.accent : Theme.text)
                .frame(width: 28, height: 28)
        }
    }

    private var sendButton: some View {
        Button {
            if running {
                Task { if let sessionId { try? await api.stop(sessionId: sessionId) } }
            } else {
                send()
            }
        } label: {
            ZStack {
                if running {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.12, green: 0.12, blue: 0.13))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? Color(red: 0.12, green: 0.12, blue: 0.13) : Theme.textMuted)
                }
            }
            .frame(width: 34, height: 34)
            .background(
                running ? Theme.accent
                    : (canSend ? Color.white : Color.white.opacity(0.08)),
                in: Circle()
            )
        }
        .disabled(!running && !canSend)
        .accessibilityLabel(running ? "Stop" : "Send")
    }

    private func send() {
        guard canSend else { return }
        if dictation.isListening { dictation.stop() }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages.map {
            PromptImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType)
        }
        draft = ""
        pendingImages = []
        photoItems = []
        turnBaselineIds = Set(messages.filter { !$0.id.hasPrefix("local-") }.map(\.id))
        // Show the user bubble immediately — refresh() remaps the pin to the
        // server id. The turn frame id stays "active-turn" so nothing jumps.
        if !text.isEmpty {
            let localId = "local-\(UUID().uuidString)"
            messages.append(ChatMessage(
                id: localId,
                role: "user",
                content: text,
                createdAt: Date()
            ))
            awaitingNewUserPin = false
            beginTurn(pinning: localId, content: text)
        } else {
            // Image-only: wait for a user row that wasn't already on the server.
            awaitingNewUserPin = true
            pinnedContent = nil
        }
        running = true
        Task {
            // A workspace with no chats yet has no session — create one on first send.
            var sid = sessionId
            if sid == nil, let s = try? await api.createSession(workspaceId: workspace.id) {
                sessions.insert(s, at: 0)
                session = s
                sid = s.id
            }
            guard let sid else {
                running = false
                endTurnPin()
                draft = text
                messages.removeAll { $0.id.hasPrefix("local-") }
                return
            }
            do {
                try await api.send(
                    sessionId: sid,
                    text: text,
                    model: model,
                    thinking: thinking,
                    approvalMode: approvalMode.rawValue,
                    images: images
                )
            } catch {
                alertMessage = error.localizedDescription
                running = false
                endTurnPin()
                draft = text
                messages.removeAll { $0.id.hasPrefix("local-") }
                return
            }
            await refresh()
            await poll()
        }
    }

    private func poll() async {
        guard let sessionId else { return }
        while running {
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            // ponytail: any failed status check stops polling; pull-to-refresh restarts it
            guard let status = try? await api.status(sessionId: sessionId) else {
                running = false
                pendingUI = nil
                showApprovalPrompt = false
                return
            }
            activity = status.activity
            if let ui = status.pendingUI, pendingUI?.id != ui.id {
                pendingUI = ui
                showApprovalPrompt = true
            }
            await refresh()
            if !status.running {
                running = false
                // Keep the active-turn frame and re-assert the scroll target so
                // short replies don't settle near the composer. Bottom landing
                // only happens after leaving the chat.
                if pinnedMessageId != nil {
                    scrollPosition.scrollTo(id: Self.activeTurnID, anchor: .top)
                }
                pendingUI = nil
                showApprovalPrompt = false
            }
        }
    }

    private func answerUI(id: String, confirmed: Bool? = nil, value: String? = nil, cancelled: Bool? = nil) async {
        guard let sessionId else { return }
        showApprovalPrompt = false
        pendingUI = nil
        try? await api.respondUI(sessionId: sessionId, id: id, confirmed: confirmed, value: value, cancelled: cancelled)
    }

    private func addImage(_ image: UIImage) {
        let rendered = image.resizedForUpload()
        guard let data = rendered.jpegData(compressionQuality: 0.82) else { return }
        pendingImages.append(PendingImage(image: rendered, mimeType: "image/jpeg", data: data))
    }

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                addImage(image)
            }
        }
        photoItems = []
    }

    private func load() async {
        sessions = (try? await api.sessions(workspaceId: workspace.id)) ?? sessions
        if session == nil { session = sessions.first }
        diffStat = try? await api.diffStat(workspaceId: workspace.id)
        await refresh()
        if let sessionId, let status = try? await api.status(sessionId: sessionId), status.running {
            running = true
            activity = status.activity
            await poll()
        }
    }

    private func refresh() async {
        guard let sessionId else { return }
        let latest = (try? await api.messages(sessionId: sessionId)) ?? messages
        // Keep the optimistic user row until a *new* server copy exists (same
        // text as an older turn must not suppress or steal the pin).
        let locals = messages.filter { $0.id.hasPrefix("local-") }
        var merged = latest
        for local in locals {
            let hasNewCopy = merged.contains {
                $0.role == "user"
                    && $0.content == local.content
                    && !turnBaselineIds.contains($0.id)
            }
            if !hasNewCopy { merged.append(local) }
        }
        messages = merged

        if awaitingNewUserPin,
           let lastUser = merged.last(where: { $0.role == "user" && !turnBaselineIds.contains($0.id) }) {
            beginTurn(pinning: lastUser.id, content: lastUser.content)
            awaitingNewUserPin = false
        } else if let pin = pinnedMessageId, !merged.contains(where: { $0.id == pin }) {
            // Remap local-* → server id; turn frame id stays "active-turn".
            if let content = pinnedContent,
               let match = merged.last(where: {
                   $0.role == "user" && $0.content == content && !turnBaselineIds.contains($0.id)
               }) {
                pinnedMessageId = match.id
            }
        }
    }
}

private extension UIImage {
    func resizedForUpload(maxDimension: CGFloat = 1600) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

private struct ChatOverlays: ViewModifier {
    @Binding var alertMessage: String?
    @Binding var showInstallApproval: Bool
    @Binding var showApprovalPrompt: Bool
    let pendingUI: PendingUI?
    let onInstallApproval: () -> Void
    let onAnswerUI: (String, Bool?, String?, Bool?) async -> Void

    private var showError: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("Something went wrong", isPresented: showError) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .alert("Install approval extension?", isPresented: $showInstallApproval) {
                Button("Install", action: onInstallApproval)
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Ask mode already works for phone turns. Install the bundled extension if you also want the same confirmations in desktop pi.")
            }
            .confirmationDialog(
                pendingUI?.title ?? "Allow tool?",
                isPresented: $showApprovalPrompt,
                titleVisibility: .visible
            ) {
                if let ui = pendingUI {
                    if ui.method == "select", let options = ui.options {
                        ForEach(options, id: \.self) { opt in
                            Button(opt) { Task { await onAnswerUI(ui.id, nil, opt, nil) } }
                        }
                    } else {
                        Button("Allow") { Task { await onAnswerUI(ui.id, true, nil, nil) } }
                        Button("Deny", role: .destructive) { Task { await onAnswerUI(ui.id, false, nil, nil) } }
                    }
                    Button("Cancel", role: .cancel) { Task { await onAnswerUI(ui.id, nil, nil, true) } }
                }
            } message: {
                Text(pendingUI?.message ?? "")
            }
    }
}

// Desktop-pasted files may appear in message text as "@⟦name⟧(url-encoded-relative-path)".
struct Attachment: Identifiable {
    let name: String
    let path: String
    var id: String { path }
    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((name as NSString).pathExtension.lowercased()) }
}

func parseAttachments(_ text: String) -> (text: String, attachments: [Attachment]) {
    var attachments: [Attachment] = []
    var stripped = text
    while let m = stripped.range(of: #"@⟦([^⟧]*)⟧\(([^)]+)\)"#, options: .regularExpression) {
        let token = String(stripped[m])
        let name = String(token.dropFirst(2).prefix(while: { $0 != "⟧" }))
        let path = token.split(separator: "(").last.map { String($0.dropLast()) } ?? ""
        attachments.append(Attachment(name: name, path: path.removingPercentEncoding ?? path))
        stripped.removeSubrange(m)
    }
    return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), attachments)
}

struct AttachmentImage: View {
    @Environment(APIClient.self) private var api
    let sessionId: String
    let attachment: Attachment
    @State private var image: UIImage?
    @State private var fullscreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { fullscreen = true }
                    .fullScreenCover(isPresented: $fullscreen) {
                        ImageViewer(image: image)
                    }
            } else {
                Label(attachment.name, systemImage: "photo")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(10)
                    .background(Theme.toolBg, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            if let data = try? await api.attachment(sessionId: sessionId, path: attachment.path) {
                image = UIImage(data: data)
            }
        }
    }
}

struct ImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .containerRelativeFrame(scale <= 1 ? [.horizontal, .vertical] : [])
                    .frame(width: scale > 1 ? UIScreen.main.bounds.width * scale : nil)
            }
            .defaultScrollAnchor(.center)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = max(1, lastScale * $0.magnification) }
                    .onEnded { _ in lastScale = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { scale = scale > 1 ? 1 : 2.5; lastScale = scale }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.15), in: Circle())
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var sessionId: String?

    var body: some View {
        switch message.role {
        case "thinking":
            ThinkingRow(text: message.content)
        case "duration":
            Text(message.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, -6)
        case "user":
            let parsed = parseAttachments(message.content)
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 8) {
                    if let sessionId {
                        ForEach(parsed.attachments) { att in
                            if att.isImage {
                                AttachmentImage(sessionId: sessionId, attachment: att)
                            } else {
                                Label(att.name, systemImage: "doc")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    if !parsed.text.isEmpty {
                        Text(parsed.text)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Color(red: 0.93, green: 0.93, blue: 0.94))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(
                                Color(red: 0.118, green: 0.118, blue: 0.14),
                                in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                           bottomTrailingRadius: 5, topTrailingRadius: 18)
                            )
                            .copyable(parsed.text)
                    }
                }
            }
        case "tool":
            ToolRow(content: message.content)
        default:
            MarkdownText(markdown: message.content)
                .copyable(message.content)
        }
    }
}

extension View {
    // Long-press any message to copy it, like the desktop's copy button.
    func copyable(_ text: String) -> some View {
        contextMenu {
            Button { UIPasteboard.general.string = text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

struct ThinkingRow: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Thinking")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
                    .copyable(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRow: View {
    let content: String   // "ToolName arg-summary"

    private var tag: String { content.split(separator: " ").first.map(String.init) ?? "TOOL" }
    private var label: String { content.dropFirst(tag.count).trimmingCharacters(in: .whitespaces) }
    private var isEdit: Bool { ["Edit", "Write", "NotebookEdit"].contains(tag) }

    var body: some View {
        HStack(spacing: 9) {
            Text(tag.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .kerning(0.8)
                .foregroundStyle(isEdit ? Color(red: 0.66, green: 0.72, blue: 0.91) : Color(red: 0.58, green: 0.86, blue: 0.66))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                    (isEdit ? Theme.accent.opacity(0.12) : Theme.green.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.toolBg, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
