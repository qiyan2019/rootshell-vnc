#if canImport(UIKit)
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// 把 `FramebufferMetalPresenter` 接进 SwiftUI。
/// 画面固定铺满视图，缩放平移由着色器处理，所以手势不用重新布局图层。
struct FramebufferMetalContent: UIViewRepresentable {
    let session: VNCSession
    let viewport: RemoteViewportState
    let sourceRegion: CGRect?

    func makeUIView(context: Context) -> FramebufferMetalHostView {
        FramebufferMetalHostView(session: session)
    }

    func updateUIView(_ uiView: FramebufferMetalHostView, context: Context) {
        uiView.update(viewport: viewport, sourceRegion: sourceRegion)
    }

    static func dismantleUIView(_ uiView: FramebufferMetalHostView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
final class FramebufferMetalHostView: UIView {
    /// 所有能跑 iOS 18 的设备和模拟器都有 Metal，这里只防设备创建失败。
    nonisolated static let isAvailable = MTLCreateSystemDefaultDevice() != nil

    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let session: VNCSession
    private var presenter: FramebufferMetalPresenter?
    private var viewportScale: CGFloat = RemoteViewportState.minimumScale
    private var viewportOffset: CGSize = .zero
    private var sourceRegion: CGRect?
    private var isSceneActive = UIApplication.shared.applicationState == .active
    private var observers: [any NSObjectProtocol] = []

    private var metalLayer: CAMetalLayer {
        // `layerClass` 保证了类型。
        layer as! CAMetalLayer
    }

    init(session: VNCSession) {
        self.session = session
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        guard let presenter = FramebufferMetalPresenter() else { return }
        self.presenter = presenter
        presenter.attach(layer: metalLayer)
        session.attachFramebufferPresenter(presenter)
        observeApplicationLifecycle()
        updatePresentationGate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 由 SwiftUI 在拆除视图时调用。之后不再向这个图层画任何东西。
    func detach() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        guard let presenter else { return }
        presenter.setViewPresentationAllowed(false)
        session.detachFramebufferPresenter(presenter)
    }

    func update(viewport: RemoteViewportState, sourceRegion: CGRect?) {
        guard viewport.scale != viewportScale
            || viewport.offset != viewportOffset
            || sourceRegion != self.sourceRegion else { return }
        viewportScale = viewport.scale
        viewportOffset = viewport.offset
        self.sourceRegion = sourceRegion
        pushViewportAndRedraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        updatePresentationGate()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = traitCollection.displayScale
        guard scale > 0, bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        CATransaction.commit()
        pushViewportAndRedraw()
    }

    private func pushViewportAndRedraw() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        presenter?.setViewport(FramebufferViewport(
            viewSize: bounds.size,
            scale: viewportScale,
            offset: viewportOffset,
            sourceRegion: sourceRegion))
        if !VNCPresentationPolicy.isPresentationProhibited() {
            presenter?.requestRedraw()
        }
    }

    /// 和 Ghostty 终端同一个节奏（`GhosttyRuntime.observeLifecycle`）：
    /// 失活那一刻就停，并等 GPU 排空，因为 iOS 在 willResignActive 返回后立刻抓场景快照，
    /// 设备锁屏时还在用 Metal 画会被系统直接杀掉。只在真正激活后恢复：
    /// willEnterForeground 时场景还没 active，控制中心这类临时失活也没有那对通知。
    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        // didEnterBackground 是兜底：不经过失活直接进后台的路径（如后台拉起）。
        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSceneActive = false
                    self?.updatePresentationGate()
                    self?.presenter?.drainToIdle()
                }
            })
        }
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSceneActive = true
                self?.updatePresentationGate()
            }
        })
    }

    private func updatePresentationGate() {
        guard let presenter else { return }
        let allowed = window != nil && isSceneActive
        presenter.setViewPresentationAllowed(allowed)
        if allowed, !VNCPresentationPolicy.isPresentationProhibited() {
            // 解码在失活期间也写内存，回来补一帧。夹具这类静态画面不会有新数据触发重画。
            presenter.requestRedraw()
        }
    }
}
#endif
