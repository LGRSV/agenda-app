// SideStore.swift — convivência com o SideStore, que instala, renova e atualiza a Agenda pela fonte sidestore.json.
//   - Marcas que o SideStore põe no Info.plist do app que ele instala (ResignAppOperation.prepareAppBundle):
//     esquema "sidestore-<bundle id>" em CFBundleURLTypes e o tipo "io.sidestore.Installed.<bundle id>"
//     em UTExportedTypeDeclarations (InstalledApp.openAppURL / installedAppUTI). O AltStore usa "altstore-" e "io.altstore.".
//   - Certificado do SideStore: a Agenda nunca revoga (o SideStore e os apps dele parariam de abrir).
// Parte do plugin AgendaRenovacao (AGPL-3.0), baseado no SideStore (https://github.com/SideStore/SideStore).
import Foundation
import Security
import SideSign

extension Renovador {
    static let urlFonteSideStore = URL(string: "https://raw.githubusercontent.com/LGRSV/agenda-app/fonte/sidestore.json")!

    private static func esquemas(_ info: [String: Any]) -> [String] {
        (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    private static func tiposExportados(_ info: [String: Any]) -> [String] {
        (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
    }

    private static func ehEsquemaDeLoja(_ s: String) -> Bool {
        let x = s.lowercased()
        return x.hasPrefix("sidestore-") || x.hasPrefix("altstore-")
    }

    private static func ehTipoDeLoja(_ s: String) -> Bool {
        let x = s.lowercased()
        return x.hasPrefix("io.sidestore.installed.") || x.hasPrefix("io.altstore.installed.")
    }

    /// Quem instalou este app, pelas marcas no Info.plist: "sidestore", "altstore" ou "" (sem marca).
    static var instaladoPor: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let e = esquemas(info).map { $0.lowercased() }, t = tiposExportados(info).map { $0.lowercased() }
        if e.contains(where: { $0.hasPrefix("sidestore-") }) || t.contains(where: { $0.hasPrefix("io.sidestore.installed.") }) {
            return "sidestore"
        }
        if e.contains(where: { $0.hasPrefix("altstore-") }) || t.contains(where: { $0.hasPrefix("io.altstore.installed.") }) {
            return "altstore"
        }
        return ""
    }

    /// O atualizador próprio parte do Info.plist da release, que não tem as marcas do SideStore/AltStore.
    /// Copia as do app instalado; sem elas o SideStore pode achar que a Agenda saiu do iPhone e parar de renová-la.
    static func manterMarcasDaLoja(em info: inout [String: Any]) {
        let instalado = Bundle.main.infoDictionary ?? [:]

        var urls = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let jaTem = Set(esquemas(info).map { $0.lowercased() })
        for tipo in instalado["CFBundleURLTypes"] as? [[String: Any]] ?? [] {
            let s = tipo["CFBundleURLSchemes"] as? [String] ?? []
            if s.contains(where: ehEsquemaDeLoja) && !s.contains(where: { jaTem.contains($0.lowercased()) }) {
                urls.append(tipo)
            }
        }
        if !urls.isEmpty { info["CFBundleURLTypes"] = urls }

        var utis = info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        let jaTemTipo = Set(tiposExportados(info).map { $0.lowercased() })
        for uti in instalado["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [] {
            guard let id = uti["UTTypeIdentifier"] as? String, ehTipoDeLoja(id), !jaTemTipo.contains(id.lowercased()) else { continue }
            utis.append(uti)
        }
        if !utis.isEmpty { info["UTExportedTypeDeclarations"] = utis }
    }

    // MARK: certificado do SideStore (nunca revogar)

    /// Pelo nome da máquina: o SideStore cria "SideStore - <conta>'s <aparelho>" (CertificateProvisioningFlow)
    /// e, instalado pelo iloader, usa o certificado "iloader" que veio com ele.
    static func ehDoSideStore(_ c: X509Certificate) -> Bool {
        let n = (c.machineName ?? "").lowercased()
        return n.contains("sidestore") || n.contains("iloader")
    }

    /// Seriais (hex) dos certificados do perfil embutido, isto é, de quem assinou este app.
    func seriaisDoApp() -> [String] {
        (perfilEmbutido()?.certificados ?? []).compactMap { der -> String? in
            guard let c = SecCertificateCreateWithData(nil, der as CFData),
                  let serial = SecCertificateCopySerialNumberData(c, nil) else { return nil }
            return (serial as Data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Certificados da lista que a Agenda não pode revogar: os do SideStore pelo nome e, se o SideStore
    /// instalou o app, o que assinou este app (é o mesmo que assina o SideStore e os apps dele).
    func certificadosProtegidos(_ lista: [X509Certificate]) -> [X509Certificate] {
        let doApp = Self.instaladoPor == "sidestore" ? seriaisDoApp() : []
        return lista.filter { c in
            if Self.ehDoSideStore(c) { return true }
            if (c.machineName ?? "").lowercased().hasPrefix("agenda") { return false }   // certificado da própria Agenda
            return doApp.contains { Self.mesmoSerial($0, c.serialNumber) }
        }
    }
}

/// No limite de certificados só sobrou o do SideStore: a Agenda não revoga (devolve para o João escolher).
struct CertificadoDoSideStore: LocalizedError {
    var errorDescription: String? {
        "A conta Apple está no limite de certificados e o único que daria para trocar é o do SideStore. A Agenda não revoga esse certificado, porque o SideStore e os apps dele parariam de abrir. Escolha: atualize a Agenda pelo SideStore (Meus Apps), ou revogue um certificado você mesmo (no SideStore ou no iloader) e tente de novo."
    }
}
