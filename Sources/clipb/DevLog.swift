#if DEV_PERSIST
import os

private let devLogger = Logger(subsystem: "com.productmind.clipb", category: "dev")

/// Dev builds only. Never pass clipboard values; app ids and status codes only.
/// Marked public: NSLog's %@ shows up as <private> in `log show`.
/// Read with: log show --last 3m --predicate 'process == "clipb"' | grep clipb-dev
func devLog(_ message: @autoclosure () -> String) {
    let text = message()
    devLogger.notice("clipb-dev: \(text, privacy: .public)")
}
#else
@inline(__always) func devLog(_ message: @autoclosure () -> String) {}
#endif
