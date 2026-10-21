import Testing
@testable import UltraCore

@Suite("Application Support folder")
struct AppSupportTests {
    @Test("the dev build keeps its workspaces apart from the Ultra in use")
    func folderByBundleID() {
        #expect(AppSupport.folderName(forBundleID: "software.petit.ultra") == "Ultra")
        #expect(AppSupport.folderName(forBundleID: "software.petit.ultra.dev") == "Ultra Dev")
        #expect(AppSupport.folderName(forBundleID: nil) == "Ultra", "a bare executable is not the dev build")
    }
}
