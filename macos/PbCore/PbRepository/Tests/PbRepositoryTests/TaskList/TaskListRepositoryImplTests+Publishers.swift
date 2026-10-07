import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

extension TaskListRepositoryImplTests {
    @Test func givenRepeatedRefreshes_whenStateIsEqual_thenStatePublishersStayQuietAndTaskRefreshPulseRemains() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let result = LockedBox<Result<CtlClient, ToolError>>(.success(ctlClient(listing: ["a"])))
        given(environment).ctl().willProduce { result.value }
        let sut = makeSUT(toolEnvironment: environment)
        let listed = LockedBox<[Bool]>([])
        let errors = LockedBox<[ToolError?]>([])
        let tasks = LockedBox<[[TaskInfo]]>([])
        let subscriptions = [
            sut.hasListedPublisher().sink { value in listed.mutate { $0.append(value) } },
            sut.listErrorPublisher().sink { value in errors.mutate { $0.append(value) } },
            sut.tasksPublisher().sink { value in tasks.mutate { $0.append(value) } }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        // when
        await sut.refresh()
        await sut.refresh()
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: [])
        result.mutate { $0 = .failure(error) }
        await sut.refresh()
        await sut.refresh()
        result.mutate { $0 = .success(ctlClient(listing: ["a"])) }
        await sut.refresh()
        // then
        #expect(listed.value == [false, true])
        #expect(errors.value == [nil, error, nil])
        #expect(tasks.value.filter { $0.map(\.taskID) == ["a"] }.count == 3)
        let late = LockedBox<[Bool]>([])
        let subscription = sut.hasListedPublisher().sink { value in late.mutate { $0.append(value) } }
        defer { subscription.cancel() }
        #expect(late.value == [true])
    }
}
