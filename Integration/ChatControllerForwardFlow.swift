// Telegram-iOS integration, part 2: submodules/TelegramUI/Sources/Chat/ChatControllerForwardFlow.swift
// (add "//submodules/ForwardFlow" to TelegramUI/BUILD deps).
// Called from ChatControllerImpl.openMessageShareMenu — see README.md, step 5.

import Foundation
import UIKit
import Display
import TelegramCore
import ForwardFlow

extension ChatControllerImpl {
    /// Snapshot of the message bubble for the share sheet. Taken lazily, at the moment of sending:
    /// the chat may have scrolled while the sheet was open. nil — the sheet dismisses as usual.
    func forwardFlowSource(messageId: EngineMessage.Id) -> () -> ForwardFlowSource? {
        return { [weak self] in
            guard let self, !self.chatDisplayNode.historyNodeContainer.isSecret, let window = self.view.window else {
                return nil
            }
            var source: ForwardFlowSource?
            self.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
                guard source == nil, let item = itemNode.item,
                      item.content.contains(where: { $0.0.id == messageId }) else {
                    return
                }
                let view = itemNode.view
                let frame = view.convert(view.bounds, to: window)
                // Only a bubble on screen: off-screen ones have nothing to flow from.
                guard frame.intersects(window.bounds), frame.width >= 1.0, frame.height >= 1.0,
                      let image = ForwardFlowSnapshot.image(of: view) else {
                    return
                }
                // ShareControllerNode.dimNode is black at 0.5 over the chat.
                source = ForwardFlowSource(frame: frame, image: image, dimmed: 0.5)
            }
            return source
        }
    }
}

private enum ForwardFlowSnapshot {
    /// layer.render draws only the node's own layer tree (drawHierarchy would also capture the dim
    /// and the sheet above it).
    static func image(of view: UIView) -> CGImage? {
        guard view.bounds.width >= 1.0, view.bounds.height >= 1.0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage
    }
}
