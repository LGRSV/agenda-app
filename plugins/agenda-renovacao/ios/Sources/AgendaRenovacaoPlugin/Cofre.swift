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
    case certificado = "certificadoAssinatura"   // "serial:p12 em base64" (a senha do p12 é o serial, como no SideStore)
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
        if chave == .senha {
            // 25/11/2026: a senha só abre com o Face ID já aprovado (Biometria.contexto); sem ele, não pede nada e falha.
            q[kSecUseAuthenticationContext as String] = Biometria.contexto ?? Biometria.contextoSilencioso()
        }
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
        if chave == .senha,
           let acesso = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) {
            // 25/11/2026: senha do Apple ID só com o dono presente (Face ID ou código do iPhone); fica só neste aparelho.
            novo[kSecAttrAccessControl as String] = acesso
            if let ctx = Biometria.contexto { novo[kSecUseAuthenticationContext as String] = ctx }
            if SecItemAdd(novo as CFDictionary, nil) == errSecSuccess { return }
            // iPhone sem código: grava do jeito antigo para a renovação não parar.
            novo.removeValue(forKey: kSecAttrAccessControl as String)
            novo.removeValue(forKey: kSecUseAuthenticationContext as String)
        }
        // Disponível em segundo plano depois do 1º desbloqueio; não vai para backup/outro aparelho.
        novo[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(novo as CFDictionary, nil)
    }

    /// Diz se existe o item sem ler o conteúdo (não abre o Face ID).
    static func existe(_ chave: Chave) -> Bool {
        var q = consulta(chave)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = Biometria.contextoSilencioso()
        let st = SecItemCopyMatching(q as CFDictionary, nil)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }

    /// Senha gravada antes de 25/11/2026 (sem Face ID): regrava protegida. Chamar com o Face ID já aprovado.
    static func protegerSenha() {
        guard Biometria.contexto != nil, let s = ler(.senha) else { return }
        gravar(.senha, s)
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
