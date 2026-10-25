import Foundation
import simd

public struct DeepSkyObject: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case galaxy, openCluster, globularCluster, planetaryNebula, nebula, clusterWithNebula, supernovaRemnant
        case starGroup, other
    }

    public var id: String
    public var messier: Int?
    public var name: String?
    /// OpenNGC type code.
    public var type: String
    public var raDeg: Double
    public var decDeg: Double
    public var mag: Double?
    public var majAxArcmin: Double?
    public var minAxArcmin: Double?
    public var posAngle: Double?

    /// ICRS (J2000) unit vector.
    public var direction: SIMD3<Double> { .unit(lon: Angle.radians(raDeg), lat: Angle.radians(decDeg)) }

    public var kind: Kind {
        switch type {
        case "G", "GPair", "GTrpl", "GGroup": .galaxy
        case "OCl": .openCluster
        case "GCl": .globularCluster
        case "PN": .planetaryNebula
        case "Neb", "HII", "EmN", "RfN", "DrkN": .nebula
        case "Cl+N": .clusterWithNebula
        case "SNR": .supernovaRemnant
        case "*", "**", "*Ass": .starGroup
        default: .other
        }
    }

    /// "M42 Orion Nebula", "NGC 869", …
    public var displayName: String {
        let designation = messier.map { "M\($0)" } ?? id
        guard let name, !name.isEmpty else { return designation }
        return designation == name ? name : "\(designation) \(name)"
    }
}

/// `Data/dso.json` (OpenNGC subset, sorted by magnitude).
public struct DeepSkyCatalog: Sendable, Codable {
    public var version: Int
    public var source: String?
    public var magLimit: Double?
    public var objects: [DeepSkyObject]

    public init(url: URL) throws { self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    public init(data: Data) throws { self = try JSONDecoder().decode(Self.self, from: data) }
}

public struct VisibleDeepSkyObject: Sendable, Hashable {
    public var object: DeepSkyObject
    public var screenPoint: SIMD2<Double>
    /// Major axis on screen in points (0 if unknown).
    public var majorAxisPoints: Double
}

/// Zoom-dependent selection: more and fainter objects as the field of view narrows.
public struct DeepSkySelection: Sendable, Hashable {
    /// Horizontal field of view (degrees) at which `baseCount` / `baseMagnitude` apply.
    public var referenceFOV = 60.0
    public var baseCount = 25
    public var maxCount = 150
    public var minCount = 10
    public var baseMagnitude = 7.5
    public var maxMagnitude = 11.0

    public init() {}

    public func countLimit(horizontalFOVDegrees fov: Double) -> Int {
        let n = Double(baseCount) * referenceFOV / max(fov, 1)
        return min(maxCount, max(minCount, Int(n.rounded())))
    }

    public func magnitudeLimit(horizontalFOVDegrees fov: Double) -> Double {
        min(maxMagnitude, baseMagnitude + 5 * log10(referenceFOV / max(fov, 1)))
    }

    /// Objects on screen, brightest first (Messier objects without magnitude count as mag 8), capped by zoom.
    /// `icrsToENU` should come from `SkySession.icrsToENU(at:)`; positions are refracted when `refraction` is given.
    public func select(_ objects: [DeepSkyObject], projector: Projector, icrsToENU: simd_double3x3,
                       refraction: Refraction? = .standard, horizontalFOVDegrees fov: Double,
                       aboveHorizonOnly: Bool = true) -> [VisibleDeepSkyObject] {
        let magLimit = magnitudeLimit(horizontalFOVDegrees: fov)
        let limit = countLimit(horizontalFOVDegrees: fov)
        let pointsPerRadian = projector.intrinsics.fx * projector.mapping.scale
        var result: [VisibleDeepSkyObject] = []
        let ordered = objects.sorted { ($0.mag ?? ($0.messier != nil ? 8 : 99)) < ($1.mag ?? ($1.messier != nil ? 8 : 99)) }
        for o in ordered {
            let mag = o.mag ?? (o.messier != nil ? 8 : 99)
            if mag > magLimit { break }
            var enu = icrsToENU * o.direction
            if aboveHorizonOnly && enu.z < 0 { continue }
            if let refraction { enu = refraction.apparent(enu: enu) }
            guard let s = projector.screenPoint(enu: enu), projector.isOnScreen(s) else { continue }
            let size = Angle.radians((o.majAxArcmin ?? 0) / 60) * pointsPerRadian
            result.append(VisibleDeepSkyObject(object: o, screenPoint: s, majorAxisPoints: size))
            if result.count >= limit { break }
        }
        return result
    }
}
