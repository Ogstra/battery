import Foundation
import ObjectiveC

// Corrected signatures derived from method type encodings via class_copyMethodList.
// All enable*/disable* methods are synchronous (take NSError **, return BOOL).
// Async variants have "WithHandler:" suffix — not needed here.
@objc protocol SmartChargeClientProtocol: NSObjectProtocol {
    func enableMCL(_ error: NSErrorPointer) -> Bool
    func disableMCL(_ error: NSErrorPointer) -> Bool
    func setMCLLimit(_ limit: UInt8, error: NSErrorPointer) -> Bool
    func getMCLLimitWithError(_ error: NSErrorPointer) -> UInt8
    func temporarilyDisableMCL(_ error: NSErrorPointer) -> Bool
    func enableSmartCharging(_ error: NSErrorPointer) -> Bool
    func disableSmartCharging(_ error: NSErrorPointer) -> Bool
    func temporarilyEnableCharging(_ error: NSErrorPointer) -> Bool
    func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64   // Q = NSUInteger
    func isOBCEngaged(_ engaged: UnsafeMutablePointer<ObjCBool>?,
                      isMaxChargeLimited limited: UnsafeMutablePointer<ObjCBool>?,
                      chargingOverrideAllowed override: UnsafeMutablePointer<ObjCBool>?,
                      withError error: NSErrorPointer) -> Bool
}

func batteryPct() -> Int {
    let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    t.arguments = ["-g", "batt"]
    let p = Pipe(); t.standardOutput = p
    try? t.run(); t.waitUntilExit()
    let s = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let r = s.range(of: #"\d+%"#, options: .regularExpression),
       let n = Int(s[r].dropLast()) { return n }
    return -1
}

guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil else {
    fputs("Failed to load PowerUI: \(String(cString: dlerror()))\n", stderr); exit(1)
}
guard let raw = NSClassFromString("PowerUISmartChargeClient") else {
    fputs("PowerUISmartChargeClient not found\n", stderr); exit(1)
}
guard let rawObj = class_createInstance(raw, 0) else {
    fputs("class_createInstance failed\n", stderr); exit(1)
}
guard let rawInstance = (rawObj as AnyObject)
    .perform(NSSelectorFromString("initWithClientName:"), with: "charge-control")?
    .takeRetainedValue() else {
    fputs("initWithClientName: failed\n", stderr); exit(1)
}
let client = unsafeBitCast(rawInstance, to: SmartChargeClientProtocol.self)

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
let arg2    = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

switch command {

case "on":
    var err: NSError? = nil
    let ok = client.disableMCL(&err)
    if let err { fputs("error: \(err)\n", stderr); exit(1) }
    print(ok ? "charging: on (MCL disabled)" : "disableMCL returned false")
    exit(ok ? 0 : 1)

case "off":
    let pct = batteryPct()
    guard pct > 0 else { fputs("could not read battery %\n", stderr); exit(1) }
    var err: NSError? = nil
    let ok = client.setMCLLimit(UInt8(pct), error: &err)
    if let err { fputs("error: \(err)\n", stderr); exit(1) }
    if ok {
        var err2: NSError? = nil
        _ = client.enableMCL(&err2)
    }
    print(ok ? "charging: off (limit frozen at \(pct)%)" : "setMCLLimit returned false")
    exit(ok ? 0 : 1)

case "limit", "maintain":
    guard let pct = arg2.flatMap(Int.init), (1...100).contains(pct) else {
        fputs("Usage: charge-control \(command) <1-100>\n", stderr); exit(1)
    }
    var err: NSError? = nil
    let ok = client.setMCLLimit(UInt8(pct), error: &err)
    if let err { fputs("error: \(err)\n", stderr); exit(1) }
    if ok {
        var err2: NSError? = nil
        _ = client.enableMCL(&err2)
    }
    print(ok ? "limit: \(pct)%" : "setMCLLimit returned false")
    exit(ok ? 0 : 1)

case "status":
    var err: NSError? = nil
    let mcl = client.getMCLLimitWithError(&err)
    let pct = batteryPct()
    print("battery:    \(pct)%")
    if let err { print("MCL limit:  error — \(err.localizedDescription)") }
    else        { print("MCL limit:  \(mcl)%") }

    var err2: NSError? = nil
    let mclEnabled = client.isMCLCurrentlyEnabled(&err2)
    if let err2 { print("MCL active: error — \(err2.localizedDescription)") }
    else        { print("MCL active: \(mclEnabled != 0)") }

    var engaged: ObjCBool = false
    var maxLimited: ObjCBool = false
    var overrideAllowed: ObjCBool = false
    var err3: NSError? = nil
    let ok = client.isOBCEngaged(&engaged,
                                  isMaxChargeLimited: &maxLimited,
                                  chargingOverrideAllowed: &overrideAllowed,
                                  withError: &err3)
    if ok {
        print("OBC engaged:        \(engaged.boolValue)")
        print("max charge limited: \(maxLimited.boolValue)")
        print("override allowed:   \(overrideAllowed.boolValue)")
    } else if let err3 {
        print("isOBCEngaged:       error — \(err3.localizedDescription)")
    }

case "introspect":
    var count: UInt32 = 0
    print("=== +[PowerUISmartChargeClient *] ===")
    if let m = class_copyMethodList(object_getClass(raw), &count) {
        for i in 0..<Int(count) { print("  +\(NSStringFromSelector(method_getName(m[i])))") }
        free(m)
    }
    print("\n=== -[PowerUISmartChargeClient *] ===")
    if let m = class_copyMethodList(raw, &count) {
        for i in 0..<Int(count) {
            let name = NSStringFromSelector(method_getName(m[i]))
            let enc  = String(cString: method_getTypeEncoding(m[i])!)
            print("  -\(name)  [\(enc)]")
        }
        free(m)
    }

default:
    print("""
    charge-control — PowerUISmartChargeClient wrapper (macOS 26.4+)

    Commands:
      on                  disable MCL (battery charges to 100%)
      off                 enable MCL at current battery % (stops charging here)
      limit <1-100>       set manual charge limit %
      maintain <1-100>    alias for limit
      status              show battery %, MCL state, OBC state
      introspect          dump all methods with type encodings
    """)
}
