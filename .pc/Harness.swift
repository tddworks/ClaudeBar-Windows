import ClaudeBarWindows
import Foundation
import Leaderboard

// THROWAWAY, never committed: the same Client, settings file and Credential
// Manager key as ClaudeBar.exe. Prints outcomes only, never a key.
@MainActor func main() async {
    let client = Client()
    let membership = client.membership()
    switch CommandLine.arguments.dropFirst().first ?? "" {
    case "join-hidden":
        let name = Username("cbwsmoke\(Int.random(in: 1000...9999))")!
        do {
            try await membership.join(as: name, sharing: ["omp"])
            try await membership.setVisible(false)
            print("joined hidden as \(name.value)")
        } catch {
            print("error: \(error)")
        }
    case "status":
        print("joined=\(membership.isJoined) user=\(membership.username?.value ?? "-") visible=\(membership.isVisible) copiedKey=\(membership.holdsCopiedKey)")
    case "leave":
        do {
            try await membership.leave()
            print("left")
        } catch {
            print("error: \(error)")
        }
    default:
        print("usage: harness join-hidden | status | leave")
    }
}

await main()
