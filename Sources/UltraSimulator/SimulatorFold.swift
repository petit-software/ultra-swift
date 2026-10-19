import Foundation

/// Opening and closing a phone that folds.
///
/// Nothing on the Mac side can do it. `simctl` and `devicectl` have no hinge, and the
/// hinge is not a HID event the host sends: the device's own SpringBoard owns it, behind
/// its display tool service (`SBSDisplayToolService`), which sweeps the hinge to a position
/// and swaps the screens exactly as a hand would. So the swap is asked for from INSIDE the
/// device, by a tiny program run there with `simctl spawn`.
///
/// The program is built here, on first use, by the same Xcode that runs the simulator —
/// `xcrun -sdk iphonesimulator clang` — and kept in Caches. Building it beside the user
/// rather than shipping it means it always matches their Xcode's simulator SDK, and an app
/// that can show a simulator has that Xcode by definition.
///
/// SpringBoard answers only a client entitled to `com.apple.springboard.sbdisplay.service`.
/// A simulator process takes its entitlements from a `__TEXT,__entitlements` section, the
/// way Xcode builds a simulator app — a code signature carrying them is refused at launch —
/// so the section is where they go. The device is a simulator on this Mac; nothing here
/// reaches a real phone.
public enum SimulatorFold {

    public enum Position: String, Sendable {
        case open, closed
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    /// Sweep the hinge to `position`, returning once the screens have swapped.
    public static func move(_ udid: String, to position: Position) async throws {
        let tool = try await helper()
        let result = await SimulatorControl.run(["simctl", "spawn", udid, tool.path,
                                                 "-position=\(position.rawValue)", "-wait"], timeout: 30)
        guard result.status == 0 else {
            let said = (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: said.isEmpty ? "The device did not fold" : "The device did not fold: \(said)")
        }
    }

    /// The program, built if this version of it is not in Caches yet.
    static func helper() async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ultra/SimulatorTools", isDirectory: true)
        let tool = folder.appendingPathComponent("ultra-fold-\(version)")
        if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("ultra-fold-\(version).m")
        let entitlements = folder.appendingPathComponent("ultra-fold-\(version).plist")
        try Self.source.write(to: source, atomically: true, encoding: .utf8)
        try Self.entitlements.write(to: entitlements, atomically: true, encoding: .utf8)
        let result = await SimulatorControl.run(buildArguments(source: source, entitlements: entitlements, output: tool),
                                                timeout: 120)
        guard result.status == 0, FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Failure(description: "Could not build the fold helper: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return tool
    }

    /// `xcrun` arguments that compile the helper for this Mac's simulator architecture.
    static func buildArguments(source: URL, entitlements: URL, output: URL) -> [String] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return ["-sdk", "iphonesimulator", "clang",
                "-target", "\(arch)-apple-ios17.0-simulator",
                "-fobjc-arc", "-framework", "Foundation", "-O2",
                source.path, "-o", output.path,
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
                "-Xlinker", entitlements.path]
    }

    /// Bumped whenever `source` changes, so a stale build in Caches is not run.
    static let version = 1

    static let entitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.springboard.sbdisplay.service</key>
            <true/>
        </dict>
        </plist>
        """

    /// The helper: SpringBoard's own argument parser turns `-position=open` into the swap
    /// settings, so this file never spells out their layout; the settings travel by value
    /// to the service, whose completion takes nothing.
    static let source = #"""
        #import <Foundation/Foundation.h>
        #import <objc/message.h>
        #include <dlfcn.h>

        typedef struct { long long a; double b; long long c, d; BOOL e; long long f; double g, h; } Swap;

        int main(int argc, char **argv) { @autoreleasepool {
            dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation", RTLD_NOW);
            BOOL (*parse)(NSArray *, Swap *, NSError **) = dlsym(RTLD_DEFAULT, "SBFDisplayToolSwapSettingsFromArguments");
            Class serviceClass = NSClassFromString(@"SBSDisplayToolService");
            SEL swap = NSSelectorFromString(@"swapDisplayWithSettings:completion:");
            if (!parse || !serviceClass || ![serviceClass instancesRespondToSelector:swap]) {
                fprintf(stderr, "this runtime has no display tool service\n");
                return 2;
            }
            NSMutableArray *arguments = [NSMutableArray array];
            for (int i = 1; i < argc; i++) [arguments addObject:@(argv[i])];
            Swap settings = {0};
            NSError *error = nil;
            if (!parse(arguments, &settings, &error)) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String ?: "bad arguments");
                return 3;
            }
            __attribute__((objc_precise_lifetime)) id service = [[serviceClass alloc] init];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            ((void (*)(id, SEL, Swap, id))objc_msgSend)(service, swap, settings, ^{ dispatch_semaphore_signal(done); });
            long late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
            ((void (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"invalidate"));
            if (late) { fprintf(stderr, "the device did not answer\n"); return 4; }
            return 0;
        }}
        """#
}
