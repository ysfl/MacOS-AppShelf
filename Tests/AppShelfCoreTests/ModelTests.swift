import Foundation
import Testing

@testable import AppShelfCore

/// Byte formatting for the card footers.
struct ByteFormatterTests {

    @Test("磁盘占用按 Finder 的口径显示")
    func diskUnits() throws {
        #expect(ByteFormatter.disk(1_342_177_280) == "1.3 GB")   // exactly 1.25, not "1.2"
        #expect(ByteFormatter.disk(1_073_741_824) == "1.0 GB")
        #expect(ByteFormatter.disk(268_435_456) == "256 MB")
        #expect(ByteFormatter.disk(524_288) == "512 KB")
        #expect(ByteFormatter.disk(1024) == "1 KB")
    }

    @Test("内存占用用短单位")
    func memoryUnits() throws {
        #expect(ByteFormatter.memory(536_870_912) == "512 M")
        #expect(ByteFormatter.memory(1_610_612_736) == "1.5 G")
    }

    @Test("零与负数显示占位符而不是 0 KB")
    func zeroAndNegativeShowPlaceholder() throws {
        // An app that just stopped running must not read as "0 K" of memory in use.
        #expect(ByteFormatter.disk(0) == ByteFormatter.placeholder)
        #expect(ByteFormatter.memory(0) == ByteFormatter.placeholder)
        #expect(ByteFormatter.disk(-1) == ByteFormatter.placeholder)
    }

    @Test("单位在取整之后才选定")
    func unitBoundary() throws {
        // The old code picked the unit from the unrounded value, so 1,048,575 bytes —
        // 1023.999 KB — printed "1024 KB" instead of "1 MB".
        #expect(ByteFormatter.disk(1_048_575) == "1 MB")
        #expect(ByteFormatter.disk(1_073_741_823) == "1.0 GB")
        #expect(ByteFormatter.disk(1_047_552) == "1023 KB")
        #expect(ByteFormatter.memory(1_048_575) == "1 M")
    }

    @Test("非空文件不会显示成 0 KB")
    func tinyFilesAreNotZero() throws {
        #expect(ByteFormatter.disk(1) == "1 KB")
        #expect(ByteFormatter.disk(500) == "1 KB")
    }
}

/// Bundle paths are the identity of an app everywhere, so normalization is load-bearing.
struct ShelfPathTests {

    @Test("同一 bundle 的不同写法归一到同一身份")
    func normalization() throws {
        let expected = "/Applications/Foo.app"
        #expect(ShelfPath.normalize("/Applications//Foo.app") == expected)
        #expect(ShelfPath.normalize("/Applications/./Foo.app") == expected)
        #expect(ShelfPath.normalize("/Applications/Foo.app/../Foo.app") == expected)
        #expect(ShelfPath.normalize("/Applications/Foo.app/") == expected)
    }

    @Test("归一后的路径可以当身份比较")
    func normalizedPathsCompareEqual() throws {
        let a = AppItem(name: "Foo", path: "/Applications/./Foo.app", bundleIdentifier: nil, category: "其他")
        let b = AppItem(name: "Foo", path: "/Applications/Foo.app", bundleIdentifier: nil, category: "其他")
        #expect(a == b)
        #expect(a.id == b.id)
    }

    @Test("扩展名判断不分大小写，且不被目录名骗到")
    func bundleExtension() throws {
        #expect(ShelfPath.isApplicationBundle("/Applications/Foo.app"))
        #expect(ShelfPath.isApplicationBundle("/Applications/FOO.APP"))
        // Used to be `hasSuffix(".app")`, which also accepted "NotAnApp.bundle" style names
        // ending in the wrong thing and rejected uppercase.
        #expect(!ShelfPath.isApplicationBundle("/Applications/My.app.folder"))
        #expect(!ShelfPath.isApplicationBundle("/Applications/Notes.txt"))
        #expect(!ShelfPath.isApplicationBundle("/Applications/MyApp"))
    }

    @Test("默认键名互不重复，避免留下孤儿偏好")
    func defaultKeysAreDistinct() throws {
        let keys = [ShelfDefaults.groupState, ShelfDefaults.sizeCache, ShelfDefaults.hiddenApps,
                    ShelfDefaults.hotKey, ShelfDefaults.statusItem, ShelfDefaults.language,
                    ShelfDefaults.appearance, ShelfDefaults.quickToolsEnabled,
                    ShelfDefaults.quickToolsCustom]
        #expect(Set(keys).count == keys.count)
        // Retired keys must never collide with a live one.
        for retired in ShelfDefaults.retired {
            #expect(!keys.contains(retired))
        }
    }
}

/// Hiding apps and inverting group membership.
struct HiddenAndMembershipTests {

    @Test("隐藏列表按归一路径判断")
    func hidingNormalizes() throws {
        var list = HiddenAppList()
        let firstHide = list.hide("/Applications//Foo.app")
        #expect(firstHide)
        #expect(list.contains("/Applications/Foo.app"))
        #expect(list.contains("/Applications/./Foo.app"))
        // Second hide changes nothing, so the caller can skip a save.
        let secondHide = list.hide("/Applications/Foo.app")
        #expect(!secondHide)
        #expect(list.count == 1)
    }

    @Test("显示回来与全部显示")
    func revealing() throws {
        var list = HiddenAppList(paths: ["/A.app", "/B.app"])
        let firstReveal = list.reveal("/A.app")
        let secondReveal = list.reveal("/A.app")
        #expect(firstReveal)
        #expect(!secondReveal)
        #expect(list.count == 1)
        list.revealAll()
        #expect(list.isEmpty)
    }

    @Test("隐藏的应用从可见列表中剔除")
    func filtering() throws {
        let apps = [AppItem(name: "A", path: "/A.app", bundleIdentifier: nil, category: "其他"),
                    AppItem(name: "B", path: "/B.app", bundleIdentifier: nil, category: "其他")]
        let hidden = HiddenAppList(paths: ["/B.app"])
        #expect(hidden.filtering(apps).map(\.name) == ["A"])
        #expect(HiddenAppList().filtering(apps).count == 2)
    }

    @Test("归属反查覆盖多个分组")
    func membershipAcrossGroups() throws {
        let shared = "/Applications/Shared.app"
        let groups = [
            AppGroup(name: "G1", symbol: "star", colorHex: "#FFF", appPaths: [shared, "/A.app"]),
            AppGroup(name: "G2", symbol: "folder", colorHex: "#000", appPaths: ["/Applications//Shared.app"])
        ]
        let membership = MembershipIndex.build(groups: groups)
        #expect(membership[shared]?.count == 2)
        #expect(MembershipIndex.groupedPaths(groups: groups) == Set([shared, "/A.app"]))
    }

    @Test("未分组按名称排序且排除已归组的")
    func ungrouped() throws {
        let apps = [AppItem(name: "Beta", path: "/B.app", bundleIdentifier: nil, category: "其他"),
                    AppItem(name: "alpha", path: "/A.app", bundleIdentifier: nil, category: "其他"),
                    AppItem(name: "Taken", path: "/T.app", bundleIdentifier: nil, category: "其他")]
        let groups = [AppGroup(name: "G", symbol: "star", colorHex: "#FFF", appPaths: ["/T.app"])]
        #expect(MembershipIndex.ungrouped(apps, groups: groups).map(\.name) == ["alpha", "Beta"])
    }

    @Test("快捷工具 id 前缀编解码")
    func quickToolIDs() throws {
        let uuid = UUID()
        #expect(QuickToolID("terminal").rawValue == "builtin.terminal")
        #expect(QuickToolID(uuid).rawValue == "custom.\(uuid.uuidString)")
        #expect(QuickToolID(parsing: "builtin.terminal") == .builtin("terminal"))
        #expect(QuickToolID(parsing: "custom.\(uuid.uuidString)") == .custom(uuid))
        // A malformed id used to be parsed by hand with dropFirst(), which could make a
        // bad entry delete the wrong thing.
        #expect(QuickToolID(parsing: "custom.not-a-uuid") == nil)
        #expect(QuickToolID(parsing: "garbage") == nil)
        #expect(QuickToolID(parsing: "builtin.") == nil)
        #expect(QuickToolID(parsing: "custom.\(uuid.uuidString)").map(\.isCustom) == true)
    }
}

/// The keyword rules that seed the starter groups.
struct CategorizerTests {

    @Test("按名称与 bundle id 命中分类")
    func classification() throws {
        #expect(AppCategorizer.category(name: "Code", bundleIdentifier: "com.microsoft.VSCode") == .development)
        #expect(AppCategorizer.category(name: "微信", bundleIdentifier: "com.tencent.xinWeChat") == .communication)
        #expect(AppCategorizer.category(name: "Safari", bundleIdentifier: "com.apple.Safari") == .everyday)
        #expect(AppCategorizer.category(name: "活动监视器", bundleIdentifier: "com.apple.ActivityMonitor") == .utility)
        #expect(AppCategorizer.category(name: "Photoshop", bundleIdentifier: nil) == .creative)
        #expect(AppCategorizer.category(name: "完全没见过的东西", bundleIdentifier: "com.x.y") == .other)
    }

    @Test("bundle id 单独就能决定分类")
    func identifierAloneIsEnough() throws {
        #expect(AppCategorizer.category(name: "Zzz", bundleIdentifier: "com.todesktop.230313mzl4w4u92.slack") == .communication)
    }

    @Test("常用名单不分大小写")
    func commonNames() throws {
        #expect(AppCategorizer.commonNames.contains("safari"))
        #expect(AppCategorizer.seedGroup(for: "Safari", bundleIdentifier: "com.apple.Safari") == .common)
    }

    @Test("识别不出来的应用留在未分组，而不是塞进其他")
    func unknownAppsStayUngrouped() throws {
        #expect(AppCategorizer.seedGroup(for: "完全没见过的东西", bundleIdentifier: "com.x.y") == nil)
    }

    @Test("内置分组名与分类原始值一致")
    func defaultGroupsMatchCategoryTokens() throws {
        let names = Set(DefaultGroups.all.map(\.name))
        #expect(names == Set(ShelfCategory.allCases.filter { $0 != .other }.map(\.rawValue)))
        #expect(Set(DefaultGroups.all.map(\.id)).count == DefaultGroups.all.count)
    }
}
