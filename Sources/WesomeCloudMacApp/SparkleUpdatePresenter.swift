import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
public protocol SoftwareUpdatePresenting: AnyObject {
    func checkForUpdates()
}

@MainActor
public final class UnavailableSoftwareUpdatePresenter: SoftwareUpdatePresenting {
    public init() {}

    public func checkForUpdates() {}
}

#if canImport(Sparkle)
@MainActor
public final class SparkleUpdatePresenter: NSObject, SoftwareUpdatePresenting {
    private let updaterController: SPUStandardUpdaterController

    public override init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.isConfigured(),
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    public func checkForUpdates() {
        guard Self.isConfigured() else { return }
        updaterController.checkForUpdates(nil)
    }

    public static func isConfigured(bundle: Bundle = .main) -> Bool {
        guard
            let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !key.contains("$("),
            let data = Data(base64Encoded: key)
        else {
            return false
        }
        return data.count == 32
    }
}
#else
public typealias SparkleUpdatePresenter = UnavailableSoftwareUpdatePresenter
#endif
