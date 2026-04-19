//
//  AddChannelView.swift
//  Retichat
//
//  Join or create a channel by name on a configured rfed node.
//

import SwiftUI

struct AddChannelView: View {
    @EnvironmentObject var channelClient: RfedChannelClient
    @Environment(\.dismiss) private var dismiss

    @State private var channelName = ""
    @State private var rfedIdentityHash = UserPreferences.shared.rfedNodeIdentityHash
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.retichatBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    // Channel name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Channel name")
                            .font(.caption)
                            .foregroundColor(.retichatOnSurfaceVariant)
                        TextField("e.g. general", text: $channelName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color.retichatSurface)
                            .cornerRadius(10)
                            .foregroundColor(.retichatOnSurface)
                    }

                    // rfed node identity hash
                    VStack(alignment: .leading, spacing: 6) {
                        Text("rfed node identity hash")
                            .font(.caption)
                            .foregroundColor(.retichatOnSurfaceVariant)
                        TextField("32 hex chars", text: $rfedIdentityHash)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(Color.retichatSurface)
                            .cornerRadius(10)
                            .foregroundColor(.retichatOnSurface)
                        Text("Leave unchanged to use the node configured in Settings.")
                            .font(.caption2)
                            .foregroundColor(.retichatOnSurfaceVariant.opacity(0.7))
                    }

                    // Error
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 4)
                    }

                    // Join button
                    Button {
                        join()
                    } label: {
                        HStack {
                            Spacer()
                            if isJoining {
                                ProgressView().tint(.white)
                            } else {
                                Text("Join / Create")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(canJoin ? Color.retichatPrimary : Color.retichatPrimary.opacity(0.4))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                    }
                    .disabled(!canJoin || isJoining)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Join Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.retichatPrimary)
                }
            }
        }
    }

    private var canJoin: Bool {
        !channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        rfedIdentityHash.trimmingCharacters(in: .whitespacesAndNewlines).count == 32
    }

    private func join() {
        let name = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = rfedIdentityHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        errorMessage = nil
        isJoining = true
        Task {
            do {
                _ = try await channelClient.joinChannel(name: name, rfedNodeIdentityHashHex: hash)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isJoining = false
                }
            }
        }
    }
}
