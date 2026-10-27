import AppKit
import Foundation
import UltraChat
import UltraCore
import UltraLayout
import UltraTerminal
import UltraTiles

/// Ultra Dev only: eight projects to look at the app full.
///
/// Real folders, not stand-ins. A demo that fakes its tiles has to be rewritten every time
/// a tile changes, and shows nothing about how the real one behaves on real data. These
/// are made on disk under Application Support ▸ Ultra Dev ▸ Demo Projects — files worth
/// opening, a git history with a change left uncommitted, a todo list with sections, a
/// context list, for some a chat — and each is opened as a session on a pane arrangement
/// of its own, so the file tree lists, the editor shows, the Git pane diffs, the browser
/// loads a page from a server one of the shells started, and Ports finds that server.
///
/// Made once, and again when `version` changes: a project the user has rearranged keeps
/// its arrangement between demo runs, which is how the demo is also a test of restoring.
/// Never in a release build (`AgentsOverview.isDevBuild`).
@MainActor
enum DemoProjects {

    /// Bumped when the projects or their arrangements change, so an old set is rebuilt.
    static let version = 4

    static var root: URL {
        AppSupport.directory.appendingPathComponent("Demo Projects", isDirectory: true)
    }

    /// `open "Ultra Dev.app" --args --demo`, or `ULTRA_DEMO=1`.
    static var isRequestedAtLaunch: Bool {
        AgentsOverview.isDevBuild
            && (CommandLine.arguments.contains("--demo")
                || ProcessInfo.processInfo.environment["ULTRA_DEMO"] == "1")
    }

    /// Make the projects if they are not there, open each as a session, and show the first.
    static func show(in list: SessionList) {
        guard AgentsOverview.isDevBuild else { return }
        installBin()
        let storage = WorkspaceStorage()
        var opened: [UUID] = []
        for spec in specs {
            let folder = root.appendingPathComponent(spec.name, isDirectory: true)
            let fresh = build(spec, at: folder)
            if fresh { arrange(spec, at: folder, storage: storage) }
            SessionAppearanceStore.set(SessionAppearance(symbol: spec.symbol, tint: spec.tint),
                                       forDirectory: folder.path)
            opened.append(list.open(directory: folder.path).workspaceID)
        }
        // A pass through every session before settling on the first. A shell starts on
        // its pane's first layout, and a session that is opened and left in the same
        // turn is never laid out: the eighth project sat with eight dead panes until it
        // was clicked. A beat on each is enough, and reads as the demo arriving.
        Task {
            for id in opened {
                list.select(id)
                try? await Task.sleep(for: .milliseconds(150))
            }
            if let first = opened.first { list.select(first) }
        }
    }

    // MARK: - The stand-ins

    /// Scripts the demo shells run, beside the projects: a stand-in agent, a test runner
    /// in watch mode, a build that rebuilds, a request log, a deploy. Each prints the way
    /// the real thing prints and keeps printing, so a pane is doing something when it
    /// is looked at rather than showing a prompt.
    ///
    /// Under Caches rather than beside the projects: the agent's command line is split on
    /// spaces wherever a binary name is wanted, and "Application Support" has one.
    static var bin: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "software.petit.ultra.dev", isDirectory: true)
            .appendingPathComponent("demo-bin", isDirectory: true)
    }

    /// A tool in `bin`, quoted for a shell, with its arguments.
    static func tool(_ name: String, _ arguments: String = "") -> String {
        shellQuoted(bin.appendingPathComponent(name).path) + (arguments.isEmpty ? "" : " " + arguments)
    }

    /// The stand-in agent's command line, as an agent pane's `command`: `claude` here is
    /// a small program of that name — see `launcherSource` — so the tty reports an
    /// executable called `claude` and the pane counts as the agent everywhere: the
    /// sidebar, the overview, the notification. It runs the transcript script in zsh and
    /// stays the process the tty sees. `scenario` is `working`, `asking` or `done`: the
    /// state the pane settles in. With no compiler on the machine the script runs in zsh
    /// directly; the pane is still an agent, having been launched as one.
    static func agentCommand(_ scenario: String) -> String {
        let script = bin.appendingPathComponent("agent.zsh").path
        let launcher = bin.appendingPathComponent("claude").path
        return FileManager.default.isExecutableFile(atPath: launcher)
            ? "\(launcher) \(script) \(scenario)"
            : "/bin/zsh \(script) \(scenario)"
    }

    /// Why `claude` is compiled rather than copied: a copy of `/bin/zsh` under another
    /// name is killed on launch — a system binary may only run from where it was
    /// installed — and a symlink reports the path it points at.
    static let launcherSource = #"""
    #include <spawn.h>
    #include <stdio.h>
    #include <sys/wait.h>
    #include <unistd.h>
    extern char **environ;
    int main(int argc, char **argv) {
        if (argc < 2) { fprintf(stderr, "usage: claude <script> [args]\n"); return 2; }
        char *args[argc + 1];
        args[0] = "/bin/zsh";
        for (int i = 1; i < argc; i++) args[i] = argv[i];
        args[argc] = NULL;
        pid_t pid;
        if (posix_spawn(&pid, "/bin/zsh", NULL, NULL, args, environ) != 0) { perror("claude"); return 1; }
        int status;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    """#

    /// Write the scripts, every time — they are small, and a changed script should not
    /// wait for the version to be bumped — and compile the launcher once.
    static func installBin() {
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("claude")
        let source = bin.appendingPathComponent("claude.c")
        if (try? String(contentsOf: source, encoding: .utf8)) != launcherSource
            || !FileManager.default.isExecutableFile(atPath: launcher.path) {
            try? launcherSource.write(to: source, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: launcher)
            let clang = Process()
            clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            clang.arguments = ["clang", "-O2", "-o", launcher.path, source.path]
            clang.standardOutput = FileHandle.nullDevice
            clang.standardError = FileHandle.nullDevice
            try? clang.run()
            clang.waitUntilExit()
        }
        for (name, text) in scripts {
            let url = bin.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static let scripts: [(String, String)] = [
        ("agent.zsh", #"""
        #!/bin/zsh
        # A stand-in for an agent's TUI: a transcript, printed at an agent's pace.
        scenario=${1:-working}
        B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; M=$'\e[35m'; R=$'\e[0m'
        say() { print -r -- "$@"; }
        step() { say ""; say "${C}⏺${R} $1"; sleep ${2:-1.2}; [[ -n "$3" ]] && say "  ${D}⎿  $3${R}"; sleep 0.6; }
        think() {
          local secs=${1:-6} i=0 frames=('✶' '✻' '✽' '✶' '✻' '✽')
          while (( i < secs * 4 )); do
            printf "\r${M}%s${R} ${D}Thinking… (%ds · ↓ %dk tokens)${R}   " "${frames[$((i % 6 + 1))]}" $((i / 4)) $((i / 3 + 2))
            sleep 0.25; (( i++ ))
          done
          printf "\r%-60s\r" ""
        }
        say "${B}╭──────────────────────────────────────────────╮${R}"
        say "${B}│${R} ${C}✻${R} Welcome to ${B}Claude Code${R}                        ${B}│${R}"
        say "${B}│${R}   ${D}$(basename "$PWD") · $(git -C "$PWD" branch --show-current 2>/dev/null || echo main)${R}"
        say "${B}╰──────────────────────────────────────────────╯${R}"
        say ""
        say "${D}>${R} Fix the failing test in the orders route and tell me what was wrong."
        sleep 1
        think 3
        step "Read(src/routes/orders.js)" 1.0 "Read 14 lines"
        step "Read(src/routes/orders.test.js)" 0.8 "Read 7 lines"
        think 4
        step "Bash(node --test 2>&1 | tail -n 12)" 2.0 "1 failing: an unknown order is a 404"
        think 3
        say ""
        say "The route returns 200 with an empty row for an id that does not exist; the test"
        say "expects 404. The query is fine, the guard after it is missing."
        case $scenario in
          asking)
            step "Edit(src/routes/orders.js)" 0.8
            say ""
            say "  ${D}12${R}   const { rows } = await pool.query(...)"
            say "  ${G}13 + if (rows.length === 0) return res.status(404).json({ error: "not found" });${R}"
            say "  ${D}14${R}   res.json(rows[0]);"
            say ""
            say "${B}Do you want to make this edit to orders.js?${R}"
            say "${C}❯${R} 1. Yes"
            say "  2. Yes, and don't ask again this session"
            say "  3. No, and tell Claude what to do differently (esc)"
            printf '\a'
            read -r answer
            say ""
            step "Bash(node --test)" 2.5 "2 passing"
            say ""
            say "${G}✔${R} Fixed: an unknown id is a 404 now."
            ;;
          done)
            step "Edit(src/routes/orders.js)" 1.0 "Added 1 line"
            step "Bash(node --test)" 2.5 "2 passing"
            say ""
            say "${G}✔${R} Done. The 404 guard was missing after the query; added it and the test passes."
            say ""
            say "${D}────────────────────────────────────────────────${R}"
            say "${D}>${R} "
            read -r answer
            ;;
          *)
            i=0
            files=(src/pricing.js src/db.js src/routes/cart.js src/server.js tests/cart.test.js README.md)
            while true; do
              f=${files[$((i % 6 + 1))]}
              think $((3 + i % 4))
              step "Read($f)" 1.0 "Read $((20 + i * 7 % 50)) lines"
              (( i % 3 == 2 )) && step "Edit($f)" 1.2 "Updated $((1 + i % 5)) lines"
              (( i % 4 == 3 )) && step "Bash(node --test)" 2.0 "$((2 + i % 3)) passing"
              (( i++ ))
            done
            ;;
        esac
        read -r answer
        """#),
        ("tests.zsh", #"""
        #!/bin/zsh
        # A test runner in watch mode: suites, dots, one that fails now and then.
        kind=${1:-swift}
        G=$'\e[32m'; Rd=$'\e[31m'; D=$'\e[2m'; B=$'\e[1m'; R=$'\e[0m'
        case $kind in
          swift) suites=(LayoutTests TreeOperationTests ForecastTests CacheTests ClientTests); cmd="swift test";;
          go)    suites=(TestRunDry TestSkipsComments TestAWSStore TestOnlyKeys); cmd="go test ./...";;
          *)     suites=(cart orders pricing health); cmd="node --test";;
        esac
        run=0
        while true; do
          print -r -- "${D}\$ $cmd${R}"
          print -r -- "${D}Building for debugging...${R}"; sleep 1.2
          total=0; failed=0
          for suite in $suites; do
            n=$(( 3 + RANDOM % 9 )); total=$(( total + n ))
            printf "  %-24s " "$suite"
            for (( i = 0; i < n; i++ )); do
              if (( run % 3 == 1 && RANDOM % 17 == 0 )); then printf "${Rd}F${R}"; failed=$(( failed + 1 )); else printf "${G}.${R}"; fi
              sleep 0.12
            done
            print ""
          done
          if (( failed == 0 )); then
            print -r -- "${G}${B}✔ $total tests in ${#suites} suites passed${R} ${D}($(( 2 + RANDOM % 6 )).$(( RANDOM % 9 ))s)${R}"
          else
            print -r -- "${Rd}${B}✘ $failed of $total tests failed${R}"
            print -r -- "  ${Rd}Expectation failed: status == 404${R} ${D}(orders.test.js:5)${R}"
          fi
          print -r -- "${D}watching for changes…${R}"; print ""
          sleep $(( 12 + RANDOM % 10 )); (( run++ ))
        done
        """#),
        ("build.zsh", #"""
        #!/bin/zsh
        # A build with a progress bar, then a watch that rebuilds.
        what=${1:-tokens}
        G=$'\e[32m'; D=$'\e[2m'; B=$'\e[1m'; C=$'\e[36m'; R=$'\e[0m'
        bar() {
          local n=$1 label=$2 i
          for (( i = 0; i <= n; i++ )); do
            local filled=$(( i * 30 / n ))
            printf "\r${C}%s${R} [%-30s] %3d%%  ${D}%s${R}" "⠿" "$(printf '#%.0s' $(seq 1 $filled))" $(( i * 100 / n )) "$label"
            sleep 0.$(( 5 + RANDOM % 9 ))
          done
          print ""
        }
        while true; do
          print -r -- "${D}\$ ${what} build${R}"
          case $what in
            tokens) bar 14 "tokens/colour.css → dist/tokens.css"; bar 9 "components → dist/index.js";;
            train)  for (( e = 1; e <= 8; e++ )); do printf "epoch %2d/8  loss %10.1f  ${D}%.1fs${R}\n" $e $(( 820000 / (e * e) + RANDOM % 900 )) $(( RANDOM % 4 )).$(( RANDOM % 9 )); sleep 0.9; done;;
            *)      bar 20 "compiling";;
          esac
          print -r -- "${G}${B}✔ Build complete${R} ${D}($(( 1 + RANDOM % 4 )).$(( RANDOM % 9 ))s)${R}"
          print -r -- "${D}watching ${what}/ for changes…${R}"; print ""
          sleep $(( 15 + RANDOM % 15 ))
          print -r -- "${D}changed: $( [[ $what == tokens ]] && echo tokens/colour.css || echo train.py )${R}"
        done
        """#),
        ("logs.zsh", #"""
        #!/bin/zsh
        # A request log, one line a beat, with the occasional slow one and error.
        kind=${1:-http}
        G=$'\e[32m'; Y=$'\e[33m'; Rd=$'\e[31m'; D=$'\e[2m'; R=$'\e[0m'
        paths=(/cart/9f2/items /orders/1042 /health /cart/a71/items /orders/1043 /orders/999 /health /cart/c03/items)
        methods=(POST GET GET POST GET GET GET POST)
        infra=("ec2    i-0a9f  cpu 41%" "rds    acme-db  connections 12" "eks    node-3  pods 17/20" "alb    5xx 0  4xx 3" "s3     tfstate  put ok" "eks    node-1  cpu 72%")
        i=0
        while true; do
          t=$(date +%H:%M:%S)
          if [[ $kind == infra ]]; then
            print -r -- "${D}$t${R}  ${infra[$((i % 6 + 1))]}"
          else
            idx=$((i % 8 + 1)); ms=$(( 4 + RANDOM % 60 )); code=200
            (( idx == 6 )) && code=404
            (( RANDOM % 23 == 0 )) && { code=500; ms=$(( 800 + RANDOM % 900 )); }
            (( RANDOM % 11 == 0 )) && ms=$(( 300 + RANDOM % 500 ))
            col=$G; (( code >= 400 )) && col=$Y; (( code >= 500 )) && col=$Rd
            slow=""; (( ms > 250 )) && slow=" ${Y}slow${R}"
            printf "${D}%s${R}  %-4s %-20s ${col}%s${R}  %4dms%s\n" "$t" "${methods[$idx]}" "${paths[$idx]}" "$code" "$ms" "$slow"
          fi
          sleep 0.$(( 4 + RANDOM % 9 )); (( RANDOM % 5 == 0 )) && sleep 1
          (( i++ ))
        done
        """#),
        ("deploy.zsh", #"""
        #!/bin/zsh
        # terraform plan, then apply, step by step — and then a prompt.
        G=$'\e[32m'; Y=$'\e[33m'; D=$'\e[2m'; B=$'\e[1m'; R=$'\e[0m'
        print -r -- "${D}\$ terraform plan -out=plan.tfplan${R}"; sleep 1
        print -r -- "module.network.aws_vpc.this: Refreshing state... [id=vpc-0a1b2c]"; sleep 0.6
        print -r -- "module.cluster.aws_eks_cluster.this: Refreshing state... [id=acme]"; sleep 0.8
        print ""
        print -r -- "Terraform will perform the following actions:"; print ""
        print -r -- "  ${G}+${R} module.database.aws_db_instance.this"
        print -r -- "      engine:            "postgres""
        print -r -- "      instance_class:    "db.t4g.medium""
        print -r -- "      allocated_storage: 50"
        print -r -- "  ${Y}~${R} module.cluster.aws_eks_cluster.this"
        print -r -- "      vpc_config.subnet_ids: [2 → 3 elements]"
        print ""
        print -r -- "${B}Plan: 1 to add, 1 to change, 0 to destroy.${R}"; sleep 2
        print ""
        print -r -- "${D}\$ terraform apply plan.tfplan${R}"; sleep 1
        for s in "Creating..." "Still creating... [10s elapsed]" "Still creating... [20s elapsed]" "Still creating... [30s elapsed]"; do
          print -r -- "module.database.aws_db_instance.this: $s"; sleep 2.5
        done
        print -r -- "module.database.aws_db_instance.this: ${G}Creation complete after 38s${R} [id=acme-db]"; sleep 1
        print -r -- "module.cluster.aws_eks_cluster.this: Modifying..."; sleep 2
        print -r -- "module.cluster.aws_eks_cluster.this: ${G}Modifications complete after 4s${R}"
        print ""
        print -r -- "${G}${B}Apply complete! Resources: 1 added, 1 changed, 0 destroyed.${R}"
        exec zsh -l
        """#),
    ]

    // MARK: - On disk

    /// The folder, with its marker. True when it was (re)made now, which is when its
    /// arrangement is written too; false when it was already there at this version.
    @discardableResult
    static func build(_ spec: Spec, at folder: URL) -> Bool {
        let marker = folder.appendingPathComponent(".ultra/demo.json")
        if let data = try? Data(contentsOf: marker),
           let made = try? JSONDecoder().decode(Marker.self, from: data), made.version == version {
            return false
        }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in spec.files {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        try? spec.todo.write(to: folder.appendingPathComponent(".ultra/todo.md"), atomically: true, encoding: .utf8)
        writeContext(spec.context.map { folder.appendingPathComponent($0) }, in: folder)
        if let chat = spec.chat { try? ChatArchive(root: folder).save(chat) }
        git(spec, in: folder)
        try? JSONEncoder().encode(Marker(version: version)).write(to: marker)
        return true
    }

    struct Marker: Codable { var version: Int }

    /// The Context pane's list, by path: a bookmark is made by the pane itself, and a
    /// record with none falls back to its path, which is here.
    static func writeContext(_ urls: [URL], in folder: URL) {
        struct Stored: Codable { var id: UUID; var path: String; var isPinned: Bool }
        let stored = urls.enumerated().map { Stored(id: UUID(), path: $1.path, isPinned: $0 == 0) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: folder.appendingPathComponent(".ultra/context.json"))
    }

    /// A history: one commit per step, each adding or changing files, then the changes of
    /// the last step left in the working tree — modified and untracked — so the Git pane
    /// has something to show and the diff viewer something to open.
    static func git(_ spec: Spec, in folder: URL) {
        func run(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "-c", "user.name=Demo", "-c", "user.email=demo@example.com",
                                 "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        run(["init", "--quiet"])
        try? ".DS_Store\n.ultra/demo.json\n".write(to: folder.appendingPathComponent(".gitignore"),
                                                     atomically: true, encoding: .utf8)
        run(["add", "-A"])
        run(["commit", "--quiet", "-m", "Initial commit"])
        for (index, step) in spec.history.enumerated() {
            for (path, text) in step.files {
                let url = folder.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            guard index < spec.history.count - 1 else { break }
            run(["add", "-A"])
            run(["commit", "--quiet", "-m", step.message])
        }
    }

    // MARK: - Arrangement

    /// The session's document, written where the next open restores it from, in place of
    /// any older one for the folder.
    static func arrange(_ spec: Spec, at folder: URL, storage: WorkspaceStorage) {
        var panes: [PaneID: PaneRecord] = [:]
        let tree = spec.layout(folder, &panes)
        // The line each shell types on start rides in its record, in the shells' order in
        // the tree — see `ShellPaneFactory.startupInput`. Typed on the first build only.
        let shells = tree.paneIDs.filter { panes[$0]?.kind == .shell }
        for (paneID, command) in zip(shells, spec.startup) where !command.isEmpty {
            panes[paneID]?.tileState = Data(command.utf8)
        }
        let document = WorkspaceDocument(directory: folder.path, title: spec.name, tree: tree, panes: panes)
        try? storage.saveNow(document)
        _ = storage.retireDuplicates(for: folder.path, keeping: document.id)
    }

    /// One project: what is on disk, and how its panes are arranged.
    struct Spec {
        var name: String
        var symbol: String
        var tint: String
        /// The files of the initial commit.
        var files: [(String, String)]
        /// Commits after the first; the LAST step is left uncommitted.
        var history: [(message: String, files: [(String, String)])]
        var todo: String
        /// Paths in the Context pane.
        var context: [String]
        var chat: ChatConversation?
        /// A line typed into each shell pane on start, in the shells' order in the tree;
        /// empty for a shell that starts at its prompt.
        var startup: [String]
        var layout: (URL, inout [PaneID: PaneRecord]) -> LayoutTree
    }

    // MARK: Pane helpers

    static func shell(_ root: URL, title: String? = nil, into panes: inout [PaneID: PaneRecord]) -> PaneID {
        let id = PaneID()
        var record = ShellPaneFactory.record(for: ShellSpec(cwd: root.path), agent: nil, cwd: root.path)
        if let title { record.title = title }
        panes[id] = record
        return id
    }

    static func tile(_ kind: PaneRecord.Kind, _ root: URL, file: String? = nil,
                     into panes: inout [PaneID: PaneRecord]) -> PaneID {
        let id = PaneID()
        panes[id] = TileFactory.record(for: kind, root: root, file: file.map { root.appendingPathComponent($0) })
        return id
    }

    /// An agent pane running the stand-in in `scenario`. Launched as an agent, so the
    /// header, the sidebar and the overview treat it as one.
    static func agent(_ root: URL, _ scenario: String, into panes: inout [PaneID: PaneRecord]) -> PaneID {
        let id = PaneID()
        let command = agentCommand(scenario)
        panes[id] = ShellPaneFactory.record(for: ShellSpec(cwd: root.path, agentCommand: command),
                                            agent: command, cwd: root.path)
        return id
    }

    static func browser(_ root: URL, url: String, title: String, into panes: inout [PaneID: PaneRecord]) -> PaneID {
        let id = PaneID()
        panes[id] = TileFactory.browserRecord(url: URL(string: url), title: title, root: root)
        return id
    }

    static func chatPane(_ root: URL, _ conversation: ChatConversation, into panes: inout [PaneID: PaneRecord]) -> PaneID {
        let id = PaneID()
        panes[id] = TileFactory.chatRecord(for: conversation, root: root)
        return id
    }

    static func conversation(_ title: String, _ turns: [(ChatRole, String)]) -> ChatConversation {
        let start = Date().addingTimeInterval(-3600)
        var messages: [ChatMessage] = []
        for (index, turn) in turns.enumerated() {
            messages.append(ChatMessage(role: turn.0, text: turn.1,
                                        createdAt: start.addingTimeInterval(Double(index) * 90)))
        }
        return ChatConversation(title: title, provider: .apple, model: "On-device", messages: messages,
                                createdAt: start, updatedAt: start.addingTimeInterval(Double(turns.count) * 90))
    }

    // MARK: - The eight

    static let designSystemChat = conversation("Dark accent", [
        (.user, "The accent reads muddy on the dark paper. What would you change?"),
        (.assistant, "Lift the accent in dark mode rather than changing the paper: `#8c80ff` keeps the hue and clears 4.5:1 on `#17161a`. Keep the wash at 12% — it reads as the same wash either way."),
        (.user, "And the hairline?"),
        (.assistant, "Leave it. 10% white on near-black is the same visual weight as 8% black on paper."),
    ])

    static let blogChat = conversation("Opening paragraph", [
        (.user, "Is the opening too slow? Read posts/2026-10-terminal-for-agents.md."),
        (.assistant, "It is one sentence of setup and one of claim, which is fast. The second sentence does the work: 'writes more than it reads, goes quiet when it needs you, and there are usually several of them' is the whole post in a line. I would leave it."),
        (.user, "Good. Give me a title that is less of a label."),
        (.assistant, "'Several occupants' — it is the surprising fact. Or 'The shell has company'."),
    ])

    static let specs: [Spec] = [
        checkoutAPI, designSystem, iosWeather, mlNotebook, infra, blog, dataPipeline, cliTool,
    ]

    /// A Node service: two shells, one running a server, a browser on it, and Ports.
    static let checkoutAPI = Spec(
        name: "checkout-api", symbol: "cart.fill", tint: "green",
        files: [
            ("package.json", """
            {
              "name": "checkout-api",
              "version": "1.4.2",
              "private": true,
              "scripts": { "dev": "node --watch src/server.js", "test": "node --test" },
              "dependencies": { "express": "^4.19.2", "pg": "^8.12.0", "stripe": "^16.2.0" }
            }

            """),
            ("src/server.js", """
            import express from "express";
            import { router as cart } from "./routes/cart.js";
            import { router as orders } from "./routes/orders.js";

            const app = express();
            app.use(express.json());
            app.use("/cart", cart);
            app.use("/orders", orders);

            app.get("/health", (_req, res) => res.json({ ok: true, uptime: process.uptime() }));

            const port = process.env.PORT ?? 3000;
            app.listen(port, () => console.log(`checkout-api listening on ${port}`));

            """),
            ("src/routes/cart.js", """
            import { Router } from "express";
            import { priceOf } from "../pricing.js";

            export const router = Router();

            const carts = new Map();

            router.post("/:id/items", (req, res) => {
              const cart = carts.get(req.params.id) ?? [];
              cart.push({ sku: req.body.sku, qty: req.body.qty ?? 1 });
              carts.set(req.params.id, cart);
              res.status(201).json({ items: cart, total: cart.reduce((sum, i) => sum + priceOf(i.sku) * i.qty, 0) });
            });

            """),
            ("src/routes/orders.js", """
            import { Router } from "express";

            export const router = Router();

            router.get("/:id", async (req, res) => {
              // TODO: read from Postgres once the migration lands
              res.json({ id: req.params.id, status: "pending" });
            });

            """),
            ("src/pricing.js", """
            const prices = { "sku-001": 1999, "sku-002": 4999, "sku-003": 899 };

            export function priceOf(sku) {
              if (!(sku in prices)) throw new Error(`unknown sku ${sku}`);
              return prices[sku];
            }

            """),
            ("README.md", "# checkout-api\n\nCart and order endpoints for the storefront. `npm run dev` starts it on :3000.\n"),
        ],
        history: [
            ("Add cart totals", [("src/pricing.js", """
            const prices = { "sku-001": 1999, "sku-002": 4999, "sku-003": 899, "sku-004": 12900 };

            export function priceOf(sku) {
              if (!(sku in prices)) throw new Error(`unknown sku ${sku}`);
              return prices[sku];
            }

            export function totalOf(items) {
              return items.reduce((sum, item) => sum + priceOf(item.sku) * item.qty, 0);
            }

            """)]),
            ("Health endpoint reports the database", [("src/server.js", """
            import express from "express";
            import { router as cart } from "./routes/cart.js";
            import { router as orders } from "./routes/orders.js";
            import { ping } from "./db.js";

            const app = express();
            app.use(express.json());
            app.use("/cart", cart);
            app.use("/orders", orders);

            app.get("/health", async (_req, res) => {
              res.json({ ok: true, uptime: process.uptime(), database: await ping() });
            });

            const port = process.env.PORT ?? 3000;
            app.listen(port, () => console.log(`checkout-api listening on ${port}`));

            """), ("src/db.js", """
            import pg from "pg";

            const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

            export async function ping() {
              try { await pool.query("select 1"); return "up"; } catch { return "down"; }
            }

            """)]),
            ("Orders read from Postgres", [("src/routes/orders.js", """
            import { Router } from "express";
            import { pool } from "../db.js";

            export const router = Router();

            router.get("/:id", async (req, res) => {
              const { rows } = await pool.query("select id, status, total_cents from orders where id = $1", [req.params.id]);
              if (rows.length === 0) return res.status(404).json({ error: "not found" });
              res.json(rows[0]);
            });

            """), ("src/routes/orders.test.js", """
            import test from "node:test";
            import assert from "node:assert/strict";

            test("an unknown order is a 404", async () => {
              assert.equal(404, 404);
            });

            """)]),
        ],
        todo: """
        ## Orders

        - [x] Cart totals in cents, never floats
        - [x] `/health` says whether Postgres answers
        - [ ] Orders read from Postgres (`src/routes/orders.js`)
          - [ ] Migration for `orders.total_cents`
          - [ ] 404 on an unknown id
        - [ ] Stripe webhook for `payment_intent.succeeded`

        ## Later

        - [ ] Rate limit `/cart` per session
        - [ ] Structured logs

        """,
        context: ["src/routes/orders.js", "src/db.js", "README.md"],
        chat: nil,
        startup: ["git log --oneline --graph --decorate", "python3 -m http.server 8731", tool("logs.zsh", "http")],
        layout: { root, panes in
            // The service at work: a shell, the server under it, the agent fixing the
            // route, its request log, and the port it is on.
            let work = shell(root, title: "shell", into: &panes)
            let server = shell(root, title: "server", into: &panes)
            let logs = shell(root, title: "logs", into: &panes)
            let agent = agent(root, "asking", into: &panes)
            let ports = tile(.ports, root, into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: work)
            tree.split(work, edge: .right, newPane: agent, ratio: 0.42)
            tree.split(agent, edge: .right, newPane: todo, ratio: 0.36)
            tree.split(work, edge: .bottom, newPane: server, ratio: 0.45)
            tree.split(agent, edge: .bottom, newPane: logs, ratio: 0.35)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.5)
            tree.split(context, edge: .bottom, newPane: ports, ratio: 0.5)
            tree.focused = agent
            return tree
        })

    /// Tokens and components: a tree, an editor on the tokens, the todo beside it.
    static let designSystem = Spec(
        name: "design-system", symbol: "paintbrush.fill", tint: "purple",
        files: [
            ("tokens/colour.css", """
            :root {
              --ink: #1b1b1f;
              --paper: #fbfaf7;
              --accent: #5b4bff;
              --accent-wash: rgb(91 75 255 / 0.12);
              --hairline: rgb(0 0 0 / 0.08);
            }

            @media (prefers-color-scheme: dark) {
              :root {
                --ink: #f2f1ee;
                --paper: #141416;
                --hairline: rgb(255 255 255 / 0.1);
              }
            }

            """),
            ("tokens/space.css", ":root {\n  --space-1: 4px;\n  --space-2: 8px;\n  --space-3: 12px;\n  --space-4: 16px;\n  --space-6: 24px;\n  --space-8: 32px;\n  --radius: 10px;\n}\n"),
            ("components/Button.tsx", """
            import { ButtonHTMLAttributes } from "react";
            import "./button.css";

            type Props = ButtonHTMLAttributes<HTMLButtonElement> & { kind?: "primary" | "quiet" };

            export function Button({ kind = "primary", ...rest }: Props) {
              return <button className={`btn btn-${kind}`} {...rest} />;
            }

            """),
            ("components/button.css", ".btn {\n  padding: var(--space-2) var(--space-4);\n  border-radius: 999px;\n  border: 0;\n}\n.btn-primary { background: var(--accent); color: white; }\n.btn-quiet { background: transparent; color: var(--accent); }\n"),
            ("README.md", """
            # Design system

            Tokens first, components second. Every colour, space and radius a component uses is
            a token in `tokens/`, so a theme is a file and a redesign is a diff.

            ## Principles

            - One accent. The wash is the accent at 12%.
            - Hairlines, not borders.
            - A control is a capsule; a container is a 10px rounded rectangle.

            """),
        ],
        history: [
            ("Add Field", [("components/Field.tsx", """
            import { InputHTMLAttributes } from "react";

            export function Field(props: InputHTMLAttributes<HTMLInputElement> & { label: string }) {
              const { label, ...rest } = props;
              return (
                <label className="field">
                  <span className="field-label">{label}</span>
                  <input {...rest} />
                </label>
              );
            }

            """)]),
            ("Dark paper is warmer", [("tokens/colour.css", """
            :root {
              --ink: #1b1b1f;
              --paper: #fbfaf7;
              --accent: #5b4bff;
              --accent-wash: rgb(91 75 255 / 0.12);
              --hairline: rgb(0 0 0 / 0.08);
            }

            @media (prefers-color-scheme: dark) {
              :root {
                --ink: #f2f1ee;
                --paper: #17161a;
                --accent: #8c80ff;
                --hairline: rgb(255 255 255 / 0.1);
              }
            }

            """), ("components/Toast.tsx", "export function Toast({ text }: { text: string }) {\n  return <div className=\"toast\">{text}</div>;\n}\n")]),
        ],
        todo: """
        ## Tokens

        - [x] Colour, space, radius as CSS variables
        - [ ] Dark accent lifts to pass contrast on dark paper (`tokens/colour.css`)
        - [ ] Type scale

        ## Components

        - [x] Button
        - [x] Field
        - [ ] Toast
        - [ ] Menu

        """,
        context: ["tokens/colour.css", "README.md"],
        chat: designSystemChat,
        startup: [tool("build.zsh", "tokens")],
        layout: { root, panes in
            // Tokens being edited with the build watching them, and the chat about the
            // dark accent beside the list of what is left.
            let files = tile(.fileTree, root, into: &panes)
            let editor = tile(.editor, root, file: "tokens/colour.css", into: &panes)
            let build = shell(root, title: "build", into: &panes)
            let chat = chatPane(root, designSystemChat, into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .left, newPane: files, ratio: 0.2)
            tree.split(editor, edge: .right, newPane: chat, ratio: 0.36)
            tree.split(editor, edge: .bottom, newPane: build, ratio: 0.3)
            tree.split(chat, edge: .bottom, newPane: todo, ratio: 0.5)
            tree.split(todo, edge: .right, newPane: context, ratio: 0.5)
            tree.focused = editor
            return tree
        })

    /// A Swift package: tree, editor, shell, Git.
    static let iosWeather = Spec(
        name: "ios-weather", symbol: "cloud.fill", tint: "blue",
        files: [
            ("Package.swift", """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Weather",
                platforms: [.iOS(.v18), .macOS(.v15)],
                products: [.library(name: "Weather", targets: ["Weather"])],
                targets: [
                    .target(name: "Weather"),
                    .testTarget(name: "WeatherTests", dependencies: ["Weather"]),
                ]
            )

            """),
            ("Sources/Weather/Forecast.swift", """
            import Foundation

            public struct Forecast: Codable, Sendable {
                public var place: String
                public var days: [Day]

                public struct Day: Codable, Sendable, Identifiable {
                    public var id: Date { date }
                    public var date: Date
                    public var high: Measurement<UnitTemperature>
                    public var low: Measurement<UnitTemperature>
                    public var condition: Condition
                }
            }

            public enum Condition: String, Codable, Sendable {
                case clear, cloudy, rain, snow, fog
            }

            """),
            ("Sources/Weather/ForecastClient.swift", """
            import Foundation

            public actor ForecastClient {
                private let session: URLSession
                private let base = URL(string: "https://api.example.com/v1")!

                public init(session: URLSession = .shared) { self.session = session }

                public func forecast(for place: String) async throws -> Forecast {
                    let url = base.appending(path: "forecast").appending(queryItems: [.init(name: "q", value: place)])
                    let (data, _) = try await session.data(from: url)
                    return try JSONDecoder().decode(Forecast.self, from: data)
                }
            }

            """),
            ("Tests/WeatherTests/ForecastTests.swift", """
            import Testing
            @testable import Weather

            @Test func aDayIsIdentifiedByItsDate() {
                let day = Forecast.Day(date: .now, high: .init(value: 21, unit: .celsius),
                                       low: .init(value: 12, unit: .celsius), condition: .clear)
                #expect(day.id == day.date)
            }

            """),
            ("README.md", "# Weather\n\nA forecast model and client, shared by the iOS app and the widget.\n"),
        ],
        history: [
            ("Decode the condition leniently", [("Sources/Weather/Forecast.swift", """
            import Foundation

            public struct Forecast: Codable, Sendable {
                public var place: String
                public var days: [Day]

                public struct Day: Codable, Sendable, Identifiable {
                    public var id: Date { date }
                    public var date: Date
                    public var high: Measurement<UnitTemperature>
                    public var low: Measurement<UnitTemperature>
                    public var condition: Condition
                }
            }

            /// Unknown conditions decode as `.cloudy` rather than failing the whole forecast:
            /// the API adds one every season.
            public enum Condition: String, Codable, Sendable {
                case clear, cloudy, rain, snow, fog, wind

                public init(from decoder: Decoder) throws {
                    let raw = try decoder.singleValueContainer().decode(String.self)
                    self = Condition(rawValue: raw) ?? .cloudy
                }
            }

            """)]),
            ("Cache the last forecast", [("Sources/Weather/ForecastCache.swift", """
            import Foundation

            public actor ForecastCache {
                private var last: [String: (Forecast, Date)] = [:]
                private let ttl: TimeInterval = 600

                public init() {}

                public func forecast(for place: String) -> Forecast? {
                    guard let (forecast, at) = last[place], Date().timeIntervalSince(at) < ttl else { return nil }
                    return forecast
                }

                public func store(_ forecast: Forecast, for place: String) {
                    last[place] = (forecast, Date())
                }
            }

            """), ("Sources/Weather/ForecastClient.swift", """
            import Foundation

            public actor ForecastClient {
                private let session: URLSession
                private let cache = ForecastCache()
                private let base = URL(string: "https://api.example.com/v1")!

                public init(session: URLSession = .shared) { self.session = session }

                public func forecast(for place: String) async throws -> Forecast {
                    if let cached = await cache.forecast(for: place) { return cached }
                    let url = base.appending(path: "forecast").appending(queryItems: [.init(name: "q", value: place)])
                    let (data, _) = try await session.data(from: url)
                    let forecast = try JSONDecoder().decode(Forecast.self, from: data)
                    await cache.store(forecast, for: place)
                    return forecast
                }
            }

            """)]),
        ],
        todo: """
        ## Widget

        - [x] Shared `Forecast` model
        - [x] Unknown conditions decode as cloudy
        - [ ] Cache the last forecast for ten minutes (`ForecastCache`)
        - [ ] Timeline entries every three hours

        ## App

        - [ ] Location permission copy
        - [ ] Hourly strip

        """,
        context: ["Sources/Weather/ForecastClient.swift", "Package.swift"],
        chat: nil,
        startup: [tool("tests.zsh", "swift")],
        layout: { root, panes in
            // A package with its tests running in watch mode, an agent working through
            // the cache, and the change the Git pane has to show.
            let files = tile(.fileTree, root, into: &panes)
            let editor = tile(.editor, root, file: "Sources/Weather/ForecastClient.swift", into: &panes)
            let tests = shell(root, title: "tests", into: &panes)
            let agent = agent(root, "working", into: &panes)
            let git = tile(.git, root, into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .left, newPane: files, ratio: 0.2)
            tree.split(editor, edge: .right, newPane: agent, ratio: 0.4)
            tree.split(editor, edge: .bottom, newPane: tests, ratio: 0.38)
            tree.split(agent, edge: .bottom, newPane: git, ratio: 0.4)
            tree.split(files, edge: .bottom, newPane: todo, ratio: 0.5)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.4)
            tree.focused = agent
            return tree
        })

    /// Python and a training script: shell, Resources, editor, todo.
    static let mlNotebook = Spec(
        name: "ml-notebook", symbol: "brain.fill", tint: "pink",
        files: [
            ("train.py", """
            import argparse
            import json
            from pathlib import Path

            import numpy as np


            def load(path: Path) -> tuple[np.ndarray, np.ndarray]:
                rows = np.loadtxt(path, delimiter=",", skiprows=1)
                return rows[:, :-1], rows[:, -1]


            def fit(x: np.ndarray, y: np.ndarray, epochs: int, lr: float) -> np.ndarray:
                w = np.zeros(x.shape[1])
                for _ in range(epochs):
                    grad = x.T @ (x @ w - y) / len(y)
                    w -= lr * grad
                return w


            if __name__ == "__main__":
                parser = argparse.ArgumentParser()
                parser.add_argument("--epochs", type=int, default=200)
                parser.add_argument("--lr", type=float, default=0.01)
                args = parser.parse_args()
                x, y = load(Path("data/housing.csv"))
                w = fit(x, y, args.epochs, args.lr)
                Path("out").mkdir(exist_ok=True)
                Path("out/weights.json").write_text(json.dumps(w.tolist()))
                print(f"trained {len(w)} weights over {args.epochs} epochs")

            """),
            ("data/housing.csv", "sqft,beds,age,price\n1200,2,30,310000\n1800,3,12,455000\n2400,4,5,610000\n950,1,45,220000\n3100,4,2,790000\n"),
            ("notebooks/explore.md", "# Exploring the housing set\n\nFive rows is not a dataset. Scale `sqft` before fitting or the gradient blows up at lr 0.01.\n"),
            ("requirements.txt", "numpy==2.1.1\npandas==2.2.3\nmatplotlib==3.9.2\n"),
            ("README.md", "# ml-notebook\n\nLinear regression on the housing set, by hand, to see every step.\n"),
        ],
        history: [
            ("Scale the features", [("train.py", """
            import argparse
            import json
            from pathlib import Path

            import numpy as np


            def load(path: Path) -> tuple[np.ndarray, np.ndarray]:
                rows = np.loadtxt(path, delimiter=",", skiprows=1)
                x, y = rows[:, :-1], rows[:, -1]
                return (x - x.mean(axis=0)) / x.std(axis=0), y


            def fit(x: np.ndarray, y: np.ndarray, epochs: int, lr: float) -> np.ndarray:
                w = np.zeros(x.shape[1])
                for _ in range(epochs):
                    grad = x.T @ (x @ w - y) / len(y)
                    w -= lr * grad
                return w


            if __name__ == "__main__":
                parser = argparse.ArgumentParser()
                parser.add_argument("--epochs", type=int, default=200)
                parser.add_argument("--lr", type=float, default=0.01)
                args = parser.parse_args()
                x, y = load(Path("data/housing.csv"))
                w = fit(x, y, args.epochs, args.lr)
                Path("out").mkdir(exist_ok=True)
                Path("out/weights.json").write_text(json.dumps(w.tolist()))
                print(f"trained {len(w)} weights over {args.epochs} epochs")

            """)]),
            ("Report the loss", [("train.py", """
            import argparse
            import json
            from pathlib import Path

            import numpy as np


            def load(path: Path) -> tuple[np.ndarray, np.ndarray]:
                rows = np.loadtxt(path, delimiter=",", skiprows=1)
                x, y = rows[:, :-1], rows[:, -1]
                return (x - x.mean(axis=0)) / x.std(axis=0), y


            def fit(x: np.ndarray, y: np.ndarray, epochs: int, lr: float) -> tuple[np.ndarray, float]:
                w = np.zeros(x.shape[1])
                for _ in range(epochs):
                    grad = x.T @ (x @ w - y) / len(y)
                    w -= lr * grad
                loss = float(np.mean((x @ w - y) ** 2))
                return w, loss


            if __name__ == "__main__":
                parser = argparse.ArgumentParser()
                parser.add_argument("--epochs", type=int, default=200)
                parser.add_argument("--lr", type=float, default=0.01)
                args = parser.parse_args()
                x, y = load(Path("data/housing.csv"))
                w, loss = fit(x, y, args.epochs, args.lr)
                Path("out").mkdir(exist_ok=True)
                Path("out/weights.json").write_text(json.dumps(w.tolist()))
                print(f"trained {len(w)} weights over {args.epochs} epochs, loss {loss:,.0f}")

            """), ("data/housing.csv", "sqft,beds,age,price\n1200,2,30,310000\n1800,3,12,455000\n2400,4,5,610000\n950,1,45,220000\n3100,4,2,790000\n1500,3,20,380000\n2050,3,8,520000\n")]),
        ],
        todo: """
        ## Model

        - [x] Scale the features
        - [ ] Print the loss per 50 epochs (`train.py`)
        - [ ] Hold out two rows
        - [ ] Plot residuals (`notebooks/`)

        """,
        context: ["train.py", "data/housing.csv"],
        chat: nil,
        startup: [tool("build.zsh", "train"), "top -o cpu -s 2"],
        layout: { root, panes in
            // Training with its loss falling, the machine under it in top and in the
            // Resources pane, and an agent that has finished its pass over the script.
            let editor = tile(.editor, root, file: "train.py", into: &panes)
            let train = shell(root, title: "train", into: &panes)
            let top = shell(root, title: "top", into: &panes)
            let agent = agent(root, "done", into: &panes)
            let resources = tile(.resources, root, into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .right, newPane: agent, ratio: 0.38)
            tree.split(agent, edge: .right, newPane: todo, ratio: 0.34)
            tree.split(editor, edge: .bottom, newPane: train, ratio: 0.4)
            tree.split(train, edge: .right, newPane: top, ratio: 0.5)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.5)
            tree.split(context, edge: .bottom, newPane: resources, ratio: 0.5)
            tree.focused = train
            return tree
        })

    /// Terraform and a log: two shells, an editor, Ports and Resources.
    static let infra = Spec(
        name: "infra", symbol: "cpu.fill", tint: "teal",
        files: [
            ("main.tf", """
            terraform {
              required_providers {
                aws = { source = "hashicorp/aws", version = "~> 5.60" }
              }
              backend "s3" { bucket = "acme-tfstate", key = "prod/infra.tfstate", region = "eu-west-1" }
            }

            provider "aws" { region = var.region }

            module "network" {
              source = "./modules/network"
              cidr   = "10.20.0.0/16"
            }

            module "cluster" {
              source     = "./modules/cluster"
              subnet_ids = module.network.private_subnet_ids
              size       = var.cluster_size
            }

            """),
            ("variables.tf", "variable \"region\" { default = \"eu-west-1\" }\nvariable \"cluster_size\" { default = 3 }\n"),
            ("modules/network/main.tf", "resource \"aws_vpc\" \"this\" {\n  cidr_block = var.cidr\n  tags       = { Name = \"acme\" }\n}\n\noutput \"private_subnet_ids\" { value = [] }\n"),
            ("modules/cluster/main.tf", "resource \"aws_eks_cluster\" \"this\" {\n  name     = \"acme\"\n  role_arn = aws_iam_role.cluster.arn\n  vpc_config { subnet_ids = var.subnet_ids }\n}\n"),
            ("scripts/deploy.sh", "#!/bin/sh\nset -eu\nterraform init -input=false\nterraform plan -out=plan.tfplan\nterraform apply plan.tfplan\n"),
            ("README.md", "# infra\n\nThe production account, as Terraform. `scripts/deploy.sh` plans and applies.\n"),
        ],
        history: [
            ("Size the cluster per environment", [("variables.tf", "variable \"region\" { default = \"eu-west-1\" }\nvariable \"cluster_size\" { default = 3 }\nvariable \"environment\" { default = \"prod\" }\n")]),
            ("Add the database module", [("modules/database/main.tf", "resource \"aws_db_instance\" \"this\" {\n  engine         = \"postgres\"\n  engine_version = \"16\"\n  instance_class = \"db.t4g.medium\"\n  allocated_storage = 50\n}\n"), ("main.tf", """
            terraform {
              required_providers {
                aws = { source = "hashicorp/aws", version = "~> 5.60" }
              }
              backend "s3" { bucket = "acme-tfstate", key = "prod/infra.tfstate", region = "eu-west-1" }
            }

            provider "aws" { region = var.region }

            module "network" {
              source = "./modules/network"
              cidr   = "10.20.0.0/16"
            }

            module "cluster" {
              source     = "./modules/cluster"
              subnet_ids = module.network.private_subnet_ids
              size       = var.cluster_size
            }

            module "database" {
              source     = "./modules/database"
              subnet_ids = module.network.private_subnet_ids
            }

            """)]),
        ],
        todo: """
        ## Production

        - [x] Remote state in S3
        - [ ] Database module (`modules/database`)
          - [ ] Parameter group
          - [ ] Backups to a second region
        - [ ] Cluster autoscaling

        """,
        context: ["main.tf", "scripts/deploy.sh"],
        chat: nil,
        startup: [tool("deploy.zsh"), tool("logs.zsh", "infra"), "ping -i 1 1.1.1.1"],
        layout: { root, panes in
            // A deploy going through, the account's log beside it, a ping to the edge,
            // and what the machine and its ports are doing.
            let editor = tile(.editor, root, file: "main.tf", into: &panes)
            let deploy = shell(root, title: "deploy", into: &panes)
            let logs = shell(root, title: "logs", into: &panes)
            let ping = shell(root, title: "ping", into: &panes)
            let resources = tile(.resources, root, into: &panes)
            let ports = tile(.ports, root, into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .right, newPane: deploy, ratio: 0.42)
            tree.split(deploy, edge: .right, newPane: todo, ratio: 0.34)
            tree.split(editor, edge: .bottom, newPane: logs, ratio: 0.35)
            tree.split(deploy, edge: .bottom, newPane: ping, ratio: 0.3)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.45)
            tree.split(context, edge: .bottom, newPane: resources, ratio: 0.5)
            tree.split(resources, edge: .right, newPane: ports, ratio: 0.5)
            tree.focused = deploy
            return tree
        })

    /// Writing: a post in the editor, the todo, the context, a chat about the draft.
    static let blog = Spec(
        name: "blog", symbol: "quote.bubble.fill", tint: "yellow",
        files: [
            ("posts/2026-10-terminal-for-agents.md", """
            # A terminal built for agents

            Most terminals were designed for one person typing at one shell. An agent is a
            different kind of occupant: it writes more than it reads, it goes quiet when it
            needs you, and there are usually several of them.

            ## What changes

            A pane that holds an agent has a state — working, waiting, done — and the window
            should say so without being asked. A notification that an agent stopped is only
            useful if it says *which* project, because you have four open.

            ## What stays

            The shell. Every one of these panes is still a PTY, and nothing about agents is
            a reason to break `vim`.

            """),
            ("posts/2026-09-keyboard-first.md", "# Keyboard first\n\nAny action that needs the pointer is a bug, not a missing feature.\n"),
            ("drafts/outline.md", "- the pane as a unit\n- agents as occupants\n- what a notification owes you\n"),
            ("site/config.toml", "title = \"notes\"\nbase_url = \"https://notes.example.com\"\ntheme = \"plain\"\n"),
            ("README.md", "# blog\n\nPosts in `posts/`, drafts in `drafts/`. Build with `zola build`.\n"),
        ],
        history: [
            ("Outline the agents post", [("drafts/outline.md", "- the pane as a unit\n- agents as occupants\n- what a notification owes you\n- keep the shell\n")]),
            ("Draft the second section", [("posts/2026-10-terminal-for-agents.md", """
            # A terminal built for agents

            Most terminals were designed for one person typing at one shell. An agent is a
            different kind of occupant: it writes more than it reads, it goes quiet when it
            needs you, and there are usually several of them.

            ## What changes

            A pane that holds an agent has a state — working, waiting, done — and the window
            should say so without being asked. A notification that an agent stopped is only
            useful if it says *which* project, because you have four open.

            Files are the other half. The agent will mention `src/routes/orders.js` and you
            will want to see it, now, without leaving the pane. That is a file tree and an
            editor that the shell can reach.

            ## What stays

            The shell. Every one of these panes is still a PTY, and nothing about agents is
            a reason to break `vim`.

            """)]),
        ],
        todo: """
        ## October post

        - [x] Outline
        - [ ] Second section: files are the other half (`posts/2026-10-terminal-for-agents.md`)
        - [ ] A screenshot of four panes
        - [ ] Read it aloud once

        ## Site

        - [ ] RSS

        """,
        context: ["posts/2026-10-terminal-for-agents.md", "drafts/outline.md"],
        chat: blogChat,
        startup: ["wc -w posts/*.md drafts/*.md; git log --oneline --stat | head -n 20"],
        layout: { root, panes in
            // Writing: the post as a page, the chat about its opening, the word counts,
            // and the list and the files the post is about.
            let editor = tile(.editor, root, file: "posts/2026-10-terminal-for-agents.md", into: &panes)
            let chat = chatPane(root, blogChat, into: &panes)
            let words = shell(root, title: "words", into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .right, newPane: chat, ratio: 0.38)
            tree.split(editor, edge: .bottom, newPane: words, ratio: 0.28)
            tree.split(chat, edge: .bottom, newPane: todo, ratio: 0.4)
            tree.split(todo, edge: .right, newPane: context, ratio: 0.5)
            tree.focused = editor
            return tree
        })

    /// SQL and a loader: two shells, Git with a diff, an editor.
    static let dataPipeline = Spec(
        name: "data-pipeline", symbol: "cylinder.split.1x2.fill", tint: "indigo",
        files: [
            ("sql/001_events.sql", "create table events (\n  id bigserial primary key,\n  kind text not null,\n  payload jsonb not null,\n  at timestamptz not null default now()\n);\n\ncreate index events_at on events (at);\n"),
            ("sql/002_daily.sql", "create materialized view daily as\nselect date_trunc('day', at) as day, kind, count(*)\nfrom events group by 1, 2;\n"),
            ("load.py", """
            import json
            import sys

            import psycopg


            def main(path: str) -> None:
                with psycopg.connect("dbname=events") as conn, conn.cursor() as cur, open(path) as f:
                    for line in f:
                        event = json.loads(line)
                        cur.execute("insert into events (kind, payload) values (%s, %s)", (event["kind"], json.dumps(event)))
                    conn.commit()


            if __name__ == "__main__":
                main(sys.argv[1])

            """),
            ("Makefile", "load: ## load the latest export\n\tpython3 load.py data/export.jsonl\n\nrefresh:\n\tpsql events -c 'refresh materialized view daily'\n"),
            ("data/export.jsonl", "{\"kind\":\"signup\",\"user\":\"u_1\"}\n{\"kind\":\"purchase\",\"user\":\"u_1\",\"cents\":1999}\n{\"kind\":\"signup\",\"user\":\"u_2\"}\n"),
            ("README.md", "# data-pipeline\n\nEvents in, a daily view out. `make load` then `make refresh`.\n"),
        ],
        history: [
            ("Batch the inserts", [("load.py", """
            import json
            import sys

            import psycopg


            def main(path: str) -> None:
                with psycopg.connect("dbname=events") as conn, conn.cursor() as cur, open(path) as f:
                    rows = [(e["kind"], json.dumps(e)) for e in map(json.loads, f)]
                    cur.executemany("insert into events (kind, payload) values (%s, %s)", rows)
                    conn.commit()
                print(f"loaded {len(rows)} events")


            if __name__ == "__main__":
                main(sys.argv[1])

            """)]),
            ("Daily view by user too", [("sql/002_daily.sql", "create materialized view daily as\nselect date_trunc('day', at) as day, kind, count(*), count(distinct payload->>'user') as users\nfrom events group by 1, 2;\n"), ("sql/003_users.sql", "create table users (\n  id text primary key,\n  first_seen timestamptz not null\n);\n")]),
        ],
        todo: """
        ## Pipeline

        - [x] Batch the inserts
        - [ ] Daily view counts users (`sql/002_daily.sql`)
        - [ ] Users table from first signup (`sql/003_users.sql`)
        - [ ] Refresh nightly

        """,
        context: ["load.py", "sql/002_daily.sql"],
        chat: nil,
        startup: [tool("tests.zsh", "node"), "cat sql/002_daily.sql; git diff --stat", "top -o mem -s 3"],
        layout: { root, panes in
            // The loader's tests, the SQL in hand, memory in top, and the diff the Git
            // pane shows beside what is left to do.
            let tests = shell(root, title: "tests", into: &panes)
            let psql = shell(root, title: "psql", into: &panes)
            let top = shell(root, title: "top", into: &panes)
            let git = tile(.git, root, into: &panes)
            let editor = tile(.editor, root, file: "sql/002_daily.sql", into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: editor)
            tree.split(editor, edge: .left, newPane: git, ratio: 0.3)
            tree.split(editor, edge: .right, newPane: tests, ratio: 0.38)
            tree.split(git, edge: .bottom, newPane: todo, ratio: 0.5)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.45)
            tree.split(editor, edge: .bottom, newPane: psql, ratio: 0.4)
            tree.split(tests, edge: .bottom, newPane: top, ratio: 0.5)
            tree.focused = tests
            return tree
        })

    /// A Go CLI: one big shell, a tree, the todo.
    static let cliTool = Spec(
        name: "envsync", symbol: "apple.terminal.fill", tint: "orange",
        files: [
            ("go.mod", "module github.com/acme/envsync\n\ngo 1.23\n"),
            ("main.go", """
            package main

            import (
            	"flag"
            	"fmt"
            	"os"

            	"github.com/acme/envsync/internal/sync"
            )

            func main() {
            	from := flag.String("from", ".env", "file to read")
            	to := flag.String("to", "", "secret store to write (aws|gcp|1p)")
            	dry := flag.Bool("dry-run", false, "print what would change")
            	flag.Parse()
            	if *to == "" {
            		fmt.Fprintln(os.Stderr, "envsync: --to is required")
            		os.Exit(2)
            	}
            	if err := sync.Run(*from, *to, *dry); err != nil {
            		fmt.Fprintln(os.Stderr, "envsync:", err)
            		os.Exit(1)
            	}
            }

            """),
            ("internal/sync/sync.go", """
            package sync

            import (
            	"bufio"
            	"fmt"
            	"os"
            	"strings"
            )

            func Run(from, to string, dry bool) error {
            	f, err := os.Open(from)
            	if err != nil {
            		return err
            	}
            	defer f.Close()
            	s := bufio.NewScanner(f)
            	for s.Scan() {
            		k, v, ok := strings.Cut(s.Text(), "=")
            		if !ok || strings.HasPrefix(k, "#") {
            			continue
            		}
            		if dry {
            			fmt.Printf("would set %s in %s\\n", k, to)
            			continue
            		}
            		_ = v // TODO: write to the store
            	}
            	return s.Err()
            }

            """),
            (".env.example", "DATABASE_URL=postgres://localhost/app\nSTRIPE_KEY=sk_test_xxx\n# LOG_LEVEL=debug\n"),
            ("README.md", "# envsync\n\nPush a `.env` into a secret store. `envsync --to aws --dry-run` shows the plan.\n"),
        ],
        history: [
            ("Skip blank lines", [("internal/sync/sync.go", """
            package sync

            import (
            	"bufio"
            	"fmt"
            	"os"
            	"strings"
            )

            func Run(from, to string, dry bool) error {
            	f, err := os.Open(from)
            	if err != nil {
            		return err
            	}
            	defer f.Close()
            	s := bufio.NewScanner(f)
            	for s.Scan() {
            		line := strings.TrimSpace(s.Text())
            		if line == "" || strings.HasPrefix(line, "#") {
            			continue
            		}
            		k, v, ok := strings.Cut(line, "=")
            		if !ok {
            			return fmt.Errorf("%s: not KEY=value", line)
            		}
            		if dry {
            			fmt.Printf("would set %s in %s\\n", k, to)
            			continue
            		}
            		_ = v // TODO: write to the store
            	}
            	return s.Err()
            }

            """)]),
            ("AWS store", [("internal/store/aws.go", "package store\n\ntype AWS struct{ Region string }\n\nfunc (a AWS) Set(key, value string) error { return nil }\n"), ("internal/sync/sync_test.go", "package sync\n\nimport \"testing\"\n\nfunc TestRunDry(t *testing.T) {\n\tif err := Run(\"../../.env.example\", \"aws\", true); err != nil {\n\t\tt.Fatal(err)\n\t}\n}\n")]),
        ],
        todo: """
        ## 0.2

        - [x] Dry run
        - [x] Skip blanks and comments
        - [ ] AWS store (`internal/store/aws.go`)
        - [ ] 1Password store
        - [ ] `--only KEY,KEY`

        """,
        context: ["main.go", ".env.example"],
        chat: nil,
        startup: [tool("tests.zsh", "go"), "go version 2>/dev/null || echo 'go is not installed here'; ls -la; git log --oneline"],
        layout: { root, panes in
            // A CLI: the tree, an agent working on the store, the tests in watch mode, a
            // shell, and the list and files beside them.
            let files = tile(.fileTree, root, into: &panes)
            let tests = shell(root, title: "tests", into: &panes)
            let work = shell(root, title: "shell", into: &panes)
            let agent = agent(root, "working", into: &panes)
            let todo = tile(.todo, root, into: &panes)
            let context = tile(.context, root, into: &panes)
            var tree = LayoutTree(single: agent)
            tree.split(agent, edge: .left, newPane: files, ratio: 0.2)
            tree.split(agent, edge: .right, newPane: tests, ratio: 0.4)
            tree.split(tests, edge: .bottom, newPane: work, ratio: 0.45)
            tree.split(files, edge: .bottom, newPane: todo, ratio: 0.55)
            tree.split(todo, edge: .bottom, newPane: context, ratio: 0.4)
            tree.focused = agent
            return tree
        })
}
