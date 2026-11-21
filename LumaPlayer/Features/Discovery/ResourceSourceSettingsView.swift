import SwiftUI

/// 搜索源维护页(设置 → 找资源)。
///
/// 这是「资源来源可维护」那条要求的落点:源清单是用户的数据,不是代码里的常量。
/// 会话分析的结论是 PanSou 那 100+ 个源**会腐烂**(站点关停、加反爬),所以这里必须能
/// 「加一条 / 改地址 / 停用 / 删掉」,而不是等发版。
struct ResourceSourceSettingsView: View {
    let container: AppContainer

    @State private var sources: [ResourceSource] = []
    @State private var loadFailure: String?
    @State private var saveFailure: String?
    /// 正在编辑的条目;`isNew` 为 true 时是新增
    @State private var editing: EditingSource?
    @State private var isSaving = false

    /// 新增 / 编辑的表单状态
    private struct EditingSource: Identifiable {
        let id: String
        var isNew: Bool
        var draft: ResourceSource
    }

    var body: some View {
        Form {
            Section {
                if let loadFailure {
                    Label(loadFailure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if sources.isEmpty {
                    Text("没有搜索源")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        row(for: source)
                    }
                }
            } header: {
                HStack {
                    Text("搜索源")
                    InfoHint(text: "本模块自己不带资源:它把关键词发给这些源,再把结果归一化后展示。"
                        + "源的可信度、可用性由你自己判断 —— 转存前请确认链接来源。")
                    Spacer()
                    Button("添加…") { addSource() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(item: $editing) { editing in
            ResourceSourceEditor(
                draft: editing.draft,
                isNew: editing.isNew,
                supportedKinds: ResourceSourceAdapterKind.allCases,
                onCancel: { self.editing = nil },
                onSave: { updated in
                    Task { await save(updated, isNew: editing.isNew) }
                })
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { saveFailure != nil },
                set: { if !$0 { saveFailure = nil } }
            )
        ) {
            Button("好") { saveFailure = nil }
        } message: {
            Text(saveFailure ?? "")
        }
    }

    private func row(for source: ResourceSource) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingM) {
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { isEnabled in
                    var updated = source
                    updated.isEnabled = isEnabled
                    Task { await save(updated, isNew: false) }
                }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(source.displayName)
                    .font(.body)
                Text(source.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let note = source.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let problem = source.validationFailure {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button("编辑…") {
                editing = EditingSource(id: source.id, isNew: false, draft: source)
            }
            .controlSize(.small)
            Button(role: .destructive) {
                Task { await remove(source) }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("删除这个搜索源")
        }
    }

    // MARK: - 动作

    private func reload() async {
        sources = await container.resourceSources.sources()
        loadFailure = await container.resourceSources.lastLoadFailureDescription()
    }

    private func addSource() {
        let draft = ResourceSource(
            id: "tg-\(UUID().uuidString.prefix(8))",
            displayName: "",
            kind: .telegramChannel,
            baseURL: "")
        editing = EditingSource(id: draft.id, isNew: true, draft: draft)
    }

    private func save(_ source: ResourceSource, isNew: Bool) async {
        var updated = sources
        if isNew {
            updated.append(source)
        } else if let index = updated.firstIndex(where: { $0.id == source.id }) {
            updated[index] = source
        } else {
            updated.append(source)
        }
        await persist(updated, closingEditor: true)
    }

    private func remove(_ source: ResourceSource) async {
        await persist(sources.filter { $0.id != source.id }, closingEditor: false)
    }

    private func persist(_ updated: [ResourceSource], closingEditor: Bool) async {
        do {
            try await container.resourceSources.save(updated)
            sources = await container.resourceSources.sources()
            if closingEditor { editing = nil }
        } catch {
            saveFailure = "写入搜索源清单失败:\(error.localizedDescription)"
        }
    }
}

/// 单条搜索源的编辑表单。
private struct ResourceSourceEditor: View {
    let draft: ResourceSource
    let isNew: Bool
    let supportedKinds: [ResourceSourceAdapterKind]
    var onCancel: () -> Void
    var onSave: (ResourceSource) -> Void

    @State private var displayName: String
    @State private var baseURL: String
    @State private var kind: ResourceSourceAdapterKind
    @State private var note: String
    @State private var validationMessage: String?

    init(
        draft: ResourceSource,
        isNew: Bool,
        supportedKinds: [ResourceSourceAdapterKind],
        onCancel: @escaping () -> Void,
        onSave: @escaping (ResourceSource) -> Void
    ) {
        self.draft = draft
        self.isNew = isNew
        self.supportedKinds = supportedKinds
        self.onCancel = onCancel
        self.onSave = onSave
        self._displayName = State(initialValue: draft.displayName)
        self._baseURL = State(initialValue: draft.baseURL)
        self._kind = State(initialValue: draft.kind)
        self._note = State(initialValue: draft.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingL) {
            Text(isNew ? "添加搜索源" : "编辑搜索源")
                .font(.title3.bold())
            Form {
                TextField("名称", text: $displayName, prompt: Text("比如「资源宇宙7」"))
                Picker("抓取方式", selection: $kind) {
                    ForEach(supportedKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField(kind.addressIsChannelName ? "频道" : "地址", text: $baseURL,
                          prompt: Text(kind.baseURLHint))
                    .textFieldStyle(.roundedBorder)
                TextField("备注(可选)", text: $note, prompt: Text("比如「只发国漫」"))
            }
            .formStyle(.grouped)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Metrics.spacingXL)
        .frame(width: Metrics.onboardingFormWidth, height: 300)
    }

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationMessage = "名称不能为空。"
            return
        }
        guard !url.isEmpty else {
            validationMessage = "地址不能为空。"
            return
        }
        // 用户常只写 `192.168.1.2:8888`:补协议,⛔ 不猜 https(自建实例多半是 http)。
        // 频道档存的是频道名,⛔ 不能补成 URL —— 补了就成 `http://tgsearchers7` 这种无效值。
        if !kind.addressIsChannelName, !url.contains("://") { url = "http://" + url }
        var updated = draft
        updated.displayName = name
        updated.baseURL = url
        updated.kind = kind
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        if let problem = updated.validationFailure {
            validationMessage = problem
            return
        }
        validationMessage = nil
        onSave(updated)
    }
}
