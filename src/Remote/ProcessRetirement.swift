import Foundation

enum ProcessRetirement {
    static func retireOnMain(_ process: Process?) {
        guard let process else { return }
        DispatchQueue.main.async {
            withExtendedLifetime(process) {}
        }
    }
}
