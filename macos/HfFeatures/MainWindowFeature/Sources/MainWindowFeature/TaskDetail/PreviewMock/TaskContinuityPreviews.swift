import SwiftUI

#if DEBUG
#Preview("Restart continuity · light") {
    TaskDetailView(TaskDetailViewModelMock.continuity()).frame(width: 1000, height: 620).preferredColorScheme(.light)
}

#Preview("Restart continuity · dark") {
    TaskDetailView(TaskDetailViewModelMock.continuity()).frame(width: 1000, height: 620).preferredColorScheme(.dark)
}
#endif
