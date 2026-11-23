import Foundation
import os.log

/// Logger for Rain SDK
public enum RainLogger {
  // MARK: - Configuration
  
  /// Thread-safe queue for configuration access
  private static let configQueue = DispatchQueue(label: "com.rain.sdk.logger.config", attributes: .concurrent)
  
  /// Private storage for isEnabled
  /// Thread-safety is ensured by configQueue synchronization
  nonisolated(unsafe) private static var _isEnabled = false
  
  /// Public logging enabled flag (can be set by SDK users)
  public static var isEnabled: Bool {
    get { configQueue.sync { _isEnabled } }
    set { configQueue.async(flags: .barrier) { _isEnabled = newValue } }
  }
  
  /// Private storage for logLevel
  /// Thread-safety is ensured by configQueue synchronization
  nonisolated(unsafe) private static var _logLevel: LogLevel = .info
  
  /// Log level for public logging
  static var logLevel: LogLevel {
    get { configQueue.sync { _logLevel } }
    set { configQueue.async(flags: .barrier) { _logLevel = newValue } }
  }
  
  /// Internal debug mode - controlled by environment variable or build setting
  /// Set RAIN_SDK_DEBUG=1 in scheme environment variables to enable
  /// This is safer than code changes and prevents accidental commits
  static var isInternalDebugEnabled: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["RAIN_SDK_DEBUG"] == "1"
    #else
    return false
    #endif
  }
  
  // MARK: - OSLog Setup
  
  private static let subsystem = "com.rain.sdk"
  private static let publicLog = OSLog(subsystem: subsystem, category: "public")
  private static let debugLog = OSLog(subsystem: subsystem, category: "debug")
  
  // MARK: - Public Logging
  
  /// Log an info message
  public static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message, level: .info, file: file, function: function, line: line)
  }
  
  /// Log a warning message
  public static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message, level: .warning, file: file, function: function, line: line)
  }
  
  /// Log an error message
  public static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    log(message, level: .error, file: file, function: function, line: line)
  }
  
  /// Generic log method
  private static func log(_ message: String, level: LogLevel, file: String, function: String, line: Int) {
    // Thread-safe read of configuration
    let (enabled, currentLogLevel) = configQueue.sync { (_isEnabled, _logLevel) }
    guard enabled, level.rawValue >= currentLogLevel.rawValue else { return }
    
    let fileName = (file as NSString).lastPathComponent
    let timestamp = DateFormatter.logFormatter.string(from: Date())
    let logMessage = "[\(timestamp)] [\(level.emoji)] [\(fileName):\(line)] \(function) - \(message)"
    
    os_log("%{public}@", log: publicLog, type: level.osLogType, logMessage)
  }
  
  // MARK: - Internal Debug Logging
  
  /// Internal debug logging for SDK developers
  public static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    guard isInternalDebugEnabled else { return }
    
    let fileName = (file as NSString).lastPathComponent
    let timestamp = DateFormatter.logFormatter.string(from: Date())
    let logMessage = "[\(timestamp)] [DEBUG] [\(fileName):\(line)] \(function) - \(message)"
    
    os_log("%{public}@", log: debugLog, type: .debug, logMessage)
  }
  
  /// Debug log for network requests/responses
  static func debugNetwork(_ message: String) {
    guard isInternalDebugEnabled else { return }
    debug("🌐 \(message)")
  }
}

// MARK: - Supporting Types

enum LogLevel: Int {
  case debug = 0
  case info = 1
  case warning = 2
  case error = 3
  
  var emoji: String {
    switch self {
    case .debug: return "🔍"
    case .info: return "ℹ️"
    case .warning: return "⚠️"
    case .error: return "❌"
    }
  }
  
  var osLogType: OSLogType {
    switch self {
    case .debug: return .debug
    case .info: return .info
    case .warning: return .default
    case .error: return .error
    }
  }
}
