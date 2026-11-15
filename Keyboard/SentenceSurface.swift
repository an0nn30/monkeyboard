import Foundation
import MonkeyBoardEngine

/// Attribute short lexical edits to the user's words. Punctuation, whitespace,
/// case, and any new prose a generative model adds are never copied wholesale.
enum SentenceSurface {
    static let matcher = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+(?:['’][\p{L}\p{M}]+)*"#)
    struct Form {
        var text: String
        var ranges: [NSRange]
        var words: [String]
        init(_ s: String) {
            text = s
            let ns = s as NSString
            ranges = SentenceSurface.matcher.matches(in:s,range:NSRange(location:0,length:ns.length)).map(\.range)
            words = ranges.map { ns.substring(with:$0) }
        }
        func replace(_ edits: [Int:String]) -> String {
            let result = NSMutableString(string:text)
            for i in edits.keys.sorted(by:>) { result.replaceCharacters(in:ranges[i],with:edits[i]!) }
            return result as String
        }
    }
    static func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of:"’",with:"'") }
    static func dist(_ a: String, _ b: String) -> Int {
        let x=Array(norm(a).utf8), y=Array(norm(b).utf8)
        var prev=Array(0...y.count), older=prev
        for (i,c) in x.enumerated() {
            var now=[i+1]
            for (j,d) in y.enumerated() {
                var v=min(now[j]+1,prev[j+1]+1,prev[j]+(c==d ? 0:1))
                if i>0 && j>0 && c==y[j-1] && x[i-1]==d { v=min(v,older[j-1]+1) }
                now.append(v)
            }
            older=prev; prev=now
        }
        return prev[y.count]
    }
    // A result may only substitute a token or insert a space inside that same
    // token. If the model deleted/added a word we cannot align, abstain.
    static func correspondence(_ raw: Form, _ output: String) -> [String]? {
        let v=Form(output).words, n=raw.words.count
        guard n>0, n<=48, v.count>=n, v.count<=n+5 else { return nil }
        if n==v.count { return v }
        var cost = Array(repeating:Array(repeating:10000,count:v.count+1),count:n+1), take=cost
        cost[0][0]=0
        for i in 0..<n {
            for j in 0..<v.count where cost[i][j]<10000 {
                for k in 1...min(3,v.count-j) {
                    let s=v[j..<j+k].joined(), d=dist(raw.words[i],s)
                    guard k==1 || d<=1 else { continue }
                    let score=cost[i][j]+4*d+k-1
                    if score<cost[i+1][j+k] { cost[i+1][j+k]=score; take[i+1][j+k]=k }
                }
            }
        }
        guard cost[n][v.count]<10000 else {return nil}
        var result=Array(repeating:"",count:n), j=v.count
        for i in (1...n).reversed() { let k=take[i][j]; result[i-1]=v[j-k..<j].joined(separator:" "); j-=k }
        return result
    }
    static func contraction(_ word: String, left: String, right: String) -> String? {
        guard (2...24).contains(word.utf8.count), word.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
        }), !left.utf8.contains(0), !right.utf8.contains(0) else { return nil }
        var out = [CChar](repeating: 0, count: 48)
        guard mb_contraction_v1(left, word, right, &out, out.count) == 1 else { return nil }
        return String(cString: out)
    }

    /// Reconcile the words actually typed with later sentence proposals. Keep
    /// punctuation and unrelated edits, including a split elsewhere in the span.
    static func restoringContractions(in raw: String, proposed: String, leading: String) -> String {
        guard !raw.contains("@"), !raw.contains("://") else { return proposed }
        let source = Form(raw)
        let original = raw as NSString
        var repairs = [Int: String]()
        for (index, range) in source.ranges.enumerated() {
            let left = leading + original.substring(to: range.location)
            let right = original.substring(from: NSMaxRange(range))
            if let fix = contraction(source.words[index], left: left, right: right) {
                repairs[index] = fix
            }
        }
        guard !repairs.isEmpty, let aligned = correspondence(source, proposed) else { return proposed }
        let output = Form(proposed)
        let result = NSMutableString(string: proposed)
        var end = output.words.count
        for i in aligned.indices.reversed() {
            let size = aligned[i].split(separator: " ").count
            let start = end - size
            if let fix = repairs[i], fix != aligned[i] {
                let range = NSUnionRange(output.ranges[start], output.ranges[end - 1])
                result.replaceCharacters(in: range, with: fix)
            }
            end = start
        }
        return result as String
    }

    static func admissible(_ source:String, _ candidate:String, first:Bool) -> String? {
        let a=norm(source), b=norm(candidate)
        guard a != b, source.allSatisfy({$0.isASCII && ($0.isLetter || "'’".contains($0))}),
              candidate.allSatisfy({$0.isASCII && ($0.isLetter || "'’ ".contains($0))}),
              first || source==source.lowercased(), source.count<30,
              source.count==1 || source != source.uppercased() else {return nil}
        let compact=b.replacingOccurrences(of:" ",with:"")
        let d=dist(a,compact)
        guard d<=max(1,min(3,(a.count+1)/3)) else {return nil}
        if b.contains(" "), d>1 {return nil}
        if source.first?.isUppercase == true {
            return b.prefix(1).uppercased()+b.dropFirst()
        }
        return b
    }
}
