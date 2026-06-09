import SwiftUI
import Charts

struct UsageDonut: View {
    let results: [CategoryResult]
    private var domain: [String] { results.map(\.definition.title) }
    private var range: [Color] { results.map(\.definition.tint) }

    var body: some View {
        Chart(results) { r in
            SectorMark(angle: .value("Size", r.totalSize),
                       innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(by: .value("Category", r.definition.title))
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(position: .trailing, alignment: .center, spacing: 6)
    }
}
