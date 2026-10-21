# ForwardFlow — "Forward" as a message flowing into the recipients' avatars

When a message is forwarded from the share sheet, a copy peels off the original bubble and flows
into the avatars of the selected chats: it stretches into a stream near each avatar, takes on the
avatar's color and dissolves at its edge. The avatar shrinks slightly while absorbing its copy and
answers with a small spring and a ring. With several recipients the copy splits into several
streams that start one after another. Then the sheet closes and the regular "Message forwarded"
toast appears.

The flow model is the one from
[BlackHoleDelete](https://github.com/riveauxmia/telegram-black-hole-delete): a message snapshot on a
~6 pt grid, vertices carried by a flow whose speed is fitted to a fixed duration. Here the target is
an avatar in any direction instead of the Dynamic Island above.

Pure UIKit + Metal, no SwiftUI, no dependencies. iOS 15+.

▶︎ [Media/demo.mp4](Media/demo.mp4) — the effect in the web prototype (send to two chats at 1×,
then the same at 0.25×, then again at 1×).

## Repository

| Path | What |
|---|---|
| `ForwardFlow/` | Drop-in Telegram-iOS module (`submodules/ForwardFlow`). |
| `ForwardFlow/BUILD` | Bazel target; the shader is compiled into `default.metallib` inside a resource bundle. |
| `ForwardFlow/Sources/ForwardFlowTimeline.swift` | Config, timing of a run (one track per recipient), avatar state at time `t`. Pure Swift. |
| `ForwardFlow/Sources/ForwardFlowAnimator.swift` | Public API: one Metal view + one `CADisplayLink`; renderer and pipeline. |
| `ForwardFlow/Resources/ForwardFlow.metal` | Shader: message mesh carried into an avatar, tint, blur and fade near it. |
| `Integration/ShareControllerForwardFlow.swift` | Integration into `ShareControllerNode` (ShareController). |
| `Integration/ChatControllerForwardFlow.swift` | Message snapshot from `ChatControllerImpl` (TelegramUI). |
| `Demo/` | Standalone UIKit demo — builds and runs in the simulator without an Xcode project. |
| `Prototype/forward-flow.html` | Web prototype (WebGL2) with the same math: tuning sliders, 0.25× slow motion, scrubbing. |
| `Media/demo.mp4` | The web prototype rendered frame by frame (1080×1920, 30 fps). |

## How it works

One full-screen view over everything, in window coordinates:

```
chat (the original message stays in place)
  dim             share sheet dim (black, 0.5)
  share sheet     avatars: the host scales them by ForwardFlowAvatarState
    meshView      copies of the message flowing into the avatars
toast             "Message forwarded", after the flow
```

* **Peeling off.** The original stays in the chat; a snapshot copy lifts off it (`liftDuration`,
  `liftScale`) and leans towards its avatar (`lean`). With several recipients every copy leans its
  own way, so they already part during the lift. The original sits under the sheet dim, so the copy
  starts with the same dim (`ForwardFlowSource.dimmed`) and brightens while lifting — no jump.
* **Flow.** One track per recipient (`ForwardFlowRun`). The axis of the stream is avatar → message;
  the "height" above the avatar edge is `D = ρ·cos(φ)^shape − r`. Flow speed is fitted so the
  farthest point of the copy is gone exactly after `swallowDuration`; tracks start `stagger` apart.
  Speed grows near the avatar (`pullStrength`, `pullReach`), so the copy narrows into a stream and
  wraps the avatar (`arcShape`), with a slight twist (`swirl`, mirrored for avatars on the left).
* **Closed form.** With `v(D) = speed·(1 + s·e^(−D/R))` the travel time is `T(D) = R·ln(e^(D/R) + s)/v`,
  so the new height has a closed form and the vertex shader needs no Newton iterations.
* **Near the avatar** the copy takes on the avatar's color (the light end of its gradient, or the
  average of a photo), blurs through mip levels and dissolves just inside the edge (`fadeInner`).
* **Avatar.** `ForwardFlowAvatarState.at(t)` — shrinks by `gulp` while absorbing, then a damped
  bulge (`bounce`, `settleDuration`) and a ring, exactly at rest at the end. Each landing calls
  `onTargetAbsorbed` (light haptic).
* **Time** advances per frame with a capped step (1/30 s): after a dropped frame the animation
  continues from where it was instead of jumping. All state is a pure function of `t`, which is
  what makes slow motion and scrubbing in the prototype trivial.

## Integration into Telegram-iOS

The share sheet with the avatar grid is `ShareController` (`submodules/ShareController`), opened
for a message by `ChatControllerImpl.openMessageShareMenu(id:)` (the share button next to channel
posts). The integration was written against `master` of Telegram-iOS as of October 2026; names below
are checked against that code, but the module has **not been compiled inside Telegram-iOS yet**.

1. **Module.** Copy the `ForwardFlow/` folder to `submodules/ForwardFlow/` as is. It is a top-level
   submodule, not under `TelegramUI`: ShareController depends on it. `apple_resource_bundle` compiles
   the shader into `default.metallib` inside `ForwardFlowResourcesBundle.bundle`;
   `ForwardFlowAnimator.resourceBundle()` finds it.
2. **Deps.** Add `"//submodules/ForwardFlow"` to `deps` in `submodules/ShareController/BUILD` and in
   `submodules/TelegramUI/BUILD`. Put `Integration/ShareControllerForwardFlow.swift` into
   `submodules/ShareController/Sources/` and `Integration/ChatControllerForwardFlow.swift` into
   `submodules/TelegramUI/Sources/Chat/`.
3. **Expose what the integration reads.**

   `SelectablePeerNode.swift` (`SelectablePeerNode`):
   ```swift
   public var avatarView: UIView {
       return self.avatarNode.view
   }
   ```
   `ShareControllerPeerGridItem.swift` (`ShareControllerPeerGridItemNode`):
   ```swift
   var avatarView: UIView {
       return self.peerNode.avatarView
   }
   ```
   `ShareControllerNode.swift` (`import ForwardFlow`):
   ```swift
   -    private var peersContentNode: SharePeersContainerNode?
   +    var peersContentNode: SharePeersContainerNode?
   +    var forwardFlowSource: (() -> ForwardFlowSource?)?
   +    var forwardFlowAnimator: ForwardFlowAnimator?
   +    var forwardFlowPending: [() -> Void] = []
   ```
   `ShareController.swift` (`import ForwardFlow`): a public property, handed to the node in
   `loadDisplayNode()` next to `self.controllerNode.completed = self.completed`:
   ```swift
   public var forwardFlowSource: (() -> ForwardFlowSource?)?
   ...
   self.controllerNode.forwardFlowSource = self.forwardFlowSource
   ```
4. **Hook.** In `ShareControllerNode.commitSend(peerId:showNames:silently:)`, run the flow instead of
   the immediate dismissal, and hold the toast and the final dismissal until it ends:
   ```swift
   if !self.fromForeignApp {
   -    self.animateOut(shared: true, completion: {
   -    })
   +    if !self.beginForwardFlow(peerIds: peerIds) {
   +        self.animateOut(shared: true, completion: {
   +        })
   +    }
       self.completed?(peerIds)
       ...
   }
   ...
   if case let .done(correlationIds) = status, !fromForeignApp {
   -    strongSelf.enqueued?(peerIds, correlationIds)
   -    strongSelf.dismiss?(true)
   +    strongSelf.afterForwardFlow {
   +        strongSelf.enqueued?(peerIds, correlationIds)
   +        strongSelf.dismiss?(true)
   +    }
       return
   }
   ```
   The existing `hapticFeedback?.success()` after 0.44 s can stay; with several recipients the light
   impacts from `onTargetAbsorbed` come first.
5. **Source.** In `ChatControllerImpl.openMessageShareMenu(id:)`
   (`ChatControllerOpenMessageShareMenu.swift`), right after `makeShareController(...)`:
   ```swift
   (shareController as? ShareController)?.forwardFlowSource = self.forwardFlowSource(messageId: id)
   ```
   The snapshot is taken lazily, at the moment of sending.
6. **Prewarm (recommended).** The first run compiles the pipeline (~tens of ms). Create one animator
   when the sheet appears and call `prewarm()`, or keep a shared one.

### What the integration does

* Snapshots the message item node with `layer.render(in:)` (only the node's own layers;
  `drawHierarchy` would also capture the dim and the sheet above it).
* Finds the avatars of the selected peers in `peersContentNode.contentGridNode`; the tint is the
  lightened average of the top half of each avatar, so it works for gradient placeholders and photos.
* Adds `meshView` to the window above the sheet, disables touches on the sheet, scales the avatar
  views and draws a ring layer around each one by `ForwardFlowAvatarState`.
* On completion: removes the view and the rings, animates the sheet out, then runs what
  `afterForwardFlow` held (the "Forwarded" toast via `enqueued`, `dismiss`).

### Fallback

`beginForwardFlow` returns false and the sheet dismisses as before when Reduce Motion is on, in
secret chats, when no source was given (sharing links, media from the gallery, other apps) or the
message is off screen, when none of the selected peers is in the grid (picked from search), or when
Metal is unavailable.

## Standalone demo

```sh
Demo/build-demo.sh "iPhone 18 Pro"     # builds with swiftc + metal, installs, launches
xcrun simctl launch --terminate-running-process "iPhone 18 Pro" demo.forwardflow.kit -autoplay YES
```

Tap a message, pick avatars, tap "Send" (or `-autoplay YES` to forward the photo to two chats every
4 s). `FORWARDFLOW_DEBUG_FRAMES=1` in the environment logs frames longer than 25 ms.

## Web prototype

`Prototype/forward-flow.html` opens in any browser with WebGL2. It runs the same timeline and the
same vertex shader (GLSL port of `ForwardFlow.metal`). The panel next to the phone has every
parameter below as a slider, 1× / 0.5× / 0.25× speed and a scrubber over the run.

## Parameters

`ForwardFlowConfig` — defaults are the tuned values from the prototype:

| Parameter | Default | Meaning |
|---|---|---|
| `liftDuration`, `liftScale`, `lean` | 0.14 s, 1.035, 7 pt | Copy peels off the original and leans to its avatar |
| `swallowDuration` | 0.66 s | How long one copy flows |
| `stagger` | 0.07 s | Delay between copies for several recipients |
| `flowRamp`, `flowAccel` | 0.22 s, 3.5 | Smooth start, acceleration over time |
| `pullStrength`, `pullReach` | 4, 2.4 r | Acceleration near the avatar |
| `arcShape` | 1.8 | 1 — straight edges, > 1 — edges wrap the avatar |
| `swirl` | 0.35 rad | Twist of the stream, mirrored for avatars on the left |
| `sinkDepth` | 0.6 r | How deep points go under the avatar edge |
| `fadeOuter`, `fadeInner`, `fadeBlur` | 2.2 r, 0.78 r, 6 pt | Tint, fade and blur near the avatar |
| `gulp`, `bounce`, `settleDuration` | 0.08, 0.16, 0.42 s | Avatar shrink and spring |

`r` is the avatar radius (30 pt in the share sheet, 26 pt when selected: `SelectablePeerNode` scales
a selected avatar to 0.867, and the integration scales on top of that).

## Notes and limits

* Not compiled yet: the Swift and Metal code was written next to the web prototype on Linux, without
  Xcode. Run `Demo/build-demo.sh` first; expect small fixes.
* Snapshots are static: an animated sticker or a video in the bubble is frozen on the first frame.
* A message covered by the sheet (low in the chat) flows from under the sheet's top edge. The
  prototype scrolls the chat so the message stays above the sheet; ShareController does not.
* Albums: the item node of the whole group is used, so the whole album flows.
* `AvatarNode.playRepostAnimation()` already exists in Telegram-iOS; it can be played on landing
  instead of, or together with, the ring.
