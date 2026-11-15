import SwiftUI

/// Every menu bar icon, with locked ones showing what earns them.
struct IconCollectionView: View {
    @Environment(RewardStore.self) private var rewards
    var columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(MenuBarIcon.all) { icon in
                IconTile(
                    icon: icon,
                    unlocked: rewards.isUnlocked(icon),
                    selected: rewards.selectedIconID == icon.id,
                    progress: rewards.achievements
                ) {
                    rewards.select(icon)
                }
            }
        }
    }
}

private struct IconTile: View {
    let icon: MenuBarIcon
    let unlocked: Bool
    let selected: Bool
    let progress: AchievementProgress
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 36, height: 30)
                        .foregroundStyle(unlocked ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    if !unlocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 4, y: 2)
                    }
                }
                Text(icon.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(unlocked ? .primary : .secondary)
                if unlocked {
                    Text(selected ? "In menu bar" : "Use")
                        .font(.caption2)
                        .foregroundStyle(selected ? Celebration.accent : .secondary)
                } else {
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Celebration.accent)
                                    .frame(width: proxy.size.width * icon.completion(for: progress))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Celebration.accent : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(unlocked ? icon.requirementText : "\(icon.requirementText) · \(icon.progressText(for: progress))")
        .accessibilityLabel("\(icon.name), \(unlocked ? (selected ? "in use" : "unlocked") : "locked. \(icon.requirementText)")")
    }
}
