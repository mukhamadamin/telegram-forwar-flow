// Telegram-iOS integration, part 1: submodules/ShareController/Sources/ShareControllerForwardFlow.swift
// (add "//submodules/ForwardFlow" to ShareController/BUILD deps).
// Needs small patches in ShareControllerNode, ShareControllerPeerGridItemNode and SelectablePeerNode,
// and a call from ShareControllerNode.commitSend — see README.md, steps 3–4.

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import ForwardFlow

extension ShareControllerNode {
    /// Runs the copy of the message into the selected avatars and keeps the sheet on screen until
    /// the last avatar has settled, then animates the sheet out. false — use the regular dismissal.
    func beginForwardFlow(peerIds: [EnginePeer.Id]) -> Bool {
        if UIAccessibility.isReduceMotionEnabled {
            return false
        }
        guard let makeSource = self.forwardFlowSource, let source = makeSource(),
              let window = self.view.window, let peersContentNode = self.peersContentNode else {
            return false
        }

        // Avatars of the selected peers that are on screen. A peer picked in search and not in the grid
        // gets no copy — its message is sent all the same.
        var avatarViews: [UIView] = []
        for peerId in peerIds {
            var found: ShareControllerPeerGridItemNode?
            peersContentNode.contentGridNode.forEachItemNode { itemNode in
                if let itemNode = itemNode as? ShareControllerPeerGridItemNode, itemNode.peerId == peerId {
                    found = itemNode
                }
            }
            if let avatarView = found?.avatarView, avatarView.window != nil {
                avatarViews.append(avatarView)
            }
        }
        guard !avatarViews.isEmpty,
              let animator = ForwardFlowAnimator(bundle: ForwardFlowAnimator.resourceBundle()) else {
            return false
        }

        let targets = avatarViews.enumerated().map { index, avatarView -> ForwardFlowTarget in
            let frame = avatarView.convert(avatarView.bounds, to: window)
            return ForwardFlowTarget(id: index, center: CGPoint(x: frame.midX, y: frame.midY),
                                     radius: frame.width / 2, tint: ForwardFlowTint.light(of: avatarView))
        }
        // A selected avatar is already scaled down by SelectablePeerNode: scale on top of that and
        // restore it at the end.
        let baseTransforms = avatarViews.map { $0.layer.transform }
        // Ring after landing: a stroke around each avatar, in the avatar's own superview.
        let ripples = zip(avatarViews, targets).map { avatarView, target -> CAShapeLayer in
            let layer = CAShapeLayer()
            layer.frame = avatarView.frame
            layer.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: avatarView.frame.size)).cgPath
            layer.fillColor = nil
            layer.strokeColor = UIColor(red: target.tint.red, green: target.tint.green, blue: target.tint.blue, alpha: 1).cgColor
            layer.lineWidth = 3
            layer.opacity = 0
            avatarView.superview?.layer.addSublayer(layer)
            return layer
        }

        animator.meshView.frame = window.bounds
        window.addSubview(animator.meshView)
        self.isUserInteractionEnabled = false
        self.forwardFlowAnimator = animator

        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        animator.onUpdate = { states in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, state) in states.enumerated() where index < avatarViews.count {
                avatarViews[index].layer.transform = CATransform3DScale(baseTransforms[index], state.scale, state.scale, 1)
                ripples[index].transform = CATransform3DMakeScale(state.rippleScale, state.rippleScale, 1)
                ripples[index].opacity = Float(state.rippleAlpha)
            }
            CATransaction.commit()
        }
        animator.onTargetAbsorbed = { _ in
            haptic.impactOccurred()
        }
        animator.onCompletion = { [weak self] in
            animator.meshView.removeFromSuperview()
            for (view, transform) in zip(avatarViews, baseTransforms) { view.layer.transform = transform }
            for layer in ripples { layer.removeFromSuperlayer() }
            animator.onUpdate = nil
            animator.onCompletion = nil
            guard let self else {
                return
            }
            self.forwardFlowAnimator = nil
            self.isUserInteractionEnabled = true
            self.animateOut(shared: true, completion: {})
            let pending = self.forwardFlowPending
            self.forwardFlowPending = []
            pending.forEach { $0() }
        }
        animator.start(source: source, targets: targets)
        return true
    }

    /// Runs `action` (the "Forwarded" toast and the final dismissal) after the flow, or now if none runs.
    func afterForwardFlow(_ action: @escaping () -> Void) {
        if let animator = self.forwardFlowAnimator, animator.isRunning {
            self.forwardFlowPending.append(action)
        } else {
            action()
        }
    }
}

/// The color a copy takes on near an avatar: the average of its top half, lightened — works for
/// gradient placeholders and photos alike.
enum ForwardFlowTint {
    static func light(of view: UIView) -> (red: Double, green: Double, blue: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            // UIKit orientation (origin top-left), then the top half of the avatar squeezed into one pixel.
            context.translateBy(x: 0, y: 1)
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: 1 / max(view.bounds.width, 1), y: 2 / max(view.bounds.height, 1))
            view.layer.render(in: context)
            return true
        }
        guard drawn, pixel[3] > 0 else {
            return (0.45, 0.75, 1.0)
        }
        let alpha = Double(pixel[3]) / 255
        let rgb = (0..<3).map { Double(pixel[$0]) / 255 / alpha }
        return (min(rgb[0] * 0.6 + 0.4, 1), min(rgb[1] * 0.6 + 0.4, 1), min(rgb[2] * 0.6 + 0.4, 1))
    }
}
