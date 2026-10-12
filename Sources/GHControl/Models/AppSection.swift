import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case tuning
    case profiles
    case driver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .tuning: "功耗调节"
        case .profiles: "配置方案"
        case .driver: "驱动连接"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tuning: "bolt.horizontal.circle.fill"
        case .profiles: "square.stack.3d.up"
        case .driver: "point.3.connected.trianglepath.dotted"
        }
    }
}
