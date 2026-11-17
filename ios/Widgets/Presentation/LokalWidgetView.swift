import SwiftUI
import WidgetKit
import UIKit

/// Shared native palette follows the captured Lokal accent and system contrast.
struct LokalWidgetTheme {
  let accent: Color
  let surface = Color(uiColor: .secondarySystemBackground)
  init(argb: Int) {
    let value = argb == 0 ? UInt32(0xFFC8FF57) : UInt32(truncatingIfNeeded: argb)
    accent = Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                   green: Double((value >> 8) & 255) / 255,
                   blue: Double(value & 255) / 255, opacity: 1)
  }
}

func lokalWidgetText(_ key: String) -> String {
  NSLocalizedString(key, comment: "Lokal Home Screen widget")
}

struct LokalWidgetView: View {
  let configuration: LokalWidgetConfiguration
  let model: LokalWidgetPresentation
  let artwork: [String: Data]
  let family: WidgetFamily
  @Environment(\.dynamicTypeSize) private var typeSize

  private var theme: LokalWidgetTheme { LokalWidgetTheme(argb: model.accentArgb) }
  private var small: Bool { family == .systemSmall }
  private var large: Bool { family == .systemLarge }
  private var accessory: Bool {
    family == .accessoryCircular || family == .accessoryInline || family == .accessoryRectangular
  }
  private var current: LokalWidgetTrackPresentation? {
    configuration == .coverFlow ? model.recommendations.first :
      (model.current ?? model.recommendations.first)
  }
  private var ready: Bool { model.availability == .available }
  private func link(_ action: String = "open", track: String? = nil) -> URL {
    LokalWidgetLink.url(action, revision: model.revision,
      updatedAtMs: model.updatedAtMs, track: track ?? model.current?.id)
  }

  var body: some View {
    Group {
      if accessory { accessoryContent }
      else { layout }
    }
    .widgetURL(configuration == .flowRadio && model.availability != .unavailable ? link("flow") : link())
    .modifier(LokalWidgetBackground(accent: theme.accent, surface: theme.surface, accessory: accessory))
  }

  /// Shared with the native image harness; no extension timers or network work.
  var layout: some View {
    ViewThatFits(in: .vertical) {
      content(compact: typeSize.isAccessibilitySize)
        .fixedSize(horizontal: false, vertical: true)
      content(compact: true).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        Text(current.map { title($0) } ?? lokalWidgetText("Your music, one tap away"))
          .font(.headline).lineLimit(1)
        Text(lokalWidgetText("Open Lokal")).font(.caption)
      }
      .accessibilityLabel(Text(summary))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .tint(theme.accent)
  }

  @ViewBuilder private func content(compact: Bool) -> some View {
    if model.availability == .unavailable {
      empty(compact: compact)
    } else if configuration == .coverFlow && !model.recommendations.isEmpty {
      recommendations(compact: compact)
    } else if configuration == .flowRadio {
      flow(compact: compact)
    } else if let track = model.current {
      nowPlaying(track, compact: compact)
    } else {
      empty(compact: compact)
    }
  }

  private var brand: some View {
    HStack(spacing: 5) {
      Image(systemName: "opticaldisc").foregroundStyle(theme.accent)
      Text("LOKAL").tracking(2).fontWeight(.bold)
      Spacer(minLength: 4)
      Text(lokalWidgetText(model.availability == .stale ? "Open Lokal to refresh" : model.isBuffering ? "Buffering" :
        model.isPlaying ? "Now Playing" : "Open Lokal")).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
    }.font(.caption2)
  }

  private func nowPlaying(_ track: LokalWidgetTrackPresentation, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: small ? 5 : 7) {
      if large { brand }
      if small {
        HStack {
          cover(track.artwork ?? model.lastArtwork)
            .frame(width: compact ? 36 : 48, height: compact ? 36 : 48)
          Spacer()
          Image(systemName: model.isPlaying ? "waveform" : "opticaldisc")
            .font(.title2).foregroundStyle(theme.accent)
        }
        metadata(track, compact: compact)
      } else {
        HStack(spacing: 12) {
          if !compact {
            cover(track.artwork ?? model.lastArtwork)
              .frame(width: large ? 120 : 62, height: large ? 120 : 62)
          }
          VStack(alignment: .leading, spacing: 5) {
            if !large { Text(ready ? "LOKAL" : lokalWidgetText("Open Lokal to refresh")).font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(theme.accent) }
            metadata(track, compact: compact)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if !compact && model.durationMs > 0 { progress }
      if small {
        Text(lokalWidgetText(ready ? "Open Lokal" : "Open Lokal to refresh"))
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      } else {
        transport
        if large && !compact && !model.recommendations.isEmpty {
          HStack(spacing: 8) {
            ForEach(model.recommendations.prefix(3)) { item in
              Link(destination: ready ? link("recommend", track: item.id) : link()) {
                HStack(spacing: 5) {
                  cover(item.artwork).frame(width: 32, height: 32)
                  Text(title(item)).font(.caption2).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain)
            }
          }.padding(.top, 4)
        }
      }
    }
  }

  private func metadata(_ track: LokalWidgetTrackPresentation, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title(track)).font(large && !compact ? .title3.bold() : .subheadline.weight(.semibold))
        .lineLimit(compact ? 1 : 2).minimumScaleFactor(0.85)
      Text(track.artist).font(small ? .caption2 : .caption)
        .foregroundStyle(.secondary).lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(title(track) + ", " + track.artist))
  }

  private var progress: some View {
    Group {
      if let interval = model.progressInterval {
        ProgressView(timerInterval: interval, countsDown: false).labelsHidden()
      } else {
        ProgressView(value: Double(model.positionMs), total: Double(max(1, model.durationMs)))
      }
    }.progressViewStyle(.linear).frame(height: 3).clipped()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(lokalWidgetText("Playback progress")))
      .accessibilityValue(progressValue)
  }

  private var progressValue: Text {
    let duration = Duration.seconds(Double(model.durationMs) / 1000).formatted(.time(pattern: .hourMinuteSecond))
    if model.playbackRate == 1, let interval = model.progressInterval {
      return Text("\(Text(timerInterval: interval, countsDown: false)) / \(duration)")
    }
    let position = Duration.seconds(Double(model.positionMs) / 1000).formatted(.time(pattern: .hourMinuteSecond))
    return Text(position + " / " + duration)
  }

  private var transport: some View {
    HStack(spacing: 16) {
      control("previous", symbol: "backward.end.fill", label: "Previous")
      control(model.isPlaying ? "pause" : "play",
        symbol: model.isPlaying ? "pause.fill" : "play.fill",
        label: model.isPlaying ? "Pause" : "Play", prominent: true)
      control("next", symbol: "forward.end.fill", label: "Next")
      Spacer(minLength: 4)
      Link(destination: link("queue")) {
        Image(systemName: "list.bullet").font(.body.weight(.medium))
          .frame(width: 30, height: 30)
      }.accessibilityLabel(Text(lokalWidgetText("Queue")))
    }.buttonStyle(.plain)
  }

  private func control(_ action: String, symbol: String, label: String, prominent: Bool = false) -> some View {
    Link(destination: ready ? link(action) : link()) {
      Image(systemName: symbol).font(.system(size: prominent ? 15 : 14, weight: .semibold))
        .frame(width: prominent ? 38 : 28, height: 30)
        .foregroundStyle(prominent ? Color.primary : Color.secondary)
        .background(prominent ? theme.accent.opacity(0.24) : .clear, in: Capsule())
    }.accessibilityLabel(Text(lokalWidgetText(label)))
  }

  private func flow(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "infinity").font(.title2.weight(.medium)).foregroundStyle(theme.accent)
        Spacer()
        Text("LOKAL").font(.caption2.bold()).tracking(2)
      }
      if let track = current, !compact {
        HStack(spacing: 10) {
          cover(track.artwork).frame(width: small ? 36 : 52, height: small ? 36 : 52)
          metadata(track, compact: small)
        }
      } else {
        Text(lokalWidgetText("Start Flow or radio in Lokal")).font(.headline).lineLimit(2)
      }
      if small {
        Text(lokalWidgetText("Flow")).font(.caption.weight(.semibold))
      } else {
        HStack(spacing: 10) {
          actionPill("Flow", icon: "infinity", destination: link("flow"))
          if model.current != nil {
            actionPill("Song Radio", icon: "dot.radiowaves.left.and.right",
              destination: ready ? link("radio") : link())
          }
        }
      }
      if large && !compact {
        Text(lokalWidgetText("Start Flow or radio in Lokal"))
          .font(.title3.weight(.semibold)).padding(.top, 8)
        Text(model.flowStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
  }

  private func actionPill(_ text: String, icon: String, destination: URL) -> some View {
    Link(destination: destination) {
      Label(lokalWidgetText(text), systemImage: icon)
        .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(theme.accent.opacity(0.15), in: Capsule())
    }.buttonStyle(.plain)
  }

  private func recommendations(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      brand
      if small || compact {
        if let track = model.recommendations.first {
          HStack(spacing: 8) {
            cover(track.artwork).frame(width: compact ? 32 : 44, height: compact ? 32 : 44)
            metadata(track, compact: compact)
          }
        }
      } else {
        HStack(alignment: .top, spacing: 10) {
          ForEach(model.recommendations) { track in
            Link(destination: ready ? link("recommend", track: track.id) : link()) {
              VStack(alignment: .leading, spacing: 5) {
                cover(track.artwork).frame(width: large ? 92 : 56, height: large ? 92 : 56)
                  .rotationEffect(.degrees(track.id == model.recommendations.first?.id ? -3 : 2))
                Text(title(track)).font(.caption.weight(.semibold)).lineLimit(large ? 2 : 1)
                if large { Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
              }.frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
          }
        }
      }
      Text(lokalWidgetText(ready ? "Your Flow" : "Open Lokal to refresh")).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func empty(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !compact {
        Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(theme.accent)
      }
      Text(lokalWidgetText("Your music, one tap away")).font(.headline).lineLimit(3)
      Text(lokalWidgetText("Open Lokal")).font(.caption).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var accessoryContent: some View {
    switch family {
    case .accessoryInline:
      Label(current.map { title($0) } ?? "Lokal", systemImage: model.isPlaying ? "waveform" : "music.note")
    case .accessoryCircular:
      Group {
        if let interval = model.progressInterval {
          ProgressView(timerInterval: interval, countsDown: false) {
            Image(systemName: "waveform")
          } currentValueLabel: {
            Image(systemName: "waveform")
          }.progressViewStyle(.circular)
        } else {
          Gauge(value: Double(model.positionMs), in: 0...Double(max(1, model.durationMs))) {
            Image(systemName: model.isPlaying ? "waveform" : "opticaldisc")
          }.gaugeStyle(.accessoryCircularCapacity)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(summary + ". " + lokalWidgetText("Playback progress")))
      .accessibilityValue(progressValue)
    default:
      HStack(spacing: 8) {
        if let track = current {
          cover(track.artwork).frame(width: 36, height: 36)
          metadata(track, compact: true)
        } else {
          Label(lokalWidgetText("Open Lokal"), systemImage: "music.note")
        }
      }
    }
  }

  @ViewBuilder private func cover(_ name: String?) -> some View {
    if let name, let bytes = artwork[name], let image = UIImage(data: bytes) {
      Image(uiImage: image).resizable().scaledToFill()
        .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    } else {
      RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.14))
        .overlay(Image(systemName: "music.note").foregroundStyle(.primary))
        .accessibilityHidden(true)
    }
  }

  private func title(_ track: LokalWidgetTrackPresentation) -> String {
    track.title.isEmpty ? lokalWidgetText("Unknown track") : track.title
  }
  private var summary: String {
    ([current.map { title($0) + ", " + $0.artist } ?? "Lokal",
      model.isBuffering ? lokalWidgetText("Buffering") : "",
      model.availability == .stale ? lokalWidgetText("Open Lokal to refresh") : ""]
      .filter { !$0.isEmpty }).joined(separator: ". ")
  }
}

struct LokalWidgetSurface: View {
  let accent: Color
  let surface: Color
  var body: some View {
    surface.overlay {
      LinearGradient(colors: [accent.opacity(0.17), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }
}

private struct LokalWidgetBackground: ViewModifier {
  let accent: Color
  let surface: Color
  var accessory = false
  @ViewBuilder func body(content: Content) -> some View {
    if accessory {
      content
    } else if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) {
        LokalWidgetSurface(accent: accent, surface: surface)
      }
    } else {
      content.padding(14).background(LokalWidgetSurface(accent: accent, surface: surface))
    }
  }
}
