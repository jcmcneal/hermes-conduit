import Foundation
import SwiftUI
import UIKit

/// Deterministic original character artwork for profiles.
/// Appearance is derived from the stable profile ID — never `hashValue`,
/// display names, list indices, or runtime session IDs.
struct AgentAvatar: View {
    let profileID: String
    let displayName: String
    let photoURL: URL?
    var size: CGFloat = 40
    var showsSelectionRing: Bool = false

    var body: some View {
        ZStack {
            if let photoURL, let image = cachedImage(at: photoURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                characterArtwork
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(
                    showsSelectionRing ? Color.conduitPrimaryAction : Color.conduitSeparator.opacity(0.55),
                    lineWidth: showsSelectionRing ? max(3.5, size * 0.045) : 1
                )
        }
        .scaleEffect(showsSelectionRing ? 1.04 : 1)
        .accessibilityHidden(true)
    }

    private var characterArtwork: some View {
        let seed = AgentAvatarIdentity.seed(for: profileID)
        let palette = AgentAvatarIdentity.palette(for: seed)
        let accessory = AgentAvatarIdentity.accessory(for: seed)
        return ZStack {
            Circle().fill(palette.background)
            AgentCharacterShape(kind: AgentAvatarIdentity.shape(for: seed))
                .fill(palette.fill)
                .padding(size * 0.08)
            AgentCharacterFace(seed: seed)
                .stroke(palette.face, style: StrokeStyle(lineWidth: max(1.6, size * 0.045), lineCap: .round))
                .padding(size * 0.24)
            AgentCharacterAccessory(kind: accessory)
                .fill(palette.accent)
                .padding(size * 0.06)
        }
        .frame(width: size, height: size)
    }

    private func cachedImage(at url: URL) -> UIImage? {
        AgentAvatarImageCache.shared.image(at: url)
    }
}

enum AgentAvatarIdentity {
    struct Palette {
        let background: Color
        let fill: Color
        let face: Color
        let accent: Color
    }

    /// Stable, process-independent seed from the profile ID.
    static func seed(for profileID: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in profileID.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return hash == 0 ? 1 : hash
    }

    static func shape(for seed: UInt64) -> AgentCharacterKind {
        let kinds = AgentCharacterKind.allCases
        return kinds[Int(seed % UInt64(kinds.count))]
    }

    static func accessory(for seed: UInt64) -> AgentCharacterAccessoryKind {
        let kinds = AgentCharacterAccessoryKind.allCases
        return kinds[Int((seed / 7) % UInt64(kinds.count))]
    }

    static func palette(for seed: UInt64) -> Palette {
        let palettes: [Palette] = [
            Palette(
                background: Color(hex: 0xE8DEFF),
                fill: Color(hex: 0x6B4EFF),
                face: Color(hex: 0x24185C),
                accent: Color(hex: 0xB9A6FF)
            ),
            Palette(
                background: Color(hex: 0xD4E8FF),
                fill: Color(hex: 0x2F6FED),
                face: Color(hex: 0x16357A),
                accent: Color(hex: 0x93C0FF)
            ),
            Palette(
                background: Color(hex: 0xD4F5E2),
                fill: Color(hex: 0x1EAE5A),
                face: Color(hex: 0x0F3F24),
                accent: Color(hex: 0x8DE0B0)
            ),
            Palette(
                background: Color(hex: 0xCCF3EF),
                fill: Color(hex: 0x0FA899),
                face: Color(hex: 0x0C4A45),
                accent: Color(hex: 0x7BDCD2)
            ),
            Palette(
                background: Color(hex: 0xFFE2C8),
                fill: Color(hex: 0xE86A12),
                face: Color(hex: 0x6B2A0A),
                accent: Color(hex: 0xFFC089)
            ),
            Palette(
                background: Color(hex: 0xFFD6E4),
                fill: Color(hex: 0xE11D48),
                face: Color(hex: 0x6F1230),
                accent: Color(hex: 0xFF9BB8)
            ),
        ]
        return palettes[Int(seed % UInt64(palettes.count))]
    }
}

enum AgentCharacterKind: CaseIterable {
    case roundBlob
    case tallOval
    case softSquare
    case diamond
    case bean
    case petal
}

enum AgentCharacterAccessoryKind: CaseIterable {
    case none
    case ear
    case hat
    case cheekDot
}

private struct AgentCharacterShape: Shape {
    let kind: AgentCharacterKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .roundBlob:
            path.addEllipse(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
        case .tallOval:
            path.addEllipse(in: CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY,
                width: rect.width * 0.76,
                height: rect.height
            ))
        case .softSquare:
            path.addRoundedRect(
                in: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04),
                cornerSize: CGSize(width: rect.width * 0.32, height: rect.height * 0.32)
            )
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.02))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.02))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.midY))
            path.closeSubpath()
        case .bean:
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.12))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.28),
                control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.08)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY - rect.height * 0.12),
                control: CGPoint(x: rect.maxX + rect.width * 0.08, y: rect.midY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.16),
                control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.1)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.12),
                control: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.midY)
            )
        case .petal:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.midY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.midX, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        return path
    }
}

private struct AgentCharacterFace: Shape {
    let seed: UInt64

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let eyeY = rect.minY + rect.height * 0.36
        let eyeSpread = rect.width * 0.2
        let eyeRadius = max(1.6, rect.width * 0.07)
        path.addEllipse(in: CGRect(
            x: rect.midX - eyeSpread - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        path.addEllipse(in: CGRect(
            x: rect.midX + eyeSpread - eyeRadius,
            y: eyeY - eyeRadius,
            width: eyeRadius * 2,
            height: eyeRadius * 2
        ))
        let smileY = rect.minY + rect.height * 0.62
        let smileWidth = rect.width * (seed.isMultiple(of: 2) ? 0.3 : 0.24)
        path.move(to: CGPoint(x: rect.midX - smileWidth, y: smileY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + smileWidth, y: smileY),
            control: CGPoint(x: rect.midX, y: smileY + rect.height * 0.16)
        )
        return path
    }
}

private struct AgentCharacterAccessory: Shape {
    let kind: AgentCharacterAccessoryKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .none:
            break
        case .ear:
            let ear = CGRect(
                x: rect.maxX - rect.width * 0.28,
                y: rect.minY + rect.height * 0.18,
                width: rect.width * 0.22,
                height: rect.height * 0.28
            )
            path.addEllipse(in: ear)
        case .hat:
            let brim = CGRect(
                x: rect.minX + rect.width * 0.12,
                y: rect.minY + rect.height * 0.08,
                width: rect.width * 0.76,
                height: rect.height * 0.1
            )
            path.addRoundedRect(in: brim, cornerSize: CGSize(width: brim.height * 0.4, height: brim.height * 0.4))
            let crown = CGRect(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY,
                width: rect.width * 0.44,
                height: rect.height * 0.16
            )
            path.addRoundedRect(in: crown, cornerSize: CGSize(width: crown.width * 0.2, height: crown.height * 0.35))
        case .cheekDot:
            let dotRadius = max(2, rect.width * 0.055)
            path.addEllipse(in: CGRect(
                x: rect.midX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.52,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }
        return path
    }
}

/// Avoids re-decoding profile photos on every streaming publish.
enum AgentAvatarImageCache {
    static let shared = AgentAvatarImageCacheBox()
}

final class AgentAvatarImageCacheBox {
    private var cache: [URL: UIImage] = [:]
    private let lock = NSLock()

    func image(at url: URL) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url] { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[url] = image
        return image
    }

    func invalidate(url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
