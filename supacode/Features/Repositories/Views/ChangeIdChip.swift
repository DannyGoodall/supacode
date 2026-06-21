import SwiftUI

/// jj change-id chip: the shortest-unique prefix (painted with `prefixStyle`)
/// sits a hair apart from the dimmed remainder — jj's own log treatment, with
/// no bold (too heavy at this size). Shared by the sidebar row and the toolbar
/// title so the two stay in lockstep; the caller supplies `prefixStyle` because
/// the emphasis rules differ (a selected sidebar row reverts to the default
/// foreground, the toolbar always uses the row tint).
struct ChangeIdChip: View {
  let changeId: ChangeIdDisplay
  let prefixStyle: AnyShapeStyle

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(changeId.prefix).foregroundStyle(prefixStyle)
      Text(changeId.rest).foregroundStyle(.secondary)
    }
    .font(.system(.footnote, design: .monospaced))
    .lineLimit(1)
  }
}
