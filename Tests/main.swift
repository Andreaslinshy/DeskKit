import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DeskKitError.message("FAIL: " + message) }
    print("PASS: " + message)
}
func texts(_ node: LayoutNode?) -> [String] {
    guard let node else { return [] }
    return [node.text].compactMap { $0 } + (node.children ?? []).flatMap { texts($0) }
}
func runChecks() async throws {
    try expect(SystemSampler.speed(current: 4000, previous: 1000, elapsed: 1.5) == 2000, "network uses actual elapsed time")
    try expect(SystemSampler.speed(current: 100, previous: 3000, elapsed: 1) == nil, "counter reset is not a negative speed")
    try expect(SystemSampler.counterDelta(10, 0xfffffff0) == 26, "32-bit network rollover")
    try expect(SystemSampler.speed(current: 4000, previous: 1000, elapsed: 60) == nil, "wake gap discards stale baseline")
    try expect(SystemSampler.speed(current: 4000, previous: 1000, elapsed: 0) == nil, "zero interval is rejected")
    let unknown = DataProviders.normalizeWindow(["usedPercent": NSNull(), "windowDurationMins": 300])
    try expect(unknown?["remainingPercent"] is NSNull, "missing quota stays unknown")
    try expect(DataProviders.normalizeWindow(["usedPercent": true])?["remainingPercent"] is NSNull, "boolean quota is rejected")
    try expect(DataProviders.normalizeWindow(["usedPercent": 31])?["remainingPercent"] as? Double == 69, "quota means remaining percent")
    var invalid = LayoutNode(type: "webview")
    var count = 0
    do { try invalid.validate(count: &count); throw DeskKitError.message("unsupported node accepted") } catch { try expect(count == 1, "unsupported widget nodes are rejected") }
    invalid = LayoutNode(type:"column", children: Array(repeating: .message("x"), count: 257))
    count = 0
    do { try invalid.validate(count: &count); throw DeskKitError.message("large node tree accepted") } catch { try expect(count > 256, "oversized layout rejected") }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DeskKitChecks-"+UUID().uuidString)
    let store = try SharedStore(directory: temp)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = ComponentSnapshot(id:"test",name:"Test",symbol:"sparkles",fetchedAt:date,attemptedAt:Date(),staleAfter:180,error:"offline",presentation:PluginPresentation(widget:.message("last known")))
    try store.save(snapshot)
    try expect(store.read("test")?.fetchedAt == date && store.read("test")?.isStale == true, "cached snapshot retains fetch time and stale state")
    try expect(store.read("../test") == nil, "snapshot path traversal rejected")
    let output = try await CommandJob.run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["{\"hello\":\"world\"}"])
    try expect(output.status == 0 && String(data:output.data,encoding:.utf8)?.contains("world") == true, "command output is fully drained")
    let failure = try await CommandJob.run(executable:URL(fileURLWithPath:"/usr/bin/false"),arguments:[])
    try expect(failure.status != 0, "command failure returns status")
    let start = Date()
    do { _ = try await CommandJob.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["10"],timeout:0.25); throw DeskKitError.message("timeout not enforced") }
    catch { try expect(Date().timeIntervalSince(start) < 2, "command timeout does not block the service queue") }
    let engine = ScriptEngine()
    let root = URL(fileURLWithPath:CommandLine.arguments.last!)
    let codex = try String(contentsOf:root.appendingPathComponent("Plugins/codex-quota.deskkit/render.js"))
    let data: [String:Any] = ["primary": ["remainingPercent":NSNull(),"windowDurationMins":300,"resetsAt":1_789_555_000], "secondary": NSNull()]
    let unknownCard = try await engine.render(script:codex,data:data)
    try expect(texts(unknownCard.widget).contains("—") && !texts(unknownCard.widget).contains("100%"), "quota layout does not invent 100 percent")
    for i in 0..<20 {
        let result = try await engine.render(script:"function render(d){return {menuBar:String(d.i),widget:{type:'text',text:String(d.i)}}}",data:["i":i])
        try expect(result.menuBar == String(i), "persistent worker response \(i)")
    }
    let scriptStart = Date()
    do { _ = try await engine.render(script:"function render(){while(true){}}",data:[:]); throw DeskKitError.message("infinite script accepted") }
    catch { try expect(Date().timeIntervalSince(scriptStart) < 5, "infinite script is stopped") }
    let recovered = try await engine.render(script:"function render(){return {menuBar:'recovered'}}",data:[:])
    try expect(recovered.menuBar == "recovered", "script worker recovers after timeout")
    do { _ = try await engine.render(script:"function render(){ throw new Error('fixture'); }",data:[:]); throw DeskKitError.message("script exception ignored") }
    catch { try expect(error.localizedDescription.contains("fixture"), "script exception is surfaced") }
    let system = try String(contentsOf:root.appendingPathComponent("Plugins/system-monitor.deskkit/render.js"))
    let fixture: [String:Any] = ["interface":"en0","download":2048,"upload":512,"cpu":12,"memoryUsed":8_589_934_592,"memoryTotal":17_179_869_184,"diskTotal":500_000_000_000,"diskAvailable":100_000_000_000,"history":[10,20,30]]
    let systemCard = try await engine.render(script:system,data:fixture)
    try expect(systemCard.menuBarLines == ["↓ 2 KB/s","↑ 512 B/s"], "system plugin formats both network directions")
    try expect(texts(systemCard.panel).contains("8.0 / 16.0 GiB"), "memory shows consistent byte units")
    let gold = try String(contentsOf:root.appendingPathComponent("Plugins/gold-price.deskkit/render.js"))
    let goldFixture = "hq_str_gds_AUTD=\"800,0,0,0,810,790,10:00,795,798,0,0,0,2026-09-16\""
    let goldCard = try await engine.render(script:gold,data:["text":goldFixture])
    try expect(texts(goldCard.widget).contains("800.00"), "gold source parsing and rendering")
    engine.shutdown()
    print("ALL CHECKS PASSED")
}
if CommandLine.arguments.contains("--script-worker") { ScriptWorker.main() }
else {
    Task {
        do { try await runChecks(); exit(0) }
        catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
    }
    dispatchMain()
}
