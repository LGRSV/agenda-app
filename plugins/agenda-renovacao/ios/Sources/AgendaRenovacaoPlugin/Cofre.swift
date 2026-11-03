// Cofre.swift — guarda credenciais e tokens SÓ no Keychain do iPhone (nunca em log, nunca em arquivo).
// Parte do plugin AgendaRenovacao (AGPL-3.0). Inspirado no Keychain/AuthManager do SideStore.
import Foundation
import Security

enum Chave: String, CaseIterable {
    case appleID = "appleID"
    case senha = "senha"
    case dsid = "dsid"
    case token = "xcodeToken"
    case anisetteID = "anisetteID"
    case adiBlob = "anisetteAdiBlob"
}

enum Cofre {
    private static let servico = "agenda.renovacao"

    private static func consulta(_ chave: Chave) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servico,
            kSecAttrAccount as String: chave.rawValue
        ]
    }

    static func ler(_ chave: Chave) -> String? {
        var q = consulta(chave)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var saida: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &saida) == errSecSuccess,
              let dados = saida as? Data,
              let texto = String(data: dados, encoding: .utf8),
              !texto.isEmpty else { return nil }
        return texto
    }

    static func gravar(_ chave: Chave, _ valor: String?) {
        let q = consulta(chave)
        SecItemDelete(q as CFDictionary)
        guard let valor, !valor.isEmpty, let dados = valor.data(using: .utf8) else { return }
        var novo = q
        novo[kSecValueData as String] = dados
        // Disponível em segundo plano depois do 1º desbloqueio; não vai para backup/outro aparelho.
        novo[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(novo as CFDictionary, nil)
    }

    /// Identificador fixo da "máquina" anisette deste iPhone (a Apple lembra dela e não pede 2FA toda hora).
    static func anisetteUUID() -> UUID {
        if let s = ler(.anisetteID), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        gravar(.anisetteID, u.uuidString)
        return u
    }

    static func apagarLogin() {
        for c in [Chave.appleID, .senha, .dsid, .token] { gravar(c, nil) }
    }
}
