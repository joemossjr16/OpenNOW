import Foundation
import CoreGraphics

enum NativeStreamControllerShortcutAction: String, Codable, CaseIterable, Identifiable {
    case none, controls, stats
    var id: String { rawValue }
    var label: String {
        switch self { case .none: return "Unassigned"; case .controls: return "Stream HUD"; case .stats: return "Toggle stats" }
    }
}

struct NativeStreamControllerShortcuts: Codable, Equatable {
    var firstButton = ""
    var secondButton = ""
    var firstAction: NativeStreamControllerShortcutAction = .controls
    var secondAction: NativeStreamControllerShortcutAction = .stats
    func action(for button: String) -> NativeStreamControllerShortcutAction {
        guard !button.isEmpty else { return .none }
        if button == firstButton { return firstAction }
        if button == secondButton { return secondAction }
        return .none
    }
}

enum NativeStreamControllerHUDCommand: Equatable { case up, down, left, right, activate, back }
struct NativeStreamControllerHUDInput: Equatable {
    let id = UUID()
    let command: NativeStreamControllerHUDCommand
}

enum NativeStreamControllerHUDRouting {
    static func direction(x: Float, y: Float) -> NativeStreamControllerHUDCommand? {
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) >= 0.6 else { return nil }
        if abs(y) >= abs(x) { return y > 0 ? .up : .down }
        return x > 0 ? .right : .left
    }
    static func gameState(_ state: NativeStreamGamepadState, captured: Bool) -> NativeStreamGamepadState {
        guard captured, state.connected else { return state }
        return NativeStreamGamepadState(controllerId: state.controllerId, buttons: 0, leftTrigger: 0,
            rightTrigger: 0, leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0, connected: true)
    }
}

enum NativeStreamControllerShortcutCapture { static var learning = false }

#if canImport(GameController)
import GameController

enum NativeStreamControllerButtonNames {
    static func buttons(_ controller: GCController) -> [(String, GCControllerButtonInput)] {
        var seen: Set<ObjectIdentifier> = []
        // Prefer an exposed rear/paddle name when aliases refer to the same input.
        return controller.physicalInputProfile.buttons.sorted {
            func rear(_ name: String) -> Bool { name.lowercased().contains("back") || name.lowercased().contains("paddle") }
            if rear($0.key) != rear($1.key) { return rear($0.key) }
            return $0.key < $1.key
        }.compactMap { name, button in
            guard seen.insert(ObjectIdentifier(button)).inserted else { return nil }
            return (name, button)
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

final class NativeStreamControllerButtonLearner: ObservableObject {
    @Published var status = "Choose Learn, then press a back button."
    @Published var listening = false
    private var restorations: [() -> Void] = []
    private var timeout: Task<Void, Never>?

    func start(_ learned: @escaping (String) -> Void) {
        stop()
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else { status = "Connect the controller first."; return }
        listening = true
        NativeStreamControllerShortcutCapture.learning = true
        status = "Press the back button you want to assign…"
        for controller in controllers {
            controller.handlerQueue = .main
            for (name, button) in NativeStreamControllerButtonNames.buttons(controller) {
                let old = button.pressedChangedHandler
                restorations.append { [weak button] in button?.pressedChangedHandler = old }
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed, let self, self.listening else { return }
                    self.stop()
                    self.status = "Detected: \(name)"
                    learned(name)
                }
            }
        }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self else { return }
            self.stop()
            self.status = "No button detected. If the back button is unassigned in GameSir, map it to an unused input there and try again."
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        restorations.forEach { $0() }; restorations.removeAll()
        listening = false
        NativeStreamControllerShortcutCapture.learning = false
    }
}

struct NativeStreamControllerShortcutsView: View {
    @Binding var settings: AppSettings
    @StateObject private var learner = NativeStreamControllerButtonLearner()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controller Shortcuts").font(.headline)
            shortcut("Back button 1", first: true)
            shortcut("Back button 2", first: false)
            Text(learner.status).font(.footnote).foregroundStyle(.secondary)
            if learner.listening { Button("Cancel Learning") { learner.stop() } }
            Text("If a back button mirrors a front button, this shortcut applies to both. Use an unused input in the GameSir mapping for a dedicated shortcut.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("HUD: D-pad or left stick moves; A selects; B goes back; left/right adjusts sliders.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .onDisappear { learner.stop() }
        .onChange(of: scenePhase) { phase in if phase != .active { learner.stop() } }
    }
    private func shortcut(_ title: String, first: Bool) -> some View {
        let name = first ? settings.controllerShortcuts.firstButton : settings.controllerShortcuts.secondButton
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button("Learn") {
                    learner.start { detected in
                        if first { settings.controllerShortcuts.firstButton = detected }
                        else { settings.controllerShortcuts.secondButton = detected }
                        if first && settings.controllerShortcuts.secondButton == detected { settings.controllerShortcuts.secondButton = "" }
                        if !first && settings.controllerShortcuts.firstButton == detected { settings.controllerShortcuts.firstButton = "" }
                    }
                }.disabled(learner.listening)
                Button("Clear") {
                    if first { settings.controllerShortcuts.firstButton = "" }
                    else { settings.controllerShortcuts.secondButton = "" }
                }.disabled(name.isEmpty || learner.listening)
            }
            Text(name.isEmpty ? "No button assigned" : name).font(.caption).foregroundStyle(.secondary)
            Picker("Action", selection: Binding(get: {
                first ? settings.controllerShortcuts.firstAction : settings.controllerShortcuts.secondAction
            }, set: { action in
                if first { settings.controllerShortcuts.firstAction = action }
                else { settings.controllerShortcuts.secondAction = action }
            })) {
                ForEach(NativeStreamControllerShortcutAction.allCases) { Text($0.label).tag($0) }
            }
        }
    }
}

@MainActor
final class NativeStreamControllerHUDNavigator: ObservableObject {
    struct Control {
        var enabled: Bool
        let activate: () -> Void
        let adjust: ((Double) -> Void)?
    }
    @Published var selected: UUID?
    private var controls: [UUID: Control] = [:]
    private var positions: [UUID: CGRect] = [:]
    func register(_ id: UUID, enabled: Bool, activate: @escaping () -> Void, adjust: ((Double) -> Void)?) {
        controls[id] = Control(enabled: enabled, activate: activate, adjust: adjust)
    }
    func remove(_ id: UUID) {
        controls[id] = nil; positions[id] = nil
        if selected == id { selected = nil }
    }
    func updatePositions(_ next: [UUID: CGRect]) {
        for (id, rect) in next where positions[id] == nil { positions[id] = rect }
    }
    func handle(_ command: NativeStreamControllerHUDCommand) {
        let ordered = controls.keys.filter { controls[$0]?.enabled == true && positions[$0] != nil }.sorted {
            let a = positions[$0]!, b = positions[$1]!
            if abs(a.midY - b.midY) < 8 { return a.midX < b.midX }
            return a.midY < b.midY
        }
        guard !ordered.isEmpty else { return }
        guard let current = selected, let index = ordered.firstIndex(of: current) else { selected = ordered.first; return }
        switch command {
        case .activate: controls[current]?.activate()
        case .left, .right:
            if let adjust = controls[current]?.adjust { adjust(command == .left ? -1 : 1) }
            else { selected = ordered[min(max(index + (command == .left ? -1 : 1), 0), ordered.count - 1)] }
        case .up: selected = ordered[max(index - 1, 0)]
        case .down: selected = ordered[min(index + 1, ordered.count - 1)]
        case .back: break
        }
    }
}

struct NativeStreamHUDPositions: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { _, next in next } }
}
private struct NativeStreamHUDNavigatorKey: EnvironmentKey {
    static let defaultValue: NativeStreamControllerHUDNavigator? = nil
}
extension EnvironmentValues {
    var controllerHUDNavigator: NativeStreamControllerHUDNavigator? {
        get { self[NativeStreamHUDNavigatorKey.self] }
        set { self[NativeStreamHUDNavigatorKey.self] = newValue }
    }
}

private struct NativeStreamHUDControl: ViewModifier {
    @Environment(\.controllerHUDNavigator) private var navigator
    let activate: () -> Void
    var adjust: ((Double) -> Void)?
    func body(content: Content) -> some View {
        if let navigator { content.modifier(NativeStreamActiveHUDControl(navigator: navigator, activate: activate, adjust: adjust)) }
        else { content }
    }
}
private struct NativeStreamActiveHUDControl: ViewModifier {
    @ObservedObject var navigator: NativeStreamControllerHUDNavigator
    @Environment(\.isEnabled) private var enabled
    @State private var id = UUID()
    let activate: () -> Void
    let adjust: ((Double) -> Void)?
    func body(content: Content) -> some View {
        content
            .id(id)
            .background(GeometryReader { proxy in Color.clear.preference(key: NativeStreamHUDPositions.self, value: [id: proxy.frame(in: .global)]) })
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: navigator.selected == id ? 2 : 0).allowsHitTesting(false))
            .onAppear { navigator.register(id, enabled: enabled, activate: activate, adjust: adjust) }
            .onChange(of: enabled) { next in navigator.register(id, enabled: next, activate: activate, adjust: adjust) }
            .onDisappear { navigator.remove(id) }
    }
}
extension View {
    func controllerHUDControl(activate: @escaping () -> Void, adjust: ((Double) -> Void)? = nil) -> some View {
        modifier(NativeStreamHUDControl(activate: activate, adjust: adjust))
    }
}
#endif
