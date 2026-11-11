// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Agents tab in the menu panel: each agent's plan limits and today's use,
/// from the same service and readings as the island's AI page.
struct AgentsSection: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var usage = AgentUsageService.shared
    @AppStorage(DefaultsKey.notchAgentsLimitDisplay) private var display = NotchAgentLimitDisplay.remaining.rawValue
    @AppStorage(DefaultsKey.notchAgentsClaude) private var claude = true
    @AppStorage(DefaultsKey.notchAgentsCodex) private var codex = true
    @AppStorage(DefaultsKey.notchAgentsOpenCode) private var opencode = true
    @AppStorage(DefaultsKey.notchAgentsCopilot) private var copilot = true
    var collapsible = true

    private var text: NotchAgentStrings { FeatureStrings.notchAgents(l10n.language) }

    private var providers: [AgentProvider] {
        [claude ? AgentProvider.claude : nil, codex ? .codex : nil, opencode ? .opencode : nil,
         copilot ? .copilot : nil].compactMap { $0 }
            .filter { usage.snapshot.seen.contains($0) }
    }

    var body: some View {
        PanelSection(.agents, title: text.title, collapsible: collapsible) {
            Group {
                if !usage.snapshot.loaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text.loading).font(.caption).foregroundStyle(.secondary)
                    }
                } else if providers.isEmpty {
                    Text(text.empty).font(.caption).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(providers) { provider in
                                if provider != providers.first { Divider() }
                                AgentsProviderRow(provider: provider, snapshot: usage.snapshot, now: context.date,
                                                  display: NotchAgentLimitDisplay(rawValue: display) ?? .remaining,
                                                  text: text)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.locale, l10n.language.formattingLocale())
        .onAppear { usage.pageDidAppear() }
        .onDisappear { usage.pageDidDisappear() }
    }
}

private struct AgentsProviderRow: View {
    let provider: AgentProvider
    let snapshot: AgentUsageSnapshot
    let now: Date
    let display: NotchAgentLimitDisplay
    let text: NotchAgentStrings
    @Environment(\.locale) private var locale

    /// The session and whichever longer window binds first, as on the island.
    private var windows: [AgentLimitWindow] {
        let all = (snapshot.limits[provider]?.windows ?? []).map { AgentLimitSupport.current($0, at: now) }
        let session = all.first { $0.kind == .session }
        let longer = all.filter { $0.kind != .session }.max { $0.usedPercent < $1.usedPercent }
        return [session, longer].compactMap { $0 }
    }

    private var today: AgentTotals? {
        guard let totals = snapshot.usage(.today).byProvider[provider],
              totals.tokens.total > 0 || totals.requests > 0 || totals.cost > 0 else { return nil }
        return totals
    }

    var body: some View {
        let windows = windows
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(provider.tint)
                Text(provider.displayName).font(.callout.weight(.semibold))
                if let plan = snapshot.plans[provider] {
                    Text(plan.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(provider.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(provider.tint.opacity(0.14), in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
                if !snapshot.working(provider).isEmpty {
                    Circle().fill(provider.tint).frame(width: 6, height: 6)
                } else if let last = snapshot.lastActivity[provider] {
                    Text(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(locale)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(windows) { row($0) }
            if windows.isEmpty {
                Text(provider.reportsLimits ? text.waitingForLimits : text.noSession)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let today {
                HStack(spacing: 4) {
                    Text(text.period(.today)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(AgentFormat.tokens(today.tokens.total)).font(.caption).foregroundStyle(.secondary)
                    Text(today.unpriced > 0 ? (today.cost > 0 ? "≥ " + AgentFormat.cost(today.cost) : "—")
                         : AgentFormat.cost(today.cost))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                }
                .help(today.unpriced > 0 ? text.unpriced : text.valueNote)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ window: AgentLimitWindow) -> some View {
        let remaining = display == .remaining
        let fraction = remaining ? window.remainingFraction : window.usedFraction
        let tint = agentLimitTint(provider, usedFraction: window.usedFraction)
        let reset = AgentLimitSupport.displayedReset(window, now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label(window)).font(.caption.weight(.medium))
                if let reset {
                    Text((window.estimatedResetsAt == nil ? "" : "≈ ") + countdown(to: reset))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(NotchAgentSupport.limitShare(window, display: display, text: text))
                    .font(.caption).monospacedDigit().foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.12))
                    Capsule(style: .continuous).fill(tint)
                        .frame(width: proxy.size.width * min(1, max(0, fraction.isFinite ? fraction : 0)))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .help(reset.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) } ?? "")
    }

    private func label(_ window: AgentLimitWindow) -> String {
        switch window.kind {
        case .session: return text.session
        case .weekly: return window.scope.map { "\(text.weekly) · \($0)" } ?? text.weekly
        case .other:
            guard let minutes = window.minutes else { return window.scope ?? text.readoutLimit }
            return AgentFormat.duration(TimeInterval(minutes) * 60, locale: locale, units: 1)
        }
    }

    private func countdown(to date: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        return AgentFormat.duration(max(60, seconds), locale: locale, units: seconds >= 3600 ? 2 : 1)
    }
}
