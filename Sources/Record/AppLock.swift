import CryptoKit
import Foundation
import SwiftUI

/// Optional app-level passphrase gate. Not high-security in the crypto
/// sense — the encryption key still lives in a 0600 file — but stops
/// casual over-the-shoulder access to your meeting archive.
///
/// The passphrase is verified against a PBKDF2-style stretched hash stored
/// in UserDefaults. Wrong entries clear the field; too many in a row do
/// nothing beyond making the user try again.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var isLocked: Bool
    @Published private(set) var isConfigured: Bool

    private let hashKey = "record.appLockHash"
    private let saltKey = "record.appLockSalt"
    private let autoLockKey = "record.appLockMinutes"

    private var autoLockTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        let configured = defaults.data(forKey: "record.appLockHash") != nil
        self.isConfigured = configured
        self.isLocked = configured
        scheduleAutoLock()
    }

    // MARK: Configuration

    var autoLockMinutes: Int {
        get { UserDefaults.standard.integer(forKey: autoLockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoLockKey)
            scheduleAutoLock()
        }
    }

    /// Sets or clears the passphrase. Pass empty to remove the lock.
    func setPassphrase(_ passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: hashKey)
            UserDefaults.standard.removeObject(forKey: saltKey)
            isConfigured = false
            isLocked = false
            return
        }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let hash = Self.derive(passphrase: trimmed, salt: salt)
        UserDefaults.standard.set(hash, forKey: hashKey)
        UserDefaults.standard.set(salt, forKey: saltKey)
        isConfigured = true
        isLocked = false
    }

    func unlock(with passphrase: String) -> Bool {
        guard isConfigured,
              let salt = UserDefaults.standard.data(forKey: saltKey),
              let expected = UserDefaults.standard.data(forKey: hashKey) else {
            isLocked = false
            return true
        }
        let candidate = Self.derive(passphrase: passphrase, salt: salt)
        let ok = candidate == expected
        if ok {
            isLocked = false
            scheduleAutoLock()
        }
        return ok
    }

    func lockNow() {
        guard isConfigured else { return }
        isLocked = true
    }

    /// Called on any user interaction to reset the auto-lock timer.
    func poke() {
        scheduleAutoLock()
    }

    private func scheduleAutoLock() {
        autoLockTimer?.invalidate()
        let minutes = autoLockMinutes
        guard minutes > 0, isConfigured else { return }
        autoLockTimer = Timer.scheduledTimer(
            withTimeInterval: Double(minutes) * 60,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.lockNow() }
        }
    }

    /// PBKDF2 via HKDF-Extract on a repeated key derivation. Not the
    /// world's strongest KDF, but standard-library and adequate here.
    private static func derive(passphrase: String, salt: Data) -> Data {
        let key = SymmetricKey(data: Data(passphrase.utf8))
        // Iterate HKDF a few times to slow brute force. Not real PBKDF2 —
        // real PBKDF2 needs CommonCrypto — but a modest stretch is enough
        // to make casual attacks impractical.
        var derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: Data("record.appLock.v1".utf8),
            outputByteCount: 32
        )
        for _ in 0..<25_000 {
            derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: derived,
                salt: salt,
                info: Data("record.appLock.v1".utf8),
                outputByteCount: 32
            )
        }
        return derived.withUnsafeBytes { Data($0) }
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock
    @State private var passphrase = ""
    @State private var errorMessage: String?
    @State private var attempts = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.25), Color.black.opacity(0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                Text("Record is locked")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(attempt)
                Button("Unlock", action: attempt)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func attempt() {
        let ok = lock.unlock(with: passphrase)
        passphrase = ""
        if ok {
            errorMessage = nil
        } else {
            attempts += 1
            errorMessage = "Wrong passphrase."
        }
    }
}
