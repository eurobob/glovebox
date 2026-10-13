import Foundation

@main
enum HandLocomotionTests {
    static func check(_ value: Bool, _ message: String = "") { precondition(value, message) }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("gameinit.lua")
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let body = "baseline_runs = (baseline_runs or 0) + 1\n"
        try body.write(to: source, atomically: true, encoding: .utf8)
        let original = "game/gameinit=\(source.path)"

        check(try KleptonHandInput.prepareLocomotionInjection(original, cacheDirectory: cache, hands: false) == original)
        check(!FileManager.default.fileExists(atPath: cache.path), "Sense must not write an override")
        for unchanged in [nil, "other/chunk=\(source.path)", "game/gameinit=relative.lua"] as [String?] {
            check(try KleptonHandInput.prepareLocomotionInjection(unchanged, cacheDirectory: cache, hands: true) == unchanged)
        }
        let prepared = try KleptonHandInput.prepareLocomotionInjection(original, cacheDirectory: cache, hands: true)!
        check(prepared.hasPrefix("game/gameinit="))
        let generated = cache.appendingPathComponent("alyx-hands-gameinit.lua")
        let contents = try String(contentsOf: generated, encoding: .utf8)
        check(contents.hasPrefix(body), "The existing gameinit must be preserved")
        check(try String(contentsOf: source, encoding: .utf8) == body, "The configured source is immutable")
        check(contents.contains("vr_movetype_set 2"))
        check(!contents.contains("Convars:Set"), "Movement preference must not be overwritten")
        print("Hand locomotion preparation: 10 checks passed")
    }
}
