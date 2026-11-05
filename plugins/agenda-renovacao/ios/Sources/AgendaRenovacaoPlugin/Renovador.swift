// Renovador.swift — o fluxo da renovação, igual ao do SideStore:
//   SignInOperation (login GSA + 2FA) -> FetchProvisioningProfilesOperation (app ID + perfil novo no portal)
//   -> RefreshAppOperation (instala o perfil pelo misagent, SEM reinstalar o app).
// Referência: SideStore/SideStore/Core/{Auth,Anisette,Operations,DeviceApi}. Parte do plugin AgendaRenovacao (AGPL-3.0).
import Foundation
import SideSign

final class Renovador: @unchecked Sendable {
    static let shared = Renovador()

    let portal = DeveloperPortal.shared
    private let xcodeVersion = "26.0 (26A242)"   // o mesmo padrão do SideStore (AnisetteConfigManager)
    private let listaServidores = URL(string: "https://servers.sidestore.io/servers.json")!
    private let servidoresReserva = ["https://ani.sidestore.io", "https://ani.sidestore.app",
                                     "https://ani.sidestore.zip", "https://ani.846969.xyz"]
    let d = UserDefaults.standard
    private let kValidade = "agendaRenovacao.validade"
    private let kUltima = "agendaRenovacao.ultimaRenovacao"
    private let kErro = "agendaRenovacao.ultimoErro"
    private let kAnisette = "agendaRenovacao.ultimoAnisette"

    // 2FA: o pedido de código vai para o JS (evento) e a resposta volta por enviarCodigo().
    private let trava = NSLock()
    private var pedidoCodigo: CheckedContinuation<TwoFactorResponse, Error>?
    private var telefoneSMS: String?
    private var ocupado = false
    var aoPedirCodigo: (([String: Any]) -> Void)?
    // Atualização do app (Atualizador.swift): progresso para o JS e aviso de que a instalação vai começar.
    var aoProgredir: (([String: Any]) -> Void)?
    var aoInstalar: (() -> Void)?
    var ultimoProgresso: (String, Int) = ("", -1)

    // MARK: pareamento

    var arquivoPareamento: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("agenda-pairing.plist")
    }

    func salvarPareamento(_ dados: Data) throws -> [String: Any] {
        let tipo = try Aparelho.tipo(de: dados)
        try dados.write(to: arquivoPareamento, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = arquivoPareamento
        var valores = URLResourceValues()
        valores.isExcludedFromBackup = true
        try? url.setResourceValues(valores)
        var r: [String: Any] = ["tipo": tipo.rawValue]
        if let udid = Aparelho.lerPlist(dados)?["UDID"] as? String { r["udid"] = udid }
        return r
    }

    func apagarPareamento() { try? FileManager.default.removeItem(at: arquivoPareamento) }

    func lerPareamento() -> Data? { try? Data(contentsOf: arquivoPareamento) }

    // MARK: perfil embutido (o que o AltStore colocou no app)

    struct PerfilLocal {
        let teamID: String?
        let validade: Date?
        let certificados: [Data]
    }

    func perfilEmbutido() -> PerfilLocal? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let dados = try? Data(contentsOf: url) else { return nil }
        return perfilLocal(dados)
    }

    private func perfilLocal(_ dados: Data) -> PerfilLocal? {
        guard let p = try? ProvisioningProfile(data: dados) else { return nil }
        return PerfilLocal(teamID: p.teamIdentifier, validade: p.expirationDate, certificados: certificados(dados))
    }

    /// DeveloperCertificates do plist dentro do .mobileprovision (para ver se o certificado do AltStore continua no perfil novo).
    private func certificados(_ dados: Data) -> [Data] {
        let texto = String(decoding: dados, as: UTF8.self)
        guard let i = texto.range(of: "<?xml"), let f = texto.range(of: "</plist>", range: i.lowerBound..<texto.endIndex),
              let plist = Aparelho.lerPlist(Data(texto[i.lowerBound..<f.upperBound].utf8)) else { return [] }
        return plist["DeveloperCertificates"] as? [Data] ?? []
    }

    // MARK: estado

    func estado(ip: String, portaRP: UInt16, lerAparelho: Bool) async -> [String: Any] {
        let bid = Bundle.main.bundleIdentifier ?? ""
        let emb = perfilEmbutido()
        let renovada = d.object(forKey: kValidade) as? Date
        var validade = emb?.validade
        if let renovada, renovada > (validade ?? .distantPast) { validade = renovada }

        var r: [String: Any] = [
            "bundleId": bid,
            "logado": Cofre.ler(.token) != nil || Cofre.ler(.senha) != nil,
            "temPareamento": FileManager.default.fileExists(atPath: arquivoPareamento.path)
        ]
        if let id = Cofre.ler(.appleID) { r["appleId"] = mascarar(id) }
        if let t = emb?.teamID { r["teamId"] = t }
        if let v = emb?.validade { r["validadeEmbutida"] = iso(v) }
        if let renovada { r["validadeRenovada"] = iso(renovada) }
        if let u = d.object(forKey: kUltima) as? Date { r["ultimaRenovacao"] = iso(u) }
        if let e = d.string(forKey: kErro) { r["ultimoErro"] = e }

        var tipo: TipoPareamento? = nil
        if let p = lerPareamento() {
            tipo = try? Aparelho.tipo(de: p)
            r["tipoPareamento"] = tipo?.rawValue ?? "inválido"
        }
        let porta = tipo == .rppairing ? portaRP : Aparelho.portaLockdown
        let vpn = await Aparelho.vpnResponde(ip: ip, porta: porta)
        r["vpnAtiva"] = vpn

        if lerAparelho, vpn, let p = lerPareamento() {
            do {
                let perfis = try await Aparelho.perfisInstalados(pareamento: p, ip: ip, portaRP: portaRP)
                let meus = perfis.compactMap { try? ProvisioningProfile(data: $0) }.filter { combina($0, bid: bid) }
                if let melhor = meus.map({ $0.expirationDate }).max() {
                    r["validadeNoAparelho"] = iso(melhor)
                    if melhor > (validade ?? .distantPast) { validade = melhor }
                }
                r["perfisNoAparelho"] = meus.count
            } catch {
                r["erroAparelho"] = error.localizedDescription
            }
        }
        if let validade {
            r["validade"] = iso(validade)
            r["diasRestantes"] = (validade.timeIntervalSinceNow / 86400 * 10).rounded() / 10
        }
        return r
    }

    private func combina(_ p: ProvisioningProfile, bid: String) -> Bool {
        let b = p.bundleIdentifier.lowercased()
        return b == bid.lowercased() || b.hasSuffix("." + bid.lowercased())
    }

    // MARK: login

    func entrar(appleID: String, senha: String) async throws -> [String: Any] {
        try comecar()
        defer { terminar() }
        let anisette = try await obterAnisette()
        let auth = try await portal.authenticate(appleID: appleID, password: senha, anisetteData: anisette,
                                                 xcodeVersion: xcodeVersion,
                                                 machinePassword: nil,
                                                 accountRepairHandler: DeveloperPortal.defaultAccountRepairHandler,
                                                 verificationHandler: { [weak self] pedido in
            guard let self else { throw DeveloperPortalError.userCancelled }
            return try await self.pedirCodigo(pedido)
        })
        Cofre.gravar(.appleID, appleID.trimmingCharacters(in: .whitespacesAndNewlines))
        Cofre.gravar(.senha, senha)
        Cofre.gravar(.dsid, auth.session.dsid)
        Cofre.gravar(.token, auth.session.authToken)
        let times = (try? await portal.fetchTeams(for: auth.account, session: auth.session)) ?? []
        return [
            "nome": auth.account.name,
            "appleId": mascarar(appleID),
            "times": times.map { ["id": $0.identifier, "nome": $0.name, "tipo": $0.type.rawValue] }
        ]
    }

    func sair() { Cofre.apagarLogin() }

    private func pedirCodigo(_ pedido: TwoFactorRequest) async throws -> TwoFactorResponse {
        if case .selectDeliveryMethod(let preferido, let telefones) = pedido {
            telefoneSMS = telefones.first?.id
            if preferido == .trustedDevice || telefones.isEmpty { return .requestTrustedDevice }
            return .requestSMS(phoneID: telefones[0].id)
        }
        var info: [String: Any] = ["modo": pedido.mode?.rawValue ?? "trustedDevice"]
        if let e = pedido.error { info["erro"] = e }
        switch pedido {
        case .sms(let tel, let ativo, _), .voice(let tel, let ativo, _):
            telefoneSMS = ativo
            info["telefone"] = tel.first(where: { $0.id == ativo })?.number ?? tel.first?.number ?? ""
        default: break
        }
        return try await withCheckedThrowingContinuation { cont in
            trava.lock()
            let antigo = pedidoCodigo
            pedidoCodigo = cont
            trava.unlock()
            antigo?.resume(throwing: DeveloperPortalError.userCancelled)
            DispatchQueue.main.async { self.aoPedirCodigo?(info) }
        }
    }

    /// Resposta do JS: código digitado, pedido de SMS ou cancelamento.
    @discardableResult
    func responderCodigo(codigo: String?, sms: Bool, cancelar: Bool) -> Bool {
        trava.lock()
        let cont = pedidoCodigo
        pedidoCodigo = nil
        trava.unlock()
        guard let cont else { return false }
        if cancelar {
            cont.resume(throwing: DeveloperPortalError.userCancelled)
        } else if sms {
            cont.resume(returning: .requestSMS(phoneID: telefoneSMS ?? ""))
        } else {
            let c = (codigo ?? "").filter { $0.isNumber }
            cont.resume(returning: .verificationCode(c))
        }
        return true
    }

    // MARK: anisette (servidores remotos padrão do SideStore)

    private func obterAnisette() async throws -> AnisetteData {
        var servidores: [URL] = []
        if let lista = try? await AnisetteDataManager.shared.fetchServerList(from: listaServidores) {
            servidores = lista.servers.filter { !$0.isHidden }.compactMap { URL(string: $0.address) }
        }
        for s in servidoresReserva { if let u = URL(string: s), !servidores.contains(u) { servidores.append(u) } }
        let ultimo = d.string(forKey: kAnisette)
        let inicio = servidores.firstIndex(where: { $0.absoluteString == ultimo }) ?? 0
        let blob = Cofre.ler(.adiBlob).flatMap { Data(base64Encoded: $0) }
        let (dados, novoBlob) = try await AnisetteDataManager.shared.fetchAnisetteDataWithFailover(
            servers: servidores,
            startIndex: inicio,
            identifier: Cofre.anisetteUUID(),
            existingAdiBlob: blob,
            headers: nil,
            onError: nil,
            onSuccess: { url in UserDefaults.standard.set(url.absoluteString, forKey: "agendaRenovacao.ultimoAnisette") }
        )
        if let novoBlob { Cofre.gravar(.adiBlob, novoBlob.base64EncodedString()) }
        return dados
    }

    /// Sessão do portal: reaproveita dsid + token (como o AuthManager do SideStore); se não valer mais,
    /// entra de novo com a senha guardada (pode pedir 2FA pelo mesmo evento).
    func sessao() async throws -> (Account, Session) {
        let anisette = try await obterAnisette()
        if let dsid = Cofre.ler(.dsid), let token = Cofre.ler(.token) {
            let s = Session(dsid: dsid, authToken: token, anisetteData: anisette, xcodeVersion: xcodeVersion)
            if let conta = try? await portal.fetchAccount(session: s) { return (conta, s) }
        }
        guard let id = Cofre.ler(.appleID), let senha = Cofre.ler(.senha) else {
            throw FalhaRenovacao("Entre com o Apple ID primeiro.")
        }
        let auth = try await portal.authenticate(appleID: id, password: senha, anisetteData: anisette,
                                                 xcodeVersion: xcodeVersion,
                                                 machinePassword: nil,
                                                 accountRepairHandler: DeveloperPortal.defaultAccountRepairHandler,
                                                 verificationHandler: { [weak self] pedido in
            guard let self else { throw DeveloperPortalError.userCancelled }
            return try await self.pedirCodigo(pedido)
        })
        Cofre.gravar(.dsid, auth.session.dsid)
        Cofre.gravar(.token, auth.session.authToken)
        return (auth.account, auth.session)
    }

    // MARK: renovação

    func renovar(ip: String, portaRP: UInt16) async throws -> [String: Any] {
        try comecar()
        defer { terminar() }
        do {
            let r = try await renovarDeFato(ip: ip, portaRP: portaRP)
            d.removeObject(forKey: kErro)
            return r
        } catch {
            d.set("\(iso(Date())): \(error.localizedDescription)", forKey: kErro)
            throw error
        }
    }

    private func renovarDeFato(ip: String, portaRP: UInt16) async throws -> [String: Any] {
        guard let pareamento = lerPareamento() else {
            throw FalhaRenovacao("Importe o arquivo de pareamento (pairing file) primeiro.")
        }
        let tipo = try Aparelho.tipo(de: pareamento)
        let porta = tipo == .rppairing ? portaRP : Aparelho.portaLockdown
        guard await Aparelho.vpnResponde(ip: ip, porta: porta) else {
            throw FalhaRenovacao("A VPN do LocalDevVPN não está respondendo em \(ip). Ligue o LocalDevVPN e tente de novo.")
        }
        guard let bid = Bundle.main.bundleIdentifier else { throw FalhaRenovacao("Sem bundle id.") }
        let emb = perfilEmbutido()

        let (conta, s) = try await sessao()
        let times = try await portal.fetchTeams(for: conta, session: s)
        guard let time = times.first(where: { $0.identifier == emb?.teamID }) ?? times.first else {
            throw FalhaRenovacao("Nenhum time de desenvolvedor nesta conta.")
        }
        if let t = emb?.teamID, t != time.identifier {
            throw FalhaRenovacao("O app foi assinado pelo time \(t), mas este Apple ID é do time \(time.identifier). Entre com o mesmo Apple ID usado no AltStore.")
        }

        // App ID do próprio app (o AltStore registra com sufixo do time, ex.: com.lgrsv.agenda.XXXXXXXXXX).
        let appIDs = try await portal.fetchAppIDs(for: time, session: s)
        var appID = appIDs.first(where: { $0.bundleIdentifier.lowercased() == bid.lowercased() })
        if appID == nil {
            appID = try await portal.addAppID(withName: "Agenda", bundleIdentifier: bid, team: time, session: s)
        }
        guard let appID else { throw FalhaRenovacao("App ID não encontrado.") }

        let perfil = try await portal.downloadProvisioningProfile(for: appID, isTeamProfile: true, subPlatform: nil,
                                                                  deviceType: .iPhone, team: time, session: s)
        var aviso: String? = nil
        if let emb, !emb.certificados.isEmpty {
            let novos = Set(certificados(perfil.data))
            if !novos.isEmpty && Set(emb.certificados).isDisjoint(with: novos) {
                aviso = "O certificado que assinou o app não está no perfil novo (pode ter sido revogado). Se o app não abrir, reinstale pelo AltStore."
            }
        }

        try await Aparelho.instalarPerfil(perfil.data, pareamento: pareamento, ip: ip, portaRP: portaRP)

        d.set(perfil.expirationDate, forKey: kValidade)
        d.set(Date(), forKey: kUltima)
        var r: [String: Any] = [
            "validade": iso(perfil.expirationDate),
            "diasRestantes": (perfil.expirationDate.timeIntervalSinceNow / 86400 * 10).rounded() / 10,
            "perfil": perfil.name,
            "uuid": perfil.uuid.uuidString,
            "appId": appID.bundleIdentifier,
            "teamId": time.identifier
        ]
        if let aviso { r["aviso"] = aviso }
        return r
    }

    // MARK: util

    func comecar() throws {
        trava.lock(); defer { trava.unlock() }
        if ocupado { throw FalhaRenovacao("Já existe uma operação em andamento.") }
        ocupado = true
    }

    func terminar() {
        trava.lock(); ocupado = false; trava.unlock()
    }

    func iso(_ data: Date) -> String { ISO8601DateFormatter().string(from: data) }

    private func mascarar(_ email: String) -> String {
        let partes = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard partes.count == 2, let primeira = partes[0].first else { return "***" }
        return "\(primeira)***@\(partes[1])"
    }
}
