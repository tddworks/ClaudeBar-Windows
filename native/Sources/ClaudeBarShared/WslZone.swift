import Foundation

/// The name Windows' zone goes to a distro by, in `TZ`
/// (docs/plans/2026-11-03-wsl-design.md, The time zone). `DataSources.timeZone()`
/// is CLDR's name for Windows' key, which always has a `/`, or a fixed offset,
/// which Foundation names `GMT+0900` or `GMT`: no file has that name, glibc
/// reads it as UTC, and the probe stops on it.
public enum WslZone {
    /// CLDR's names that tzdata moved to its `backward` file, which Ubuntu
    /// ships apart in `tzdata-legacy`, by the names tzdata links them to.
    public static let renamed: [String: String] = [
        "America/Buenos_Aires": "America/Argentina/Buenos_Aires",
        "America/Godthab": "America/Nuuk",
        "America/Indianapolis": "America/Indiana/Indianapolis",
        "Asia/Calcutta": "Asia/Kolkata",
        "Asia/Katmandu": "Asia/Kathmandu",
        "Asia/Rangoon": "Asia/Yangon",
        "Europe/Kiev": "Europe/Kyiv",
    ]

    /// The name a distro's tzdata knows `zone` by at `date`: a named zone by
    /// its current name; a fixed offset of whole hours as `Etc/GMT∓h` (POSIX's
    /// sign: +09:00 is `Etc/GMT-9`), tzdata's −12 to +14; none as `Etc/UTC`.
    /// nil for any other offset: no tzdata name counts as it does.
    public static func name(for zone: TimeZone, at date: Date) -> String? {
        if zone.identifier.contains("/") { return renamed[zone.identifier] ?? zone.identifier }
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds % 3600 == 0 else { return nil }
        let hours = seconds / 3600
        if hours == 0 { return "Etc/UTC" }
        guard (-12...14).contains(hours) else { return nil }
        return hours > 0 ? "Etc/GMT-\(hours)" : "Etc/GMT+\(-hours)"
    }
}
