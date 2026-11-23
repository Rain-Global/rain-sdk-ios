import Foundation

enum FileHelpers {
  public static func readJSONFile<O: Decodable>(
    forName name: String,
    type: O.Type
  ) -> O? {
    do {
      if let bundlePath = Bundle.module.path(forResource: name, ofType: "json"),
         let jsonData = try String(contentsOfFile: bundlePath).data(using: .utf8) {
        return try JSONDecoder().decode(type, from: jsonData)
      }
    } catch {
      print("FileHelpers: Error reading JSON file as string \(name).json - \(error)")
    }
    return nil
  }
}
