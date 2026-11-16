//
//  SettingsView.swift
//  JustaUsageBar
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sessionKey: String = ""
    @State private var organizationId: String = ""
    @State private var showingAuthWindow = false
    @State private var showManualEntry = false

    private let anthropicOrange = Color(red: 0.83, green: 0.53, blue: 0.30)

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 2) {
                Text("✳︎")
                    .foregroundColor(anthropicOrange)
                Text("Claude")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button(action: { dismiss() }) {
                    Text("×")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if viewModel.hasClaudeCredentials {
                // Connected state - minimal
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Sign out") {
                        viewModel.clearClaudeCredentials()
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            } else {
                // Sign in
                VStack(spacing: 10) {
                    Button(action: { showingAuthWindow = true }) {
                        HStack(spacing: 4) {
                            Text("✳︎")
                            Text("Sign in")
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(anthropicOrange)

                    Button(showManualEntry ? "hide" : "manual") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showManualEntry.toggle()
                        }
                    }
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)

                    if showManualEntry {
                        VStack(spacing: 8) {
                            SecureField("session key", text: $sessionKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                            TextField("org id", text: $organizationId)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                            Button("save") {
                                viewModel.saveCredentials(sessionKey: sessionKey, organizationId: organizationId)
                                dismiss()
                            }
                            .font(.system(size: 9))
                            .foregroundColor(anthropicOrange)
                            .buttonStyle(.plain)
                            .disabled(sessionKey.isEmpty || organizationId.isEmpty)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 160)
        .task {
            sessionKey = await CredentialStorage.shared.sessionKey ?? ""
            organizationId = await CredentialStorage.shared.organizationId ?? ""
        }
        .sheet(isPresented: $showingAuthWindow) {
            AuthWindowView { sk, org in
                viewModel.saveCredentials(sessionKey: sk, organizationId: org)
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: UsageViewModel.shared)
}

struct SourceSettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var address = ""
    @State private var key = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data source").font(.headline)
            HStack {
                Button(viewModel.source == .direct ? "Direct ✓" : "Use direct") {
                    run { await viewModel.useDirectSource() }
                }
                Button(viewModel.source == .cpa ? "CLIProxyAPI ✓" : "Use saved CPA") {
                    run { try await viewModel.useSavedCPA() }
                }
            }
            TextField("CPA base address, e.g. http://localhost:8317", text: $address)
            SecureField("Management key", text: $key)
            Text("Remote connections should use HTTPS. HTTP sends the management key in plaintext. CPA must allow remote management for remote access.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Test and enable") {
                    run {
                        try await viewModel.testAndEnableCPA(address: address, key: key)
                        key = ""
                        message = "Connection enabled."
                    }
                }
                .disabled(address.isEmpty || key.isEmpty)
                Button("Clear saved CPA") {
                    run {
                        try await viewModel.clearCPAConfiguration()
                        address = ""; key = ""
                        message = "CPA configuration removed."
                    }
                }
                if busy { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 440)
        .disabled(busy)
        .task { address = await CredentialStorage.shared.cpaConnection?.address ?? "" }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { message = (error as? CPAError)?.errorDescription ?? "Could not save or connect. Check the address, key, and network." }
        }
    }
}
