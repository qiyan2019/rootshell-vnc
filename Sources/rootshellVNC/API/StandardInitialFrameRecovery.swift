import Foundation

/// 首帧底图恢复的判定（纯逻辑，Agito）。
///
/// DCT 首帧门要等 type-0 把整张画面盖满才呈现。刚冷启动的 screensharingd 偶尔不回应
/// 订阅激活时那条非增量整帧请求，之后只推变化区域，首帧门就永远等不到整屏覆盖：
/// 数据一直在进、画面一直不出，只能手动重连
/// （Agito `docs/plan/2026-11-04-iOS屏幕共享首帧卡在正在接收画面排查.md`）。
///
/// 每个检查拍比较一次「未覆盖面积、已应用的像素批次、入站字节」：
/// - 面积在缩小：底图在来，不动。
/// - 有批次应用了但面积没缩小：到的只是变化区域，整帧请求丢了。
/// - 连续几拍一个字节都没进来：请求丢了。
/// - 只有字节在进、没有批次应用：一条大的整帧消息还在路上，不补，免得慢网下叠加整帧请求。
/// 判定请求丢了就补发整帧请求，两次补发之间按退避间隔隔开，总次数有上限。
/// 等满放行时限且已经有像素到过，就先显示已收到的部分；补发照常继续，直到盖满。
struct StandardInitialFrameRecoveryPolicy {
    /// 一个检查拍的观测值。
    struct Sample: Equatable {
        var nanos: UInt64
        var uncoveredArea: Double
        /// 本代帧缓冲已应用的像素批次数（单调递增）。
        var appliedPixelBatches: UInt64
        /// 控制通道累计入站字节（读到即计，单调递增）。
        var receivedBytes: UInt64
    }

    struct Decision: Equatable {
        var renew = false
        var presentPartial = false
        /// 这一拍刚达到补发上限（只报一次，用于诊断）。
        var reachedRenewalLimit = false
        var batchesSinceLastCheck: UInt64 = 0
        var bytesSinceLastCheck: UInt64 = 0
    }

    static let checkIntervalNanos: UInt64 = 1_000_000_000
    /// 第 n 次补发距上次请求至少隔多久；超出数组的按最后一项。
    /// 热的 screensharingd 在 0.3 秒内就发完整帧，2 秒没盖满已经很可疑。
    static let renewalBackoffNanos: [UInt64] = [
        2_000_000_000, 4_000_000_000, 8_000_000_000,
    ]
    static let maximumRenewals = 6
    /// 连续几拍零字节算请求丢了。
    static let deadAirChecks = 3
    /// 多久还没盖满就先显示已收到的部分。
    static let partialPresentationDelayNanos: UInt64 = 10_000_000_000

    private(set) var renewals = 0
    private(set) var presentedPartial = false
    let startNanos: UInt64
    private var lastRequestNanos: UInt64
    private var previous: Sample?
    private var deadAirCount = 0

    /// - Parameter startNanos: 首帧门开始等待的时间，近似订阅激活时那条整帧请求发出的时间。
    init(startNanos: UInt64) {
        self.startNanos = startNanos
        self.lastRequestNanos = startNanos
    }

    mutating func evaluate(_ sample: Sample) -> Decision {
        var decision = Decision()
        if let previous {
            let batches = sample.appliedPixelBatches &- previous.appliedPixelBatches
            let bytes = sample.receivedBytes &- previous.receivedBytes
            decision.batchesSinceLastCheck = batches
            decision.bytesSinceLastCheck = bytes
            deadAirCount = bytes == 0 ? deadAirCount + 1 : 0
            let progressed = sample.uncoveredArea < previous.uncoveredArea
            let requestLost = !progressed
                && (batches > 0 || deadAirCount >= Self.deadAirChecks)
            if requestLost, renewals < Self.maximumRenewals,
               sample.nanos &- lastRequestNanos >= Self.backoff(afterRenewals: renewals) {
                renewals += 1
                lastRequestNanos = sample.nanos
                deadAirCount = 0
                decision.renew = true
                decision.reachedRenewalLimit = renewals == Self.maximumRenewals
            }
        }
        previous = sample
        if !presentedPartial,
           sample.appliedPixelBatches > 0,
           sample.nanos &- startNanos >= Self.partialPresentationDelayNanos {
            presentedPartial = true
            decision.presentPartial = true
        }
        return decision
    }

    static func backoff(afterRenewals renewals: Int) -> UInt64 {
        renewalBackoffNanos[min(renewals, renewalBackoffNanos.count - 1)]
    }
}
