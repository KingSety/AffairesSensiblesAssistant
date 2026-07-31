import Foundation

actor LocalSearchIndexPrewarmer {
    static let shared = LocalSearchIndexPrewarmer()

    private var preparationTask: Task<Void, Error>?

    func prepare() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task {
            try await LocalTranscriptService.prepareSearchIndex()
        }
        preparationTask = task

        do {
            try await task.value
        } catch {
            preparationTask = nil
            throw error
        }
    }
}
