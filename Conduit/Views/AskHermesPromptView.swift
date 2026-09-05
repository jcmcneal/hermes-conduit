//
//  AskHermesPromptView.swift
//  Conduit
//
//  A copyable "Ask Hermes" prompt card used across the Connection Setup
//  wizard. Purely clipboard-based: nothing is ever sent to Hermes from here,
//  and the prompts contain no secrets.
//

import SwiftUI
import UIKit

struct AskHermesPromptView: View {
    let title: String
    let prompt: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.conduitAccent)

            Text(prompt)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("setup.prompt-text")

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = prompt
                    copied = true
                } label: {
                    Label("Copy Prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityIdentifier("setup.copy-prompt")

                if copied {
                    Text("Copied")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.copied-confirmation")
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }
}
