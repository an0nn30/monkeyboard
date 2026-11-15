import Foundation
@main struct Overlay {
 struct Row: Decodable { var id:String; var raw:String; var displayed:String }
 static func main() async throws {
  let args=CommandLine.arguments, model=SentenceFinisher()
  let rows=try JSONDecoder().decode([Row].self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
  let resources=URL(fileURLWithPath:args[2]); let encoder=JSONEncoder()
  for row in rows {
   let line=await model.review(raw:row.raw,displayed:row.displayed,resources:resources)
   print(String(decoding:try encoder.encode(["id":row.id,"final":line]),as:UTF8.self));fflush(stdout)
  }
  let ok=await model.isReady;precondition(ok)
 }
}
