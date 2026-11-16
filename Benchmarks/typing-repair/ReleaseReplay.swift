struct ReplayRelease: Codable {
    let x, y, radius: CGFloat
}

// Compiled alongside KeyboardView so both benchmarks use its real hit test and release target.
extension KeyboardView {
    func replayTarget(at point: CGPoint) -> UIButton? {
        let down = hitTest(point, with: nil)
        guard let source = down as? KeyButton else { return down as? UIButton }
        return button(at: point, from: source)
    }

    #if MB_CONTACT_REPLAY
    func replayContact(at point: CGPoint, assigned: UIButton?, radius: CGFloat) -> UIButton? {
        guard let key = assigned as? KeyButton else { return assigned }
        return contactTarget(at: point, assigned: key, radius: radius)
    }
    #endif

    func resolveReplayRelease(_ release: ReplayRelease) -> (String, UInt32) {
        let point = CGPoint(x: release.x, y: release.y)
        var target = replayTarget(at: point)
        #if MB_CONTACT_REPLAY
        target = replayContact(at: point, assigned: target, radius: release.radius)
        #endif
        guard let target, let name = target.accessibilityLabel else { return ("drop", 0) }
        let key = name == "Space" ? " " : name.lowercased()
        #if MB_SPATIAL_CORRECTION
        if let cap = target as? KeyButton { return (key, nearbyLetters(at: point, for: cap.key)) }
        return (key, 0)
        #else
        return (key, 0)
        #endif
    }
}
