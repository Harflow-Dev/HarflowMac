import Foundation
@testable import HfRepository
import Testing

@Suite struct NullToolEnvironmentRepositoryTests {

    @Test func givenNullRepository_whenReadingTasksDirectory_thenItIsStateRootTasks() {
        // given
        let sut = NullToolEnvironmentRepository()

        // when
        let directory = sut.tasksDirectory

        // then
        #expect(directory == NSHomeDirectory() + "/.harflow/tasks")
    }
}
