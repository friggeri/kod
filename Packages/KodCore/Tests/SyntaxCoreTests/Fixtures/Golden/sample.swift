import Foundation

/// A sample doc comment.
struct Greeter {
    let name: String
    static let defaultGreeting = "Hello"

    func greet(loudly: Bool = false) -> String {
        let message = "\(Self.defaultGreeting), \(name)!"
        if loudly {
            return message.uppercased()
        }
        return message
    }
}

let greeter = Greeter(name: "World")
print(greeter.greet(loudly: true))
