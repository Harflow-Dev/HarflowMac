import CoreGraphics
@testable import MainWindowFeature

/// Lane geometry shared by the Parallel tests, derived from the production floor so a floor change
/// keeps each test's intent ("two lanes visible", "scrolled to lane 4") instead of its literal width.
enum ParallelTestGeometry {
    /// One lane plus the divider that follows it.
    static let laneStride = ParallelLayout.minimumColumnWidth + ParallelLayout.dividerWidth
}
