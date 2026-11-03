import CoreGraphics

/// 触摸滚动的调参集合。所有速度、距离都以「屏幕单位」表达
/// （iOS 是 pt，Android 是 dp），两端常量数值保持一致。
///
/// 远端点：Apple 服务端是 macOS 的 point；非 Apple 服务端就是帧缓冲像素。
/// `s` = 屏幕单位 / 远端点 = 视口缩放（屏幕单位 / 帧缓冲像素）
/// × `remotePixelsPerPoint`（帧缓冲像素 / 远端点）。
public struct RemoteScrollTuning: Sendable, Equatable {
    /// 速度增益分段的下门槛：|v| ≤ vLo 时增益为 1。
    public var vLo: CGFloat
    /// 速度增益分段的上门槛：vLo…vHi 之间线性升到 gMax。
    public var vHi: CGFloat
    /// 速度增益上限。
    public var gMax: CGFloat
    /// 缩放补偿 clamp 下界（调参边界，不是兜底）。
    public var zoomGainMin: CGFloat
    /// 缩放补偿 clamp 上界。
    public var zoomGainMax: CGFloat
    /// 横向锁定时的增益下限。
    public var horizontalMinGain: CGFloat
    /// 进入惯性的最小屏幕速度。
    public var flingMinSpeed: CGFloat
    /// 惯性初速的屏幕速度上限。
    public var flingMaxSpeed: CGFloat
    /// 惯性停止阈值：远端速度 × s 小于它即停。
    public var stopSpeed: CGFloat
    /// 连续甩叠加：按下到抬手的允许窗口（秒）。
    public var stackWindow: CFTimeInterval
    /// 连续甩叠加：剩余速度计入系数。
    public var stackFactor: CGFloat
    /// 宿主覆盖的 P（帧缓冲像素 / 远端 point）。nil 表示按探测结果取。
    public var remotePixelsPerPoint: CGFloat?

    public init(
        vLo: CGFloat = 400,
        vHi: CGFloat = 2_500,
        gMax: CGFloat = 2.5,
        zoomGainMin: CGFloat = 0.25,
        zoomGainMax: CGFloat = 8,
        horizontalMinGain: CGFloat = 2,
        flingMinSpeed: CGFloat = 25,
        flingMaxSpeed: CGFloat = 12_000,
        stopSpeed: CGFloat = 5,
        stackWindow: CFTimeInterval = 0.8,
        stackFactor: CGFloat = 1,
        remotePixelsPerPoint: CGFloat? = nil
    ) {
        self.vLo = vLo
        self.vHi = vHi
        self.gMax = gMax
        self.zoomGainMin = zoomGainMin
        self.zoomGainMax = zoomGainMax
        self.horizontalMinGain = horizontalMinGain
        self.flingMinSpeed = flingMinSpeed
        self.flingMaxSpeed = flingMaxSpeed
        self.stopSpeed = stopSpeed
        self.stackWindow = stackWindow
        self.stackFactor = stackFactor
        self.remotePixelsPerPoint = remotePixelsPerPoint
    }

    public static let `default` = RemoteScrollTuning()
}

/// 滚动增益的纯函数集合，不依赖 UIKit，macOS / Linux 均可测。
public enum ScrollGain {
    /// G_speed：|v| ≤ vLo → 1；vLo…vHi 线性升到 gMax；≥ vHi → gMax。
    public static func speedGain(
        forScreenSpeed speed: CGFloat,
        tuning: RemoteScrollTuning = .default
    ) -> CGFloat {
        let v = abs(speed)
        if v <= tuning.vLo { return 1 }
        if v >= tuning.vHi { return tuning.gMax }
        let t = (v - tuning.vLo) / (tuning.vHi - tuning.vLo)
        return 1 + t * (tuning.gMax - 1)
    }

    /// 缩放补偿：clamp(1/s, zoomGainMin, zoomGainMax)。
    /// s ≤ 0 只在无帧缓冲时出现，此时不产生滚动事件，自然落到上限。
    public static func zoomGain(
        s: CGFloat,
        tuning: RemoteScrollTuning = .default
    ) -> CGFloat {
        min(max(1 / s, tuning.zoomGainMin), tuning.zoomGainMax)
    }

    /// 拖动样本的倍率。
    /// - 竖向 / 不锁定：`zoomGain × speedGain(|v|)`。
    /// - 横向锁定：`max(horizontalMinGain, zoomGain)`，不乘 G_speed。
    public static func dragGain(
        screenSpeed: CGFloat,
        s: CGFloat,
        horizontallyLocked: Bool,
        tuning: RemoteScrollTuning = .default
    ) -> CGFloat {
        let zoom = zoomGain(s: s, tuning: tuning)
        if horizontallyLocked {
            return max(tuning.horizontalMinGain, zoom)
        }
        return zoom * speedGain(forScreenSpeed: screenSpeed, tuning: tuning)
    }

    /// 惯性初速（屏幕单位）。门槛与上限都先按屏幕速度判断；
    /// 返回的 gain 把屏幕初速换算成远端初速（= zoomGain × speedGain(|v释放|)）。
    /// |v释放| < flingMinSpeed 时返回 nil（不进惯性）。
    public static func momentumInitialVelocity(
        releaseVelocity: CGPoint,
        s: CGFloat,
        horizontallyLocked: Bool,
        tuning: RemoteScrollTuning = .default
    ) -> (screenVelocity: CGPoint, gain: CGFloat)? {
        let releaseSpeed = hypot(releaseVelocity.x, releaseVelocity.y)
        guard releaseSpeed >= tuning.flingMinSpeed else { return nil }
        // 横向锁定时只保留 x 分量，与拖动路径的过滤器行为一致
        var velocity = horizontallyLocked
            ? CGPoint(x: releaseVelocity.x, y: 0)
            : releaseVelocity
        let magnitude = hypot(velocity.x, velocity.y)
        if magnitude > tuning.flingMaxSpeed {
            let ratio = tuning.flingMaxSpeed / magnitude
            velocity = CGPoint(
                x: velocity.x * ratio, y: velocity.y * ratio)
        }
        let gain = zoomGain(s: s, tuning: tuning)
            * speedGain(forScreenSpeed: releaseSpeed, tuning: tuning)
        return (velocity, gain)
    }

    /// 惯性停止判断：远端速度 × s < stopSpeed。
    public static func shouldStopMomentum(
        remoteSpeed: CGFloat,
        s: CGFloat,
        tuning: RemoteScrollTuning = .default
    ) -> Bool {
        remoteSpeed * s < tuning.stopSpeed
    }

    /// 惯性单步衰减：UIScrollView.DecelerationRate.normal，每毫秒 0.998。
    /// 两条路径共用——衰减本身与增益无关，只作用在已发出的单位速度上。
    public static func decayedMomentumVelocity(
        _ velocity: CGPoint,
        elapsed: CFTimeInterval
    ) -> CGPoint {
        let decay = pow(0.998 as CGFloat, elapsed * 1_000)
        return CGPoint(x: velocity.x * decay, y: velocity.y * decay)
    }

    /// 解析 P：宿主覆盖 > 本连接走 Apple 精确滚动（0x17）时为 2 > 否则 1。
    /// 0x17 的 pointDelta 是 macOS point，这类连接的帧缓冲通常按
    /// Retina 2× 上报；非 HiDPI 外接屏 1:1 时增益会大一倍，用覆盖修正。
    /// `usesApplePreciseScroll` 必须来自
    /// `VNCSession.usesApplePreciseScroll`（与
    /// `TransportSession.shouldUseApplePreciseInput` 同一谓词）。
    public static func resolvedRemotePixelsPerPoint(
        override: CGFloat?,
        usesApplePreciseScroll: Bool
    ) -> CGFloat {
        override ?? (usesApplePreciseScroll ? 2 : 1)
    }
}

/// 连续甩叠加（计划 §2.3）：
/// 惯性中被按下时记录剩余屏幕速度和时刻；下一次抬手同时满足
/// 同向（点积 > 0）、间隔 ≤ stackWindow、释放速度 ≥ flingMinSpeed
/// 三个条件时，用 `释放 + stackFactor × 剩余` 作新初速（调用即消耗记录）。
public struct FlickStacker: Sendable, Equatable {
    public private(set) var caughtVelocity = CGPoint.zero
    public private(set) var caughtTimestamp: CFTimeInterval = 0
    private var hasCatch = false

    public init() {}

    public mutating func recordCatch(velocity: CGPoint, at timestamp: CFTimeInterval) {
        hasCatch = true
        caughtVelocity = velocity
        caughtTimestamp = timestamp
    }

    public mutating func reset() {
        hasCatch = false
        caughtVelocity = .zero
        caughtTimestamp = 0
    }

    /// 求值并消耗记录：满足叠加条件返回叠加值，否则原样返回释放速度。
    public mutating func stackedReleaseVelocity(
        _ releaseVelocity: CGPoint,
        at timestamp: CFTimeInterval,
        tuning: RemoteScrollTuning = .default
    ) -> CGPoint {
        defer { hasCatch = false }
        guard hasCatch,
              timestamp - caughtTimestamp <= tuning.stackWindow,
              releaseVelocity.x * caughtVelocity.x
                + releaseVelocity.y * caughtVelocity.y > 0,
              hypot(releaseVelocity.x, releaseVelocity.y)
                >= tuning.flingMinSpeed
        else { return releaseVelocity }
        return CGPoint(
            x: releaseVelocity.x + caughtVelocity.x * tuning.stackFactor,
            y: releaseVelocity.y + caughtVelocity.y * tuning.stackFactor)
    }
}
