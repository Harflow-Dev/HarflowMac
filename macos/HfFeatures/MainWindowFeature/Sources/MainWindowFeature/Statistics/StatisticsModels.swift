import Foundation

// MARK: - Statistics presentation

enum StatisticsRange: Int, CaseIterable, Sendable { case seven = 7, thirty = 30, ninety = 90 }
enum StatisticsMeasure: String, CaseIterable, Sendable { case time = "Total time", usage = "Usage" }
enum StatisticsList: String, CaseIterable, Sendable { case workflows = "Workflows", tasks = "Tasks", harnesses = "Harnesses" }
enum StatisticsScreenState: Equatable, Sendable { case loading, empty(String), error(String), unsupported(String), ready }

struct StatisticsOption: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
}

struct StatisticsBar: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var accessibilityLabel: String
    var workflowFraction: Double
    var taskFraction: Double
}

struct StatisticsChart: Equatable, Sendable {
    var title = "Total time"
    var total = "Unavailable"
    var caption = ""
    var workflowTotal = "Unavailable"
    var taskTotal = "Unavailable"
    var topAxis = ""
    var middleAxis = ""
    var bottomAxis = ""
    var bars: [StatisticsBar] = []
    var gap: Double = 2
    var disclosure: String?
}

struct StatisticsChildRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var value: String
    var secondaryValue: String
    var fraction: Double
    var statusGlyph: String?
    var statusLabel: String?
    var isFailure = false
}

struct StatisticsRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var value: String
    var secondaryValue: String
    var fraction: Double
    var isExpanded = false
    var children: [StatisticsChildRow] = []
    var childrenTitle = ""
    var childrenFooter = ""
    var canShowNodes = false
    var rank: Int?
    var glyph: String?
    var harnessDot = false
    var share: String?
    var kindLabel: String?
}

struct StatisticsNodePage: Equatable, Sendable {
    var workflowID: String
    var title: String
    var subtitle: String
    var wallTime: String
    var executionTime: String
    var usage: String
    var rows: [StatisticsRow]
    var footer: String
    var runs = "Unavailable"
    var runsBreakdown = ""
    var rankingTitle = "Nodes by execution time"
    var primaryColumn = "Execution time"
    var secondaryColumn = "Usage"
}

struct StatisticsPresentation: Equatable, Sendable {
    var state: StatisticsScreenState = .loading
    var range: StatisticsRange = .thirty
    var measure: StatisticsMeasure = .time
    var list: StatisticsList = .workflows
    var repository: String?
    var harness: String?
    var requestedModel: String?
    var repositoryLabel: String?
    var harnessLabel: String?
    var modelLabel: String?
    var repositoryOptions: [StatisticsOption] = []
    var harnessOptions: [StatisticsOption] = []
    var modelOptions: [StatisticsOption] = []
    var coverage: [String] = []
    var chart = StatisticsChart()
    var rows: [StatisticsRow] = []
    var listTitle = "Workflows by total time"
    var listFooter = ""
    var primaryColumn = "Total time"
    var secondaryColumn = "Usage"
    var nodes: StatisticsNodePage?
    var refreshFailure: String?
}
