import SwiftUI
import UIKit

extension View {
  /// Dismisses the keyboard (resign first responder).
  func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}
