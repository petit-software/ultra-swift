import AppKit
import SwiftUI

/// What is running in a terminal pane, as a glyph: Claude's mark for Claude Code, OpenAI's
/// Codex mark for Codex, a terminal for a plain shell, and a sparkle for an agent this
/// has no mark for.
///
/// The two marks are drawn from their vector outlines, as template images, so they take
/// the foreground colour like the symbols beside them and stay sharp at any size.
public struct AgentGlyph: View {
    /// The agent's binary as the tty names it — `claude`, `codex` — or nil for a shell.
    public let agent: String?
    public var size: CGFloat

    public init(agent: String?, size: CGFloat = 14) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        if let mark = Mark(agent: agent), let image = Self.image(mark) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: agent == nil ? "apple.terminal.fill" : "sparkles")
                .font(.system(size: size - 1, weight: .medium))
                .frame(width: size, height: size)
        }
    }

    enum Mark: String, CaseIterable {
        case claude, codex

        init?(agent: String?) {
            guard let name = agent.map({ ($0 as NSString).lastPathComponent.lowercased() }) else { return nil }
            if name.hasPrefix("claude") { self = .claude }
            else if name.hasPrefix("codex") || name.hasPrefix("gpt") { self = .codex }
            else { return nil }
        }

        var path: String {
            switch self {
            case .claude: Self.claudePath
            case .codex: Self.codexPath
            }
        }

        var fillRule: String { self == .codex ? "evenodd" : "nonzero" }

        static let codexPath = "M9.3708801 2.18576C 11.1759 1.70239 13.0087 2.1905899 14.3229 3.3222699C 16.0284 2.9979801 17.8626 3.4927599 19.1849 4.81496C 20.506599 6.1368399 21 7.96945 20.6766 9.6740904C 21.809601 10.9886 22.297701 12.823 21.8141 14.629C 21.330099 16.435499 19.9888 17.778799 18.35 18.350599C 17.778299 19.988899 16.436199 21.3295 14.6302 21.813801C 12.8243 22.2976 10.9899 21.809099 9.6753502 20.6763C 7.97048 21.0002 6.1374102 20.506701 4.8152599 19.184601C 3.49332 17.8624 2.9975801 16.0289 3.32161 14.3235C 2.18976 13.0088 1.70243 11.1746 2.18606 9.3696203C 2.67009 7.5641398 4.0098701 6.2191601 5.6482501 5.6469998C 6.2205801 4.0089998 7.5654802 2.6696301 9.3708801 2.18576ZM9.4091797 9.0440798C 9.1304502 8.5801601 8.5280895 8.4295197 8.06394 8.7080097C 7.6000299 8.9866304 7.4496498 9.5890999 7.72787 10.0533L 8.8950195 11.9998L 7.72787 13.9463C 7.44943 14.4104 7.60008 15.0128 8.06394 15.2915C 8.5281897 15.5701 9.1305304 15.4196 9.4091797 14.9555L 10.8798 12.5044C 11.0661 12.1939 11.0661 11.8057 10.8798 11.4952L 9.4091797 9.0440798ZM12.9805 13.4704C 12.4393 13.4707 12.0002 13.9097 12.0001 14.4509C 12.0001 14.9922 12.4392 15.4311 12.9805 15.4313L 15.9219 15.4313C 16.463301 15.4313 16.9023 14.9924 16.9023 14.4509C 16.902201 13.9095 16.463301 13.4704 15.9219 13.4704L 12.9805 13.4704Z"

        static let claudePath = "M5.9240499 15.2962L 9.8582296 13.0903L 9.9240503 12.8981L 9.8582296 12.7918L 9.6658201 12.7918L 9.0075998 12.7513L 6.75949 12.6906L 4.8101301 12.6097L 2.92152 12.5085L 2.44557 12.4073L 2 11.8204L 2.0455699 11.5269L 2.44557 11.2588L 3.01772 11.3094L 4.2835398 11.3954L 6.1822801 11.5269L 7.5594902 11.6079L 9.6000004 11.8204L 9.9240503 11.8204L 9.9696198 11.6888L 9.8582296 11.6079L 9.77215 11.5269L 7.8076 10.1963L 5.6810098 8.7897797L 4.56709 7.9802699L 3.96456 7.5704498L 3.6607599 7.1859398L 3.52911 6.3460698L 4.0759501 5.7439899L 4.8101301 5.79459L 4.9974699 5.84518L 5.7417698 6.4169002L 7.3316498 7.6463499L 9.4076004 9.1743002L 9.7113895 9.4272699L 9.8329096 9.34126L 9.8480997 9.28055L 9.7113895 9.0528698L 8.5822802 7.0139098L 7.3772202 4.9395399L 6.8405099 4.0794301L 6.69873 3.56337C 6.6480999 3.3508699 6.6126599 3.17379 6.6126599 2.9562399L 7.2354398 2.11131L 7.5797501 2L 8.4101295 2.11131L 8.75949 2.41487L 9.2759504 3.59373L 10.1114 5.4505401L 11.4076 7.9752102L 11.7873 8.7240105L 11.9899 9.4171495L 12.0658 9.6296501L 12.1975 9.6296501L 12.1975 9.5082197L 12.3038 8.0865202L 12.5013 6.3410101L 12.6937 4.0946102L 12.7595 3.4621799L 13.0734 2.7032599L 13.6962 2.2934501L 14.1823 2.52618L 14.5823 3.0978999L 14.5266 3.4672401L 14.2886 5.0103698L 13.8228 7.4287901L 13.519 9.0478096L 13.6962 9.0478096L 13.8987 8.8454304L 14.719 7.7576499L 16.096201 6.0374398L 16.7038 5.3544102L 17.412701 4.6005602L 17.868401 4.2413402L 18.729099 4.2413402L 19.362 5.1823902L 19.078501 6.15381L 18.1924 7.27701L 17.4582 8.2281799L 16.4051 9.6448298L 15.7468 10.7781L 15.8076 10.8692L 15.9646 10.854L 18.344299 10.3481L 19.6304 10.1154L 21.1646 9.8522596L 21.8582 10.1761L 21.9342 10.5049L 21.660801 11.1778L 20.0203 11.5826L 18.096201 11.9671L 15.2304 12.6451L 15.1949 12.6704L 15.2354 12.721L 16.5266 12.8424L 17.078501 12.8728L 18.430401 12.8728L 20.9468 13.06L 21.605101 13.4951L 22 14.0263L 21.9342 14.4311L 20.921499 14.9471L 19.554399 14.6233L 16.364599 13.8644L 15.2709 13.5912L 15.119 13.5912L 15.119 13.6823L 16.030399 14.5727L 17.7013 16.0804L 19.7924 18.0233L 19.898701 18.503901L 19.6304 18.8834L 19.3468 18.842899L 17.5089 17.4617L 16.799999 16.839399L 15.1949 15.4885L 15.0886 15.4885L 15.0886 15.6302L 15.4582 16.171499L 17.412701 19.106001L 17.513901 20.006599L 17.3722 20.299999L 16.865801 20.4771L 16.308901 20.3759L 15.1646 18.7721L 13.9848 16.965799L 13.0329 15.3468L 12.9165 15.4126L 12.3544 21.458599L 12.0911 21.7673L 11.4835 22L 10.9772 21.615499L 10.7089 20.9932L 10.9772 19.7637L 11.3013 18.159901L 11.5646 16.884899L 11.8025 15.3013L 11.9443 14.7751L 11.9342 14.7397L 11.8177 14.7549L 10.6228 16.3941L 8.8050604 18.848L 7.3670902 20.386L 7.02279 20.5226L 6.4253201 20.214001L 6.48101 19.6625L 6.8151898 19.171801L 8.8050604 16.642L 10.0051 15.0736L 10.7797 14.168L 10.7747 14.0364L 10.7291 14.0364L 5.4430399 17.4667L 4.5012698 17.5882L 4.0962 17.2087L 4.1468401 16.586399L 4.3392401 16.384001L 5.9291101 15.2912L 5.9240499 15.2962Z"
    }

    /// Built once per mark: `body` runs for every row on every redraw.
    @MainActor private static var images: [Mark: NSImage] = [:]

    @MainActor
    static func image(_ mark: Mark) -> NSImage? {
        if let hit = images[mark] { return hit }
        let svg = """
        <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">\
        <path fill="black" fill-rule="\(mark.fillRule)" d="\(mark.path)"/></svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        images[mark] = image
        return image
    }
}

#Preview("Agent glyphs", traits: .fixedLayout(width: 220, height: 60)) {
    HStack(spacing: 16) {
        AgentGlyph(agent: "claude", size: 24)
        AgentGlyph(agent: "codex", size: 24)
        AgentGlyph(agent: "gemini", size: 24)
        AgentGlyph(agent: nil, size: 24)
    }
    .foregroundStyle(.primary)
    .padding()
}
