// Prefs.swift — 語言、設定值、歷史紀錄
//
// 設定只有四個：目標大小、壓好的放哪、原檔怎麼辦、外觀／語言。其餘都寫死成好的預設值——
// 「不用調任何參數就能拿到好結果」。
import Foundation

// ─── 存在哪 ───────────────────────────────────────────────────────────

/// 設定存哪：平常＝使用者的 UserDefaults；驗收鉤（--script／--demo／--wizard 截圖）與命令列（--cli）另用一份，
/// 跑測試、其他程式叫它壓檔，都不會改到使用者在 app 裡的設定與紀錄。
enum Store {
    static let isTest: Bool = {
        let a = CommandLine.arguments
        return a.contains("--script") || a.contains("--demo") || a.contains("--snapshot") || a.contains("--cli")
    }()
    /// 每個測試實例一份（名字帶 PID）：好幾個測試同時跑時不會互相改到設定（不然一個實例在精靈選 10 MB，
    /// 同時在跑的另一個實例也會拿 10 MB 當目標）。結束時收掉，不在偏好設定夾留一堆檔。
    static let suite = "ltd.intention.slimly.selftest.\(ProcessInfo.processInfo.processIdentifier)"
    static let d: UserDefaults = isTest ? UserDefaults(suiteName: suite)! : .standard
    /// 測試開始前把測試用的設定清乾淨（只清這個實例那一份），並登記結束時收掉
    static func resetTestDefaults() {
        guard isTest else { return }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        atexit { UserDefaults.standard.removePersistentDomain(forName: Store.suite) }
    }
}

// ─── 語言 ─────────────────────────────────────────────────────────────

enum Lang {
    static let key = "SlimlyLang"                 // system／zh／en
    static var setting: String {
        get {
            let a = CommandLine.arguments                    // 截圖用：--lang zh／en
            if let i = a.firstIndex(of: "--lang"), a.count > i + 1 { return a[i + 1] }
            return Store.d.string(forKey: key) ?? "system"
        }
        set { Store.d.set(newValue, forKey: key) }
    }
    /// 實際用的語言：跟系統時看偏好語言第一個是不是中文（繁簡都算中文介面）
    static var code: String {
        switch setting {
        case "zh": return "zh"
        case "en": return "en"
        default:
            let first = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return first.hasPrefix("zh") ? "zh" : "en"
        }
    }
    static var isEn: Bool { code == "en" }
}

/// 給人看的字一律寫成 L("中文", "English")
func L(_ zh: String, _ en: String) -> String { Lang.isEn ? en : zh }

// ─── 設定值 ───────────────────────────────────────────────────────────

enum Prefs {
    private static var d: UserDefaults { Store.d }

    /// 目標大小（MB）。0＝不限大小、只做看不出差別的那一級。預設 25＝寄 Email 的上限（Gmail）。
    static var targetMB: Int {
        get {
            let a = CommandLine.arguments                    // 測試用：--target <MB>（不改使用者的設定）
            if let i = a.firstIndex(of: "--target"), a.count > i + 1, let v = Int(a[i + 1]) { return v }
            return d.object(forKey: "SlimlyTargetMB") as? Int ?? 25
        }
        set { d.set(max(0, newValue), forKey: "SlimlyTargetMB") }
    }
    static var targetBytes: Int64? { targetMB > 0 ? Int64(targetMB) * 1024 * 1024 : nil }

    /// 壓好的放哪：beside＝原檔旁邊（預設）／folder＝固定一個資料夾
    static var place: String {
        get { d.string(forKey: "SlimlyPlace") ?? "beside" }
        set { d.set(newValue, forKey: "SlimlyPlace") }
    }
    /// 「下載項目 › Slimly」。測試用 --downloads <資料夾> 換掉（驗「改存到下載項目」時不寫進使用者真的下載項目）
    static var defaultFolder: String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--downloads"), a.count > i + 1 { return a[i + 1] }
        return NSHomeDirectory() + "/Downloads/Slimly"
    }
    static var folder: String {
        get {
            let a = CommandLine.arguments                    // 測試用：--dest <資料夾>（不改使用者的設定）
            if let i = a.firstIndex(of: "--dest"), a.count > i + 1 { return a[i + 1] }
            return d.string(forKey: "SlimlyFolder") ?? defaultFolder
        }
        set { d.set(newValue, forKey: "SlimlyFolder") }
    }
    /// --dest 有給＝測試模式一律寫進那個資料夾
    static var effectivePlace: String {
        CommandLine.arguments.contains("--dest") ? "folder" : place
    }

    /// 原檔怎麼辦：keep＝留在原處（預設）／backup＝收進旁邊的「未壓縮備份」，壓好的用原檔名（只在「原檔旁邊」時有效）
    static var original: String {
        get {
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--original"), a.count > i + 1 { return a[i + 1] }
            return d.string(forKey: "SlimlyOriginal") ?? "keep"
        }
        set { d.set(newValue, forKey: "SlimlyOriginal") }
    }

    /// 照片的 GPS 位置：預設照留（跟原檔一樣）；開了＝壓好的照片拿掉位置資訊。測試用 --strip-gps
    static var stripGPS: Bool {
        get { CommandLine.arguments.contains("--strip-gps") || d.bool(forKey: "SlimlyStripGPS") }
        set { d.set(newValue, forKey: "SlimlyStripGPS") }
    }

    static var wizardDone: Bool {
        get { d.bool(forKey: "SlimlyWizardDone") }
        set { d.set(newValue, forKey: "SlimlyWizardDone") }
    }

    /// 外觀：system／light／dark
    static var theme: String {
        get {
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--theme"), a.count > i + 1 { return a[i + 1] }
            return d.string(forKey: "SlimlyTheme") ?? "system"
        }
        set { d.set(newValue, forKey: "SlimlyTheme") }
    }

    // ── 最近壓的（30 筆）──
    private static let historyKey = "SlimlyHistory"
    static var history: [[String: Any]] {
        get { (d.array(forKey: historyKey) as? [[String: Any]]) ?? [] }
        set { d.set(Array(newValue.prefix(30)), forKey: historyKey) }
    }
    static func remember(_ item: [String: Any]) {
        history = [item] + history          // 測試時寫進測試專用的那一份（Store）
    }
}

// ─── 大小怎麼寫給人看 ─────────────────────────────────────────────────

/// 1 MB＝1024×1024 bytes（跟信箱、表單的上限同一套算法；Finder 用的是 1000）
func humanSize(_ b: Int64) -> String {
    let mb = Double(b) / 1_048_576
    if mb >= 100 { return String(format: "%.0f MB", mb) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    let kb = Double(b) / 1024
    return String(format: "%.0f KB", max(1, kb))
}
