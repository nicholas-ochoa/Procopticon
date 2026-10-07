import SwiftUI

/// A page listed in the sidebar of a properties or inspector window.
protocol SidebarPage: Hashable, Identifiable, CaseIterable where AllCases: RandomAccessCollection {
    var title: String { get }
    var symbol: String { get }
}

/// Window layout with its pages listed in a sidebar and the selected page beside it (process and
/// service properties, the executable inspector). Open the window with `fullSizeContent` so the
/// sidebar runs up under the title bar.
struct SidebarPagesView<Page: SidebarPage, Detail: View, Footer: View>: View {
    @Binding var selection: Page
    @ViewBuilder var detail: (Page) -> Detail
    /// Shown at the bottom of the sidebar, for controls that apply to every page.
    @ViewBuilder var footer: Footer

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { if let page = $0 { selection = page } })) {
                ForEach(Page.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        } detail: {
            detail(selection)
        }
    }
}

extension SidebarPagesView where Footer == EmptyView {
    init(selection: Binding<Page>, @ViewBuilder detail: @escaping (Page) -> Detail) {
        self.init(selection: selection, detail: detail, footer: { EmptyView() })
    }
}
