import Foundation
import os

/// Console logging for the sample app.
enum SampleLog {
  private static let logger = Logger(subsystem: "RainSample", category: "demo")

  static func d(_ area: String, _ message: String) {
    logger.debug("[\(area, privacy: .public)] \(message, privacy: .public)")
  }

  static func i(_ area: String, _ message: String) {
    logger.info("[\(area, privacy: .public)] \(message, privacy: .public)")
  }

  static func w(_ area: String, _ message: String) {
    logger.warning("[\(area, privacy: .public)] \(message, privacy: .public)")
  }

  static func e(_ area: String, _ message: String) {
    logger.error("[\(area, privacy: .public)] \(message, privacy: .public)")
  }

  static func maskToken(_ value: String?) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "<empty>" }
    guard value.count > 8 else { return "***" }
    return "\(value.prefix(4))…\(value.suffix(4)) (len=\(value.count))"
  }

  static func maskEmail(_ value: String?) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "<empty>" }
    guard let at = value.firstIndex(of: "@"), value.distance(from: value.startIndex, to: at) > 1
    else { return "***" }
    let name = value[value.startIndex..<at]
    return "\(name.prefix(1))\(String(repeating: "*", count: max(name.count - 1, 1)))\(value[at...])"
  }
}
