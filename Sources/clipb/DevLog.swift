#if DEV_PERSIST
import Foundation

/// Dev builds only. Never pass clipboard values; app ids and status codes only.
/// Read with: log show --last 3m --predicate 'process == "clipb"'
func devLog(_ message: @autoclosure () -> String) {
    NSLog("clipb-dev: %@", message())
}
#else
@inline(__always) func devLog(_ message: @autoclosure () -> String) {}
#endif
