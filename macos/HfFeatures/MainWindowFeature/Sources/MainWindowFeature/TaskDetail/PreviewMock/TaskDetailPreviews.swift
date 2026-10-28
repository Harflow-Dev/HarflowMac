import HfUI
import SwiftUI

#if DEBUG
@MainActor
private func previewDetail(_ mock: TaskDetailViewModelMock = TaskDetailViewModelMock()) -> some View {
    NavigationStack { TaskDetailView(mock) }
        .frame(width: HfRadius.Metrics.taskDetailPreviewWidth, height: HfRadius.Metrics.taskDetailPreviewHeight)
}

#Preview("Long title - narrow") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle()) }
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Long title - narrow dark") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle()) }
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Long title - wide") {
    previewDetail(.longTitle())
}

#Preview("Unbroken title - narrow") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle(unbroken: true)) }
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Unbroken title - narrow dark") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle(unbroken: true)) }
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Long title - embedded") {
    TaskDetailView(TaskDetailViewModelMock.longTitle(), isEmbedded: true)
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Long title - embedded dark") {
    TaskDetailView(TaskDetailViewModelMock.longTitle(), isEmbedded: true)
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Running - light") {
    previewDetail().preferredColorScheme(.light)
}

#Preview("Running - dark") {
    previewDetail().preferredColorScheme(.dark)
}

#Preview("Finished - light") {
    previewDetail(.finished()).preferredColorScheme(.light)
}

#Preview("Finished - dark") {
    previewDetail(.finished()).preferredColorScheme(.dark)
}
#endif
