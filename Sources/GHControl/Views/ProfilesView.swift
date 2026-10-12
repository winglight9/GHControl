import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @State private var isImporting = false
    @State private var importRole: ImportRole?
    @State private var baselineData: Data?
    @State private var baselineName: String?
    @State private var diff: ProfileDiff?
    @State private var searchText = ""
    @State private var errorMessage = ""
    @State private var isShowingError = false

    private var visibleChanges: [ProfileChange] {
        guard let diff else { return [] }
        guard !searchText.isEmpty else { return diff.changes }
        return diff.changes.filter {
            $0.key.localizedCaseInsensitiveContains(searchText)
                || ($0.before?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.after?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    eyebrow: "WINDOWS PROFILE RESEARCH",
                    title: "配置方案",
                    subtitle: "导入 Windows Adrenalin 的基线与调节后 XML，检查 GH 面板实际改变了哪些原始字段。"
                )

                VStack(alignment: .leading, spacing: 14) {
                    Label("比较两份 Windows 配置", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Text("先在 Windows 中导出默认配置，再单独选择它；之后导出只改动一个控件后的配置，再单独选择。建议每次只改 Power Limit、核心频率或 HBM 频率中的一项。应用只解析并展示 XML 字段差异，不会执行其中的设置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        importRole = .baseline
                        isImporting = true
                    } label: {
                        Label(baselineName == nil ? "选择默认/基线 XML" : "更换默认/基线 XML", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    if let baselineName {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("基线：\(baselineName)")
                                .font(.caption.weight(.medium))
                                .textSelection(.enabled)
                        }
                        Button {
                            importRole = .tuned
                            isImporting = true
                        } label: {
                            Label("选择调节后的 XML", systemImage: "doc.badge.plus")
                        }
                    }

                    if let diff {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("已比较：\(diff.baselineName) → \(diff.tunedName)")
                                .font(.caption.weight(.medium))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1) }

                if let diff {
                    diffSummary(diff)
                    if diff.changes.isEmpty {
                        ContentUnavailableViewCompat(
                            title: "没有发现差异",
                            symbol: "equal.circle",
                            message: "两份 XML 的叶字段相同；确认第二份文件确实来自修改后的 GH 配置。"
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("原始字段差异").font(.headline)
                                Spacer()
                                TextField("筛选字段或值", text: $searchText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 260)
                            }

                            ForEach(visibleChanges) { change in
                                ProfileChangeRow(change: change)
                            }
                            if visibleChanges.isEmpty {
                                Text("没有符合筛选条件的字段。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 80)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1) }
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("为什么先做 XML 差分？").font(.callout.weight(.semibold))
                            Text("Windows 端已确认能调节 GH 的功耗与频率。先从该机器真实导出的配置找出字段变化，再研究其与 macOS PowerPlay 表的关系；不会把其他 Radeon 型号的字段含义套过来。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("macOS 配置应用仍关闭", systemImage: "lock.shield")
                        .font(.callout.weight(.semibold))
                    Text("字段差分只说明 XML 内容变了。需要继续确认字段语义、GH 专用表结构、驱动接受情况、读回结果和实际 GPU 变化，才可以生成可应用的 macOS 设置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false,
            onCompletion: importProfiles
        )
        .alert("无法比较配置", isPresented: $isShowingError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func diffSummary(_ diff: ProfileDiff) -> some View {
        HStack(spacing: 18) {
            SummaryValue(title: "字段差异", value: "\(diff.changes.count)", tint: .blue)
            SummaryValue(title: "基线字段", value: "\(diff.baselineFieldCount)", tint: .secondary)
            SummaryValue(title: "调节后字段", value: "\(diff.tunedFieldCount)", tint: .secondary)
            Spacer()
            Label("未解释的原始字段", systemImage: "questionmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func importProfiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { throw ImportError.noFile }
            let fileData = try readScopedFile(url)
            switch importRole {
            case .baseline:
                baselineData = fileData
                baselineName = url.lastPathComponent
                diff = nil
            case .tuned:
                guard let baselineData, let baselineName else { throw ImportError.baselineRequired }
                diff = try AdrenalinProfileParser.compare(
                    baselineData: baselineData,
                    baselineName: baselineName,
                    tunedData: fileData,
                    tunedName: url.lastPathComponent
                )
            case nil:
                throw ImportError.noFile
            }
            searchText = ""
        } catch {
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func readScopedFile(_ url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private enum ImportError: LocalizedError {
        case noFile
        case baselineRequired

        var errorDescription: String? {
            switch self {
            case .noFile: "没有选择 XML 文件。"
            case .baselineRequired: "请先选择默认/基线 XML。"
            }
        }
    }

    private enum ImportRole {
        case baseline
        case tuned
    }
}

private struct SummaryValue: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProfileChangeRow: View {
    let change: ProfileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Text(kindLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(kindTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(kindTint.opacity(0.1), in: Capsule())
                Text(change.key)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let before = change.before {
                ValueLine(label: "基线", value: before, tint: .secondary)
            }
            if let after = change.after {
                ValueLine(label: "调节后", value: after, tint: .blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var kindLabel: String {
        switch change.kind {
        case .added: "新增"
        case .removed: "移除"
        case .changed: "改变"
        }
    }

    private var kindTint: Color {
        switch change.kind {
        case .added: .green
        case .removed: .red
        case .changed: .orange
        }
    }
}

private struct ValueLine: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).frame(width: 46, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.monospaced())
        .foregroundStyle(tint)
    }
}

private struct ContentUnavailableViewCompat: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}
