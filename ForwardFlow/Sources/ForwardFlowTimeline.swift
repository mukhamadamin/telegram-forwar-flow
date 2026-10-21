// ForwardFlow — «Forward» as a copy of the message flowing into the recipients' avatars.
// Geometry and timing. Pure Swift + CoreGraphics: no UIKit, no Metal.

import CoreGraphics
import Foundation

// MARK: - Configuration

/// All tunable parameters. Defaults are the values tuned in the prototype (Prototype/forward-flow.html).
public struct ForwardFlowConfig {
    // Peeling off
    /// The copy lifts off the original before it starts flowing (s).
    public var liftDuration: Double = 0.14
    /// Copy scale at the end of the lift.
    public var liftScale: Double = 1.035
    /// Lean towards the avatar while lifting (pt): with several recipients the copies already part here.
    public var lean: Double = 7

    // Flow (into one avatar)
    /// How long one copy flows (s): flow speed is fitted automatically.
    public var swallowDuration: Double = 0.66
    /// Delay between the copies for several recipients (s).
    public var stagger: Double = 0.07
    /// Smooth start of the flow (s) and overall acceleration over time (1/s).
    public var flowRamp: Double = 0.22
    public var flowAccel: Double = 3.5
    /// Acceleration near the avatar ("spaghettification") and its reach (in avatar radii).
    public var pullStrength: Double = 4
    public var pullReach: Double = 2.4
    /// Bend shape: 1 — straight edges, > 1 — edges overtake the middle and wrap the avatar.
    public var arcShape: Double = 1.8
    /// Twist of the stream (rad); the sign is mirrored for avatars left of the message.
    public var swirl: Double = 0.35
    /// How deep points go under the avatar edge (in avatar radii).
    public var sinkDepth: Double = 0.6
    /// Where the message starts taking on the avatar color and where it is gone (in avatar radii; 1 — edge).
    public var fadeOuter: Double = 2.2
    public var fadeInner: Double = 0.78
    /// Blur near the avatar (pt).
    public var fadeBlur: Double = 6

    // Avatar
    /// The avatar shrinks by this fraction while absorbing its copy.
    public var gulp: Double = 0.08
    /// Bulge after the last point lands, like the island in BlackHoleDelete (fraction of the size).
    public var bounce: Double = 0.16
    /// Duration of the spring (s).
    public var settleDuration: Double = 0.42

    public init() {}
    public static let `default` = ForwardFlowConfig()
}

// MARK: - Run

/// One recipient avatar: its center and radius in screen points.
public struct ForwardFlowTarget {
    public let id: Int
    public let center: CGPoint
    public let radius: CGFloat
    /// Color the message takes on near the avatar (light end of the avatar gradient), RGB 0…1.
    public let tint: (red: Double, green: Double, blue: Double)
    public init(id: Int, center: CGPoint, radius: CGFloat, tint: (red: Double, green: Double, blue: Double)) {
        self.id = id
        self.center = center
        self.radius = radius
        self.tint = tint
    }
}

/// Timing of one copy flowing into one avatar.
public struct ForwardFlowTrack {
    public let target: ForwardFlowTarget
    /// Unit vector avatar → message: the axis of the stream.
    public let axis: CGVector
    /// Flow speed fitted so that the farthest point is gone exactly after `swallowDuration` (pt/s).
    public let flowSpeed: Double
    public let start: Double
    /// The nearest point reaches the avatar edge / the farthest point is gone.
    public let touch: Double
    public let end: Double
    public let swirl: Double
}

/// Timing of one forward. Built once at send.
public struct ForwardFlowRun {
    public let config: ForwardFlowConfig
    /// Message snapshot frame before the lift (pt).
    public let frame: CGRect
    /// One track per recipient, in the order of the targets.
    public let tracks: [ForwardFlowTrack]

    public var total: Double { (tracks.map(\.end).max() ?? config.liftDuration) + config.settleDuration + 0.04 }

    public init(frame: CGRect, targets: [ForwardFlowTarget], config: ForwardFlowConfig = .default) {
        self.config = config
        self.frame = frame
        let lifted = Self.lifted(frame, by: 1, config: config)
        let mid = CGPoint(x: lifted.midX, y: lifted.midY)
        tracks = targets.enumerated().map { index, target in
            let dx = Double(mid.x - target.center.x), dy = Double(mid.y - target.center.y)
            let length = max(hypot(dx, dy), 0.001)
            let axis = CGVector(dx: dx / length, dy: dy / length)

            // Flow speed: travel distance is inversely proportional to speed.
            let unit = AvatarFlow(config: config, radius: Double(target.radius), speed: 1)
            let heights = Self.samples(of: lifted).map { unit.height(of: $0, target: target, axis: axis) }
            let far = heights.max() ?? 0, near = heights.min() ?? 0
            let path = unit.travelTime(far) - unit.travelTime(unit.floor)
            let eased = unit.eased(config.swallowDuration)
            let flow = AvatarFlow(config: config, radius: Double(target.radius), speed: (path > 0 && eased > 0) ? path / eased : 70)

            let start = config.liftDuration + Double(index) * config.stagger
            let side: Double = target.center.x >= mid.x ? 1 : -1
            return ForwardFlowTrack(target: target, axis: axis, flowSpeed: flow.speed, start: start,
                                    touch: start + flow.time(from: near, to: 0),
                                    end: start + flow.time(from: far, to: flow.floor),
                                    swirl: config.swirl * side)
        }
    }

    /// 0…1: how far the copy has peeled off the original.
    public func lift(at t: Double) -> Double {
        ForwardFlowEase.inOut(clamp01(t / max(config.liftDuration, 0.001)))
    }

    /// Message frame at time t: grows to `liftScale` around its center during the lift.
    public func frame(at t: Double) -> CGRect {
        Self.lifted(frame, by: lift(at: t), config: config)
    }

    static func lifted(_ frame: CGRect, by k: Double, config: ForwardFlowConfig) -> CGRect {
        let grow = CGFloat((config.liftScale - 1) * k)
        return frame.insetBy(dx: -frame.width * grow / 2, dy: -frame.height * grow / 2)
    }

    /// Corners, edge midpoints and center: the nearest point of a bubble is often mid-edge.
    static func samples(of frame: CGRect) -> [CGPoint] {
        [frame.minX, frame.midX, frame.maxX].flatMap { x in
            [frame.minY, frame.midY, frame.maxY].map { y in CGPoint(x: x, y: y) }
        }
    }
}

/// Flow towards one avatar — the same formula as the mesh vertex shader (`forwardFlowMeshVertex`).
struct AvatarFlow {
    let speed, strength, reach, ramp, sink, shape, accel, floor: Double

    init(config c: ForwardFlowConfig, radius: Double, speed: Double) {
        self.speed = max(speed, 1)
        strength = c.pullStrength
        reach = max(c.pullReach * radius, 1)
        ramp = c.flowRamp
        sink = c.sinkDepth * radius
        shape = c.arcShape
        accel = c.flowAccel
        // Lowest height a point needs to reach to be gone.
        floor = max((min(c.fadeInner, c.fadeOuter) - 1) * radius, -sink)
    }

    /// "Height" of a point above the avatar edge: D = ρ·k(φ) − r, φ measured from the stream axis.
    func height(of point: CGPoint, target: ForwardFlowTarget, axis: CGVector) -> Double {
        let r = Double(target.radius)
        let dx = Double(point.x - target.center.x), dy = Double(point.y - target.center.y)
        let rho = max(hypot(dx, dy), 0.001)
        let cosPhi = min(max((dx * Double(axis.dx) + dy * Double(axis.dy)) / rho, 0.65), 1)
        let t = clamp01((rho - r) / (r * 3))
        let w = t * t * (3 - 2 * t)
        return rho * pow(cosPhi, shape * w) - r
    }

    /// v(D) = speed · (1 + strength · e^(−D/reach)), so T(D) = reach · ln(e^(D/reach) + strength) / speed.
    func travelTime(_ x: Double) -> Double { (x + reach * log(1 + strength * exp(-x / reach))) / speed }

    func eased(_ tau: Double) -> Double {
        let ramped = ramp > 0.001 ? tau - ramp * (1 - exp(-tau / ramp)) : tau
        return accel > 0.001 ? (exp(accel * ramped) - 1) / accel : ramped
    }

    func time(from x: Double, to target: Double) -> Double {
        let need = travelTime(x) - travelTime(target)
        guard need > 0 else { return 0 }
        var lo = 0.0, hi = need + ramp + 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if eased(mid) < need { lo = mid } else { hi = mid }
        }
        return hi
    }
}

// MARK: - Avatar at time t

/// How the host should draw a recipient avatar at a moment of the run.
public struct ForwardFlowAvatarState {
    /// Scale of the avatar: shrinks while absorbing, springs back after the last point lands.
    public var scale: CGFloat
    /// Ring around the avatar after landing: scale (1 — avatar size) and opacity.
    public var rippleScale: CGFloat
    public var rippleAlpha: Double

    public static let rest = ForwardFlowAvatarState(scale: 1, rippleScale: 1, rippleAlpha: 0)

    public static func at(_ t: Double, track: ForwardFlowTrack, config c: ForwardFlowConfig) -> ForwardFlowAvatarState {
        if t < track.touch {
            return .rest
        }
        if t < track.end {
            let a = ForwardFlowEase.inOut(clamp01((t - track.touch) / max(track.end - track.touch, 0.01)))
            return ForwardFlowAvatarState(scale: CGFloat(1 - c.gulp * a), rippleScale: 1, rippleAlpha: 0)
        }
        // Back from the gulp and a damped bulge, exactly 1 at the end.
        let u = clamp01((t - track.end) / max(c.settleDuration, 0.01))
        let back = 1 - c.gulp * (1 - ForwardFlowEase.outCubic(u))
        let bulge = c.bounce * sin(.pi * u) * exp(-2.2 * u)
        return ForwardFlowAvatarState(scale: CGFloat(back + bulge),
                                      rippleScale: CGFloat(1 + 0.55 * ForwardFlowEase.outCubic(u)),
                                      rippleAlpha: u > 0 ? 0.55 * pow(1 - u, 1.6) : 0)
    }
}

enum ForwardFlowEase {
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
