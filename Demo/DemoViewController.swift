// ForwardFlow — minimal UIKit demo of the integration (not needed in Telegram-iOS).
// A fake chat and a fake share sheet with a grid of avatars. Shows the exact calls the host makes:
// snapshot → avatar targets → start → avatar scale/ripple by state → dismiss the sheet and show the toast.

import UIKit

final class DemoViewController: UIViewController {
    private let wallpaper = UIImageView()
    private let content = UIView()
    private let dim = UIView()
    private let sheet = UIView()
    private let sheetTitle = UILabel()
    private let sendButton = UIButton(type: .system)
    private let toast = UILabel()
    private var bubbles: [UIView] = []
    private var cells: [DemoPeerCell] = []
    private var source: UIView?
    private var sheetShown = false
    private var animator: ForwardFlowAnimator?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let sheetHeight: CGFloat = 330
    private static let dimAlpha: CGFloat = 0.4

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        wallpaper.contentMode = .scaleAspectFill
        view.addSubview(wallpaper)
        view.addSubview(content)
        makeBubbles()

        dim.backgroundColor = UIColor(white: 0, alpha: Self.dimAlpha)
        dim.alpha = 0
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeSheet)))
        view.addSubview(dim)

        sheet.backgroundColor = .systemBackground
        sheet.layer.cornerRadius = 14
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetTitle.text = "Forward"
        sheetTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        sheetTitle.textAlignment = .center
        sheet.addSubview(sheetTitle)
        let peers: [(String, String, UIColor, UIColor)] = [
            ("Saved Messages", "SM", Self.rgb(0x72D5FD), Self.rgb(0x2A9EF1)), ("Design Team", "DT", Self.rgb(0xA0DE7E), Self.rgb(0x54CB68)),
            ("Timur", "T", Self.rgb(0xFFCD6A), Self.rgb(0xFFA85C)), ("Lena Kim", "LK", Self.rgb(0xE0A2F3), Self.rgb(0xD669ED)),
            ("Mom", "M", Self.rgb(0xFF885E), Self.rgb(0xFF516A)), ("Work", "W", Self.rgb(0x53EDD6), Self.rgb(0x28C9B7)),
            ("Dima", "D", Self.rgb(0x82B1FF), Self.rgb(0x665FFF)), ("Kira", "K", Self.rgb(0xFF8AAC), Self.rgb(0xF5598B)),
        ]
        for (name, initials, light, dark) in peers {
            let cell = DemoPeerCell(name: name, initials: initials, light: light, dark: dark)
            cell.onToggle = { [weak self] in self?.updateSendButton() }
            sheet.addSubview(cell)
            cells.append(cell)
        }
        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        sendButton.backgroundColor = .systemBlue
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 12
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sheet.addSubview(sendButton)
        view.addSubview(sheet)

        animator = ForwardFlowAnimator()
        if let animator {
            // Order: chat < dim < sheet < mesh < toast. The copies flow over the sheet into the avatars.
            view.addSubview(animator.meshView)
        }

        toast.font = .systemFont(ofSize: 14)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.backgroundColor = UIColor(white: 0.11, alpha: 0.92)
        toast.layer.cornerRadius = 14
        toast.layer.masksToBounds = true
        toast.alpha = 0
        view.addSubview(toast)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animator?.prewarm()
        // -autoplay YES: forward the photo to two chats by itself every 4 s (for recording).
        if UserDefaults.standard.bool(forKey: "autoplay") {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.autoplay() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.autoplay() }
        }
    }

    private func autoplay() {
        guard animator?.isRunning != true, bubbles.count > 1 else { return }
        openSheet(for: bubbles[1])
        cells.enumerated().forEach { index, cell in cell.setChosen(index == 1 || index == 2, animated: true) }
        updateSendButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.send() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        wallpaper.frame = bounds
        // content may carry the shift transform: set bounds and center, not frame.
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dim.frame = bounds
        if wallpaper.image?.size != bounds.size { wallpaper.image = Self.wallpaperImage(size: bounds.size) }
        // The mesh view covers the whole screen, aligned with window coordinates.
        animator?.meshView.frame = bounds
        layoutBubbles()

        let bottom = view.safeAreaInsets.bottom
        let height = Self.sheetHeight + bottom
        sheet.frame = CGRect(x: 0, y: sheetShown ? bounds.height - height : bounds.height, width: bounds.width, height: height)
        sheetTitle.frame = CGRect(x: 0, y: 14, width: bounds.width, height: 24)
        let cellWidth = bounds.width / 4
        for (index, cell) in cells.enumerated() {
            cell.frame = CGRect(x: CGFloat(index % 4) * cellWidth, y: 54 + CGFloat(index / 4) * 104, width: cellWidth, height: 96)
        }
        sendButton.frame = CGRect(x: 16, y: Self.sheetHeight - 64, width: bounds.width - 32, height: 50)
        toast.frame = CGRect(x: 12, y: bounds.height - bottom - 70, width: bounds.width - 24, height: 44)
    }

    private func makeBubbles() {
        let texts: [(String, Bool, Bool)] = [
            ("Hi! Saw the forwarding prototype, looks alive.", false, false), ("Color reference for the screen background", false, true),
            ("Nice, forwarding it to the design team", true, false), ("Check it at 0.25×: you can see the bubble stretch into the avatar.", false, false),
        ]
        for (text, outgoing, photo) in texts {
            let bubble = UIView()
            bubble.backgroundColor = outgoing ? UIColor(red: 0.88, green: 1.0, blue: 0.78, alpha: 1) : .white
            bubble.layer.cornerRadius = 17
            bubble.layer.masksToBounds = true
            if photo {
                let image = UIImageView(image: Self.photoImage(size: CGSize(width: 260, height: 172)))
                image.tag = 2
                bubble.addSubview(image)
            }
            let label = UILabel()
            label.text = text
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 17)
            label.textColor = .black
            label.tag = outgoing ? 1 : 0
            bubble.addSubview(label)
            bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped(_:))))
            content.addSubview(bubble)
            bubbles.append(bubble)
        }
    }

    private func layoutBubbles() {
        let width = view.bounds.width
        var y = view.safeAreaInsets.top + 24
        for bubble in bubbles {
            guard let label = bubble.subviews.compactMap({ $0 as? UILabel }).first else { continue }
            let photo = bubble.viewWithTag(2)
            let textWidth = photo != nil ? 236 : width * 0.7
            let size = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            let photoHeight: CGFloat = photo != nil ? 172 : 0
            let bubbleWidth = photo != nil ? 264 : size.width + 28
            let frame = CGRect(x: label.tag == 1 ? width - bubbleWidth - 12 : 12, y: y, width: bubbleWidth, height: photoHeight + size.height + 16)
            bubble.frame = frame
            photo?.frame = CGRect(x: 2, y: 2, width: bubbleWidth - 4, height: photoHeight - 2)
            label.frame = CGRect(x: 14, y: photoHeight + 8, width: size.width, height: size.height)
            y = frame.maxY + 8
        }
    }

    @objc private func bubbleTapped(_ gesture: UITapGestureRecognizer) {
        guard let bubble = gesture.view, animator?.isRunning != true else { return }
        openSheet(for: bubble)
    }

    private func openSheet(for bubble: UIView) {
        source = bubble
        sheetShown = true
        // Keep the forwarded message visible above the sheet.
        let sheetTop = view.bounds.height - Self.sheetHeight - view.safeAreaInsets.bottom
        let shift = max(0, bubble.frame.maxY - (sheetTop - 14))
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.dim.alpha = 1
            self.content.transform = CGAffineTransform(translationX: 0, y: -shift)
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        updateSendButton()
    }

    @objc private func closeSheet() {
        guard animator?.isRunning != true else { return }
        sheetShown = false
        UIView.animate(withDuration: 0.3) {
            self.dim.alpha = 0
            self.content.transform = .identity
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        cells.forEach { $0.setChosen(false, animated: false) }
        sheet.isUserInteractionEnabled = true
    }

    private func updateSendButton() {
        let count = cells.filter(\.isChosen).count
        sendButton.isEnabled = count > 0
        sendButton.alpha = count > 0 ? 1 : 0.4
    }

    @objc private func send() {
        guard let animator, !animator.isRunning, let source, let window = view.window else { return }
        let chosen = cells.filter(\.isChosen)
        // 1. Snapshot of the message in window coordinates. It sits under the dim: pass its strength.
        guard !chosen.isEmpty, let image = Self.snapshot(source) else { return }
        let flowSource = ForwardFlowSource(frame: source.convert(source.bounds, to: window), image: image, dimmed: Double(Self.dimAlpha))
        // 2. Avatars in window coordinates, with the light end of their gradient as the tint.
        let targets = chosen.enumerated().map { index, cell -> ForwardFlowTarget in
            let frame = cell.avatar.convert(cell.avatar.bounds, to: window)
            return ForwardFlowTarget(id: index, center: CGPoint(x: frame.midX, y: frame.midY), radius: frame.width / 2, tint: cell.tint)
        }
        // 3. Avatars follow the animator; the sheet waits for the last one.
        sheet.isUserInteractionEnabled = false
        haptic.prepare()
        animator.onUpdate = { states in
            for (state, cell) in zip(states, chosen) { cell.apply(state) }
        }
        animator.onTargetAbsorbed = { [weak self] _ in self?.haptic.impactOccurred() }
        animator.onCompletion = { [weak self] in
            guard let self else { return }
            self.closeSheet()
            self.showToast(names: chosen.map(\.name))
        }
        animator.start(source: flowSource, targets: targets)
    }

    private func showToast(names: [String]) {
        toast.text = "Message forwarded to " + names.joined(separator: ", ")
        UIView.animate(withDuration: 0.25) { self.toast.alpha = 1 }
        UIView.animate(withDuration: 0.25, delay: 2.2, options: []) { self.toast.alpha = 0 }
    }

    private static func snapshot(_ view: UIView) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        // layer.render — only this view's own layer tree; drawHierarchy would capture the dim above it.
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage
    }

    private static func rgb(_ hex: Int) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func photoImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let colors = [rgb(0x2C3A6B).cgColor, rgb(0xC0587A).cgColor, rgb(0xF08A4B).cgColor, rgb(0xF7C178).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.45, 0.72, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            rgb(0xFFE3A3).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.66 - 22, y: size.height * 0.66 - 22, width: 44, height: 44)).fill()
            rgb(0x2A1A33).setFill()
            let hills = UIBezierPath()
            hills.move(to: CGPoint(x: 0, y: size.height * 0.8))
            hills.addCurve(to: CGPoint(x: size.width, y: size.height * 0.76),
                           controlPoint1: CGPoint(x: size.width * 0.3, y: size.height * 0.62), controlPoint2: CGPoint(x: size.width * 0.6, y: size.height * 0.95))
            hills.addLine(to: CGPoint(x: size.width, y: size.height))
            hills.addLine(to: CGPoint(x: 0, y: size.height))
            hills.fill()
        }
    }

    private static func wallpaperImage(size: CGSize) -> UIImage? {
        guard size.width > 0 else { return nil }
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.85, green: 0.89, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.53, green: 0.72, blue: 0.52, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}

/// One avatar in the fake share sheet: gradient circle, selection ring, check, ripple and name.
final class DemoPeerCell: UIView {
    let name: String
    let avatar = UIView()
    let tint: (red: Double, green: Double, blue: Double)
    var onToggle: (() -> Void)?
    private(set) var isChosen = false
    private let wrap = UIView()
    private let ring = CAShapeLayer()
    private let ripple = CAShapeLayer()
    private let check = UIView()
    private let label = UILabel()

    init(name: String, initials: String, light: UIColor, dark: UIColor) {
        self.name = name
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        light.getRed(&r, green: &g, blue: &b, alpha: nil)
        tint = (Double(r), Double(g), Double(b))
        super.init(frame: .zero)

        wrap.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        addSubview(wrap)
        ring.path = UIBezierPath(ovalIn: wrap.bounds.insetBy(dx: 1, dy: 1)).cgPath
        ring.fillColor = nil
        ring.strokeColor = UIColor.systemBlue.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        wrap.layer.addSublayer(ring)

        avatar.frame = wrap.bounds.insetBy(dx: 2, dy: 2)
        avatar.layer.cornerRadius = 30
        avatar.layer.masksToBounds = true
        let gradient = CAGradientLayer()
        gradient.frame = avatar.bounds
        gradient.colors = [light.cgColor, dark.cgColor]
        avatar.layer.addSublayer(gradient)
        let initialsLabel = UILabel(frame: avatar.bounds)
        initialsLabel.text = initials
        initialsLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        avatar.addSubview(initialsLabel)
        wrap.addSubview(avatar)

        ripple.path = UIBezierPath(ovalIn: avatar.frame).cgPath
        ripple.fillColor = nil
        ripple.strokeColor = light.cgColor
        ripple.lineWidth = 3
        ripple.opacity = 0
        ripple.frame = wrap.bounds
        wrap.layer.addSublayer(ripple)

        check.frame = CGRect(x: 43, y: 43, width: 22, height: 22)
        check.backgroundColor = .systemBlue
        check.layer.cornerRadius = 11
        check.layer.borderWidth = 2
        check.layer.borderColor = UIColor.systemBackground.cgColor
        check.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        wrap.addSubview(check)

        label.text = name
        label.font = .systemFont(ofSize: 12)
        label.textAlignment = .center
        label.numberOfLines = 2
        addSubview(label)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        wrap.center = CGPoint(x: bounds.midX, y: 32)
        label.frame = CGRect(x: 2, y: 68, width: bounds.width - 4, height: 30)
    }

    @objc private func tapped() {
        setChosen(!isChosen, animated: true)
        onToggle?()
    }

    func setChosen(_ chosen: Bool, animated: Bool) {
        isChosen = chosen
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.avatar.transform = chosen ? CGAffineTransform(scaleX: 0.84, y: 0.84) : .identity
            self.check.transform = chosen ? .identity : CGAffineTransform(scaleX: 0.01, y: 0.01)
        }
        ring.opacity = chosen ? 1 : 0
    }

    /// The animator's state for this avatar: scale of the whole avatar and the ring after landing.
    func apply(_ state: ForwardFlowAvatarState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wrap.transform = CGAffineTransform(scaleX: state.scale, y: state.scale)
        ripple.transform = CATransform3DMakeScale(state.rippleScale, state.rippleScale, 1)
        ripple.opacity = Float(state.rippleAlpha)
        CATransaction.commit()
    }
}

@main
final class DemoAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DemoSceneDelegate.self
        return configuration
    }
}

final class DemoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = DemoViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
