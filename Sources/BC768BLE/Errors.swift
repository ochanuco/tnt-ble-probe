import Foundation

extension NSError {
    var logDescription: String {
        "\(localizedDescription) (domain=\(domain) code=\(code))"
    }
}

func describeError(_ error: Error?) -> String? {
    guard let error else { return nil }
    return (error as NSError).logDescription
}
