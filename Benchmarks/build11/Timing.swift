import Foundation
import MonkeyBoardEngine
@main struct Timing {
    static func main(){
        let pool="book\tblog\tboo\tboot\tbug\tboom\tbog"
        for ctx in ["my left foot was getting wet when i went back upstairs to find the ",String(repeating:"hello rabbit park wind snow book garden coat rocks friend fish horse ",count:10)+"the "] {
            var times=[Double](), sink=0
            for _ in 0...500 {
                let start=DispatchTime.now().uptimeNanoseconds
                sink+=Int(mb_refine_v1(ctx,"boog","book",pool))
                times.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1e6)
            }
            let first=times.removeFirst(), sorted=times.sorted()
            print("words",ctx.split(separator:" ").count,"first_ms",first,"warm_p95_ms",sorted[474],"checksum",sink)
        }
    }
}
