/// The panes of the Settings window, in sidebar order.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case sections
    case shortcuts
    case control
    case permissions

    public var id: String { rawValue }

    /// Sidebar label and window title.
    public var title: String {
        switch self {
        case .general: return "General"
        case .sections: return "Sections"
        case .shortcuts: return "Shortcuts"
        case .control: return "Control"
        case .permissions: return "Permissions"
        }
    }

    /// SF Symbol shown next to the title in the sidebar.
    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .sections: return "rectangle.split.3x1"
        case .shortcuts: return "keyboard"
        case .control: return "terminal"
        case .permissions: return "lock.shield"
        }
    }

    /// A pane by its raw value or title, ignoring case and surrounding spaces.
    public init?(name: String) {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let pane = Self.allCases.first(where: { $0.rawValue == wanted || $0.title.lowercased() == wanted }) else { return nil }
        self = pane
    }
}
