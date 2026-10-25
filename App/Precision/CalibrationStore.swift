import Foundation
import SkyCore

/// Loads the calibration JSON the tools write: Documents/calibration.json (copied in through Finder) wins over a
/// calibration.json bundled from Data/.
enum CalibrationStore {
    struct Loaded {
        var calibration = PrecisionCalibration()
        var source = "none"
    }

    static func load() -> Loaded {
        let candidates: [(String, URL?)] = [
            ("Documents/calibration.json", URL.documentsDirectory.appending(path: "calibration.json")),
            ("bundled calibration.json", Bundle.main.url(forResource: "calibration", withExtension: "json")),
        ]
        for (name, url) in candidates {
            guard let url, let data = try? Data(contentsOf: url) else { continue }
            do {
                return Loaded(calibration: try PrecisionCalibration.decode(data), source: name)
            } catch {
                return Loaded(source: "\(name) unreadable: \(error.localizedDescription)")
            }
        }
        return Loaded()
    }
}
