import SwiftUI
import DiskCore

/// Le bilan d'une passe et ce qu'on peut en faire, dans une feuille — maquette 13.
///
/// La feuille porte sa propre pile : relancer un autre outil ou comparer à
/// une autre passe s'y ouvre sans quitter le bilan, et lancer quoi que ce soit
/// la referme et montre la passe.
struct PassReportSheet: View {

    @ObservedObject var model: SimulationModel
    let record: PassRecord
    /// La passe vient d'être lancée : la feuille se ferme, l'onglet Passe
    /// s'ouvre.
    let onLaunched: () -> Void
    /// Rouvre le défilement du disque, là où il en est. Absent là où il n'y a
    /// pas de défilement à rouvrir — depuis l'onglet Passe, par exemple.
    var onResumeLife: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PassReportScreen(model: model, record: record, onLaunched: launched,
                             onResumeLife: onResumeLife.map { resume in { dismiss(); resume() } })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.close") { dismiss() }
                    }
                }
        }
        .tint(Theme.read)
        .preferredColorScheme(.dark)
    }

    private func launched() {
        dismiss()
        onLaunched()
    }
}

private struct PassReportScreen: View {

    @ObservedObject var model: SimulationModel
    let record: PassRecord
    let onLaunched: () -> Void
    /// Rouvre le défilement, quand l'écran d'où vient le bilan en a un.
    var onResumeLife: (() -> Void)?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let start = record.startMap, let end = record.endMap {
                        maps(start: start, end: end)
                    }
                    ReportRows(record: record)
                    if let summary = record.summary {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Theme.write)
                            Text(summary)
                                .font(.dynamic(size: 12))
                                .foregroundStyle(Theme.text.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                    }
                    actions
                }
                .padding(16)
            }
        }
        .navigationTitle("report.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: String(localized: "report.finished",
                                  defaultValue: "FINISHED · \(Format.duration(record.duration).uppercased())",
                                  comment: "Bandeau du bilan, en capitales : la durée de la passe"))
                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.read)
            Text(record.toolLabel)
                .font(.dynamic(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text([record.title, record.disk.map { $0.spec.fileSystemLabel }].compactMap { $0 }
                    .joined(separator: " · "))
                .font(.dynamic(size: 12, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }

    private func maps(start: (grid: MapGrid, shades: [ClusterShade]),
                      end: (grid: MapGrid, shades: [ClusterShade])) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.kind == .install ? "report.map.blank" : "report.map.before")
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                ClusterMapView(grid: start.grid, shades: start.shades)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.kind == .install ? "report.map.installed" : "report.map.after")
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                ClusterMapView(grid: end.grid, shades: end.shades)
            }
        }
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("report.maps.accessibility")
    }

    @ViewBuilder
    private var actions: some View {
        let others = model.otherDefrags(than: record)
        VStack(spacing: 10) {
            if let disk = record.disk {
                if record.kind == .day {
                    // Le défilement a la main sur la suite, et c'est bien lui
                    // que le bilan propose : il n'offrait rien du tout, alors
                    // que son commentaire promettait de le rouvrir
                    // (`UX_REVIEW.md` §2.5).
                    if let onResumeLife {
                        Button(action: onResumeLife) {
                            actionLabel("report.action.resumeLife",
                                        systemImage: "clock.arrow.circlepath", primary: true)
                        }
                    }
                } else if record.installed != nil {
                    Button {
                        model.loadInstalledBoot(from: record)
                        model.engine.play()
                        onLaunched()
                    } label: {
                        actionLabel("report.action.bootFresh", systemImage: "power", primary: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        DefragToolChoiceScreen(disk: disk) { disk, activity, strategy in
                            try model.load(generated: disk, as: activity, using: strategy)
                            model.engine.play()
                            onLaunched()
                        }
                    } label: {
                        actionLabel("report.action.otherTool", systemImage: "arrow.triangle.2.circlepath", primary: true)
                    }
                    .buttonStyle(.plain)
                }

                if !record.arrangement.isEmpty {
                    Button {
                        model.loadRangedBoot(from: record)
                        model.engine.play()
                        onLaunched()
                    } label: {
                        actionLabel("report.action.bootTidied", systemImage: "power", primary: false)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("report.compare.header")
                        .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    ForEach(others) { other in
                        NavigationLink {
                            PassComparisonScreen(a: record, b: other)
                        } label: {
                            HStack {
                                Text(other.toolLabel)
                                    .font(.dynamic(size: 14))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text(Format.duration(other.duration))
                                    .font(.dynamic(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.dim)
                                Image(systemName: "chevron.right")
                                    .font(.dynamic(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.dim)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }

            ShareLink(item: shareText) {
                actionLabel("report.action.share", systemImage: "square.and.arrow.up", primary: false)
            }
            .buttonStyle(.plain)

        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, primary: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title).font(.dynamic(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(primary ? Theme.read : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(primary ? Color.clear : Color.white.opacity(0.16), lineWidth: 1)
        )
        .foregroundStyle(primary ? Theme.background : Theme.text)
    }

    /// Le bilan en texte, tel qu'il se colle dans un message.
    private var shareText: String {
        var lines = ["Winchester — \(record.title)",
                     "\(record.toolLabel), \(Format.duration(record.duration))"]
        func field(_ label: String, _ value: String) -> String { "\(label) : \(value)" }
        if let before = record.before, let after = record.after {
            lines.append(field(String(localized: "report.row.fragmentedFiles", defaultValue: "Fragmented files"),
                               "\(before.fragmentedFiles) → \(after.fragmentedFiles)"))
            lines.append(field(String(localized: "report.row.piecesToMerge", defaultValue: "Pieces to merge"),
                               "\(before.fragments) → \(after.fragments)"))
            lines.append(field(String(localized: "report.row.freeHoles", defaultValue: "Free holes"),
                               "\(before.freeHoles) → \(after.freeHoles)"))
        }
        if record.kind == .install {
            lines.append(field(String(localized: "report.row.filesLaid", defaultValue: "Files laid down"), "\(record.filesMoved)"))
            lines.append(field(String(localized: "report.row.written", defaultValue: "Written"),
                               Format.megabytes(UInt64(record.movedBytes))))
        } else {
            lines.append(field(String(localized: "report.row.moved", defaultValue: "Moved"),
                               Format.megabytes(UInt64(record.movedBytes))))
            lines.append(field(String(localized: "report.row.evacuations", defaultValue: "Evacuations"), "\(record.evacuations)"))
        }
        if let summary = record.summary { lines.append(summary) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

/// Avant → après, ligne à ligne.
private struct ReportRows: View {
    let record: PassRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let before = record.before, let after = record.after {
                row(String(localized: "report.row.fragmentedFiles", defaultValue: "Fragmented files"),
                    Format.integer(before.fragmentedFiles), Format.integer(after.fragmentedFiles))
                row(String(localized: "report.row.piecesToMerge", defaultValue: "Pieces to merge"),
                    Format.integer(before.fragments), Format.integer(after.fragments))
                row(String(localized: "report.row.freeHoles", defaultValue: "Free holes"),
                    Format.integer(before.freeHoles), Format.integer(after.freeHoles))
            }
            if record.kind == .day {
                // Une journée ne range rien : elle écrit ce que l'usage écrit.
                single(String(localized: "report.row.written", defaultValue: "Written"), Format.megabytes(UInt64(record.movedBytes)))
                single(String(localized: "report.row.requests", defaultValue: "Requests"), Format.integer(record.requests))
                single(String(localized: "report.row.seeks", defaultValue: "Seeks"), Format.integer(record.seeks))
            } else if record.kind == .install {
                // Une installation ne déplace rien : elle écrit ce qu'elle pose,
                // les tables et le registre en plus.
                single(String(localized: "report.row.written", defaultValue: "Written"), Format.megabytes(UInt64(record.movedBytes)))
                single(String(localized: "report.row.filesLaid", defaultValue: "Files laid down"), Format.integer(record.filesMoved))
                if let metrics = record.installed?.metrics {
                    single(String(localized: "report.row.fragmentedOnArrival", defaultValue: "Fragmented on arrival"),
                           Format.integer(metrics.fragmentedFileCount))
                    single(String(localized: "report.row.freeHoles", defaultValue: "Free holes"), Format.integer(metrics.freeRunCount))
                }
            } else {
                let moved = Format.megabytes(UInt64(record.movedBytes))
                single(String(localized: "report.row.moved", defaultValue: "Moved"),
                       record.contentBytes > 0
                           ? String(localized: "report.row.moved.share",
                                    defaultValue: "\(moved) (\(Format.percent(Double(record.movedBytes) / record.contentBytes)) of the contents)")
                           : moved)
                single(String(localized: "report.row.filesMoved", defaultValue: "Files moved"), Format.integer(record.filesMoved))
                single(String(localized: "report.row.evacuations", defaultValue: "Evacuations"), Format.integer(record.evacuations))
            }
            single(String(localized: "report.row.requests", defaultValue: "Requests"), Format.integer(record.requests))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func row(_ label: String, _ before: String, _ after: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.dynamic(size: 13)).foregroundStyle(Theme.text)
            Spacer()
            Text(before).font(.dynamic(size: 13, design: .monospaced)).foregroundStyle(Theme.dim)
            Text(verbatim: "→").font(.dynamic(size: 13, design: .monospaced)).foregroundStyle(Theme.dim)
            Text(after)
                .font(.dynamic(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.read)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .monospacedDigit()
    }

    private func single(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.dynamic(size: 13)).foregroundStyle(Theme.text)
            Spacer()
            Text(value)
                .font(.dynamic(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
        .monospacedDigit()
    }
}

/// Deux passes sur le même disque, en colonnes — sans verdict.
///
/// Chaque ligne marque la valeur la plus basse, parce que chacune de ces
/// mesures est un coût ou un reste. Rien ne les additionne : un outil qui
/// range mieux et un outil qui va plus vite ne font pas le même travail.
struct PassComparisonScreen: View {
    let a: PassRecord
    let b: PassRecord

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("compare.title")
                            .font(.dynamic(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.text)
                        Text(a.title)
                            .font(.dynamic(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }

                    VStack(spacing: 10) {
                        HStack {
                            Text(verbatim: "").frame(maxWidth: .infinity, alignment: .leading)
                            column("A · \(a.toolLabel)")
                            column("B · \(b.toolLabel)")
                        }
                        if let aAfter = a.after, let bAfter = b.after {
                            line(String(localized: "report.row.fragmentedFiles", defaultValue: "Fragmented files"),
                                 Double(aAfter.fragmentedFiles), Double(bAfter.fragmentedFiles))
                            line(String(localized: "compare.row.totalPieces", defaultValue: "Pieces in total"),
                                 Double(aAfter.fragments), Double(bAfter.fragments))
                            line(String(localized: "report.row.freeHoles", defaultValue: "Free holes"),
                                 Double(aAfter.freeHoles), Double(bAfter.freeHoles))
                        }
                        line(String(localized: "compare.row.duration", defaultValue: "Duration"), a.duration, b.duration) {
                            $0 < 60 ? Format.decimal($0, digits: 1) + "\u{00A0}s" : Format.duration($0)
                        }
                        line(String(localized: "compare.row.bytesMoved", defaultValue: "Bytes moved"),
                             Double(a.movedBytes), Double(b.movedBytes)) {
                            Format.megabytes(UInt64($0))
                        }
                        line(String(localized: "report.row.evacuations", defaultValue: "Evacuations"),
                             Double(a.evacuations), Double(b.evacuations))
                        line(String(localized: "report.row.requests", defaultValue: "Requests"),
                             Double(a.requests), Double(b.requests))
                    }
                    .panel()

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(Theme.write)
                        Text("compare.note")
                            .font(.dynamic(size: 12))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .panel()
                }
                .padding(16)
            }
        }
        .navigationTitle("compare.navTitle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private func column(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.dim)
            .lineLimit(2)
            .frame(width: 96, alignment: .trailing)
    }

    private func line(_ label: String, _ left: Double, _ right: Double,
                      format: (Double) -> String = { Format.integer(Int($0.rounded())) }) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.dynamic(size: 13))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Deux valeurs qui s'écrivent pareil ne se départagent pas à l'écran.
            let tie = format(left) == format(right)
            cell(format(left), best: !tie && left < right)
            cell(format(right), best: !tie && right < left)
        }
        .monospacedDigit()
    }

    private func cell(_ text: String, best: Bool) -> some View {
        Text(text)
            .font(.dynamic(size: 13, weight: best ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(best ? Theme.read : Theme.text)
            .frame(width: 96, alignment: .trailing)
    }
}
