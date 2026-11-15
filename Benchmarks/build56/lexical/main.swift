import Foundation

// Tab-delimited batched probe for the production implementation.
guard CommandLine.arguments.count == 2,
      let search = Lexical55(resources: URL(fileURLWithPath: CommandLine.arguments[1])) else { exit(2) }
while let line = readLine() {
    let fields = line.components(separatedBy: "\t")
    guard fields.count == 3 else { exit(3) }
    let (left, token, right) = (fields[0], fields[1], fields[2])
    let repair = search.repair(token, left: left, right: right) ?? ""
    let candidates = search.candidates(for: token, limit: 96)
    print(([repair, search.isEstablished(token) ? "known" : "unknown", search.protects(token, left: left, right: right) ? "protected" : "free"] + candidates).joined(separator: "\t"))
}
