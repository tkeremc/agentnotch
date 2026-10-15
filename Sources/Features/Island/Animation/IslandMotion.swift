import Foundation

// A critically damped spring settles without bouncing past the notch edges.
// Retargeting preserves position and velocity, including during quick hovers.
struct IslandMotion {
    var progress: Double = 0
    var velocity: Double = 0

    mutating func advance(toward target: Double, elapsed: Double, frequency: Double) {
        let displacement = progress - target
        let weight = velocity + frequency * displacement
        let wave = displacement + weight * elapsed
        let attenuation = exp(-frequency * elapsed)
        progress = target + attenuation * wave
        velocity = attenuation * (weight - frequency * wave)
        if abs(progress - target) < 0.002 && abs(velocity) < 0.04 {
            self = IslandMotion(progress: target)
        }
    }
}
