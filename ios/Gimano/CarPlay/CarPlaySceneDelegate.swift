import CarPlay
import UIKit

/// The CarPlay navigation scene (docs/driving.md §5). The car screen is a second view of the drive the phone runs:
/// one AppModel, one NavigationSession, one voice.
///
/// The CarPlay navigation entitlement (com.apple.developer.carplay-maps) is not granted yet, so only simulator builds
/// carry it (Config/Signing.xcconfig); on a device this scene is never connected.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        MainActor.assumeIsolated {
            guard let model = AppModel.current else { return }
            let c = CarPlayController(model: model, interface: interfaceController, window: window)
            controller = c
            c.connect()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        MainActor.assumeIsolated {
            controller?.disconnect()
            controller = nil
        }
    }
}
