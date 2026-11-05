// Atualizador.swift — atualiza o próprio app sem AltStore, do jeito que o SideStore instala/atualiza apps no aparelho:
//   CertificateProvisioningFlow (certificado + chave privada guardados no Keychain) -> download da .ipa
//   -> FetchProvisioningProfilesOperation (perfil do App ID) -> ResignAppOperation (AppBundleSigner do SideSign)
//   -> CreateIpaOperation + SendAppOperation (AFC para PublicStaging) -> InstallAppOperation (installation_proxy).
// Referência: SideStore/SideStore/Core/{Auth/Flows,Operations/PipelineOperations} e minimuxer/DeviceGateway/idevice.
// Parte do plugin AgendaRenovacao (AGPL-3.0), baseado no SideStore (https://github.com/SideStore/SideStore).
import Foundation
import SideSign

/// A conta já tem o máximo de certificados e o certificado com chave privada deste iPhone não existe:
/// para assinar é preciso revogar um (o SideStore pergunta antes, aqui o JS pergunta e chama de novo com revogar).
struct PrecisaRevogar: LocalizedError {
    let certificados: [String]
    var errorDescription: String? {
        "A conta Apple já está no limite de certificados. Para assinar a versão nova é preciso revogar um certificado antigo; apps instalados com ele (por exemplo pelo AltStore) podem parar de abrir. A Agenda é reinstalada já com o certificado novo."
    }
}

extension Renovador {
    static let urlFonte = URL(string: "https://raw.githubusercontent.com/LGRSV/agenda-app/fonte/altstore.json")!
    static let bundleDaFonte = "com.lgrsv.agenda"
    /// Só aceita pacote da release do próprio repositório (a página que chama vem da internet).
    static let prefixoPacote = "https://github.com/LGRSV/agenda-app/releases/download/"
    static let kAtualizacao = "agendaRenovacao.atualizacao"
    static let kErroAtualizacao = "agendaRenovacao.ultimoErroAtualizacao"

    struct Lancamento {
        let versao: String
        let url: URL
        let tamanho: Int?
        let data: String?
    }

    var versaoInstalada: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compara versões por partes numéricas ("1.0.10" > "1.0.9"): -1, 0 ou 1.
    static func comparar(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    static func mesmoSerial(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> String {
            let t = s.lowercased().filter { $0.isHexDigit }
            let semZero = t.drop(while: { $0 == "0" })
            return semZero.isEmpty ? "0" : String(semZero)
        }
        return n(a) == n(b)
    }

    // MARK: fonte (o mesmo altstore.json que o AltStore lia)

    func lerFonte() async throws -> Lancamento {
        var pedido = URLRequest(url: Self.urlFonte, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        pedido.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (dados, resposta) = try await URLSession.shared.data(for: pedido)
        guard (resposta as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: dados) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == Self.bundleDaFonte }),
              let versoes = app["versions"] as? [[String: Any]] else {
            throw FalhaRenovacao("Não consegui ler a fonte de atualizações.")
        }
        let validas = versoes.compactMap { v -> Lancamento? in
            guard let ver = v["version"] as? String, let s = v["downloadURL"] as? String,
                  s.hasPrefix(Self.prefixoPacote), let u = URL(string: s) else { return nil }
            return Lancamento(versao: ver, url: u, tamanho: (v["size"] as? NSNumber)?.intValue, data: v["date"] as? String)
        }
        guard let melhor = validas.max(by: { Self.comparar($0.versao, $1.versao) < 0 }) else {
            throw FalhaRenovacao("A fonte de atualizações não tem um pacote válido.")
        }
        return melhor
    }

    /// Versão instalada x versão da fonte. Não rejeita: em erro de rede devolve {erro}.
    func versaoDisponivel() async -> [String: Any] {
        let atual = versaoInstalada
        var r: [String: Any] = ["atual": atual]
        if let p = d.dictionary(forKey: Self.kAtualizacao), let para = p["para"] as? String {
            let quando = p["quando"] as? Date ?? .distantPast
            if Self.comparar(atual, para) >= 0 {
                r["atualizadoAgora"] = para
                d.removeObject(forKey: Self.kAtualizacao)
            } else if Date().timeIntervalSince(quando) > 900 {
                r["atualizacaoNaoConcluida"] = para
                d.removeObject(forKey: Self.kAtualizacao)
            }
        }
        if let e = d.string(forKey: Self.kErroAtualizacao) { r["ultimoErro"] = e }
        do {
            let f = try await lerFonte()
            r["disponivel"] = f.versao
            r["haNova"] = Self.comparar(f.versao, atual) > 0
            if let t = f.tamanho { r["tamanho"] = t }
            if let x = f.data { r["data"] = x }
        } catch {
            r["erro"] = error.localizedDescription
        }
        return r
    }

    // MARK: atualização

    func atualizar(ip: String, portaRP: UInt16, revogar: Bool, forcar: Bool) async throws -> [String: Any] {
        try comecar()
        defer { terminar() }
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("agenda-atualizacao", isDirectory: true)
        try? FileManager.default.removeItem(at: pasta)
        defer { try? FileManager.default.removeItem(at: pasta) }
        do {
            let r = try await atualizarDeFato(ip: ip, portaRP: portaRP, revogar: revogar, forcar: forcar, pasta: pasta)
            d.removeObject(forKey: Self.kErroAtualizacao)
            return r
        } catch {
            d.removeObject(forKey: Self.kAtualizacao)
            if !(error is PrecisaRevogar) {
                d.set("\(iso(Date())): \(error.localizedDescription)", forKey: Self.kErroAtualizacao)
            }
            throw error
        }
    }

    private func atualizarDeFato(ip: String, portaRP: UInt16, revogar: Bool, forcar: Bool, pasta: URL) async throws -> [String: Any] {
        avisar("conferindo", "Conferindo a VPN e a versão nova…", 0.02)
        guard let pareamento = lerPareamento() else {
            throw FalhaRenovacao("Importe o arquivo de pareamento (pairing file) primeiro.")
        }
        let tipo = try Aparelho.tipo(de: pareamento)
        let porta = tipo == .rppairing ? portaRP : Aparelho.portaLockdown
        guard await Aparelho.vpnResponde(ip: ip, porta: porta) else {
            throw FalhaRenovacao("A VPN do LocalDevVPN não está respondendo em \(ip). Ligue o LocalDevVPN e tente de novo.")
        }
        guard let bid = Bundle.main.bundleIdentifier else { throw FalhaRenovacao("Sem bundle id.") }
        let atual = versaoInstalada
        let lancamento = try await lerFonte()
        if !forcar && Self.comparar(lancamento.versao, atual) <= 0 {
            throw FalhaRenovacao("O app já está na versão mais nova (\(atual)).")
        }

        // 1) Apple ID e time: os mesmos da renovação (mesmo time + mesmo bundle id = mesmos dados e Keychain).
        avisar("apple", "Entrando na Apple…", 0.05)
        let emb = perfilEmbutido()
        let (conta, s) = try await sessao()
        let times = try await portal.fetchTeams(for: conta, session: s)
        guard let time = times.first(where: { $0.identifier == emb?.teamID }) ?? times.first else {
            throw FalhaRenovacao("Nenhum time de desenvolvedor nesta conta.")
        }
        if let t = emb?.teamID, t != time.identifier {
            throw FalhaRenovacao("O app foi assinado pelo time \(t), mas este Apple ID é do time \(time.identifier). Entre com o mesmo Apple ID usado no AltStore.")
        }

        // 2) Certificado com chave privada (CertificateProvisioningFlow do SideStore). A chave do certificado
        //    do AltStore ficou no AltStore; na 1ª vez cria um certificado novo e guarda (com a chave) no Keychain.
        avisar("certificado", "Conferindo o certificado de assinatura…", 0.08)
        let noPortal = try await portal.fetchCertificates(for: time, session: s)
        var chave = certificadoGuardado(valeEm: noPortal)
        var aRevogar: [X509Certificate] = []
        var certificadoNovo = false
        if chave == nil {
            do {
                chave = try await criarCertificado(time: time, sessao: s)
                certificadoNovo = true
            } catch let e where Self.limiteDeCertificados(e) {
                aRevogar = Self.ordemParaRevogar(noPortal)
                if aRevogar.isEmpty { throw e }
                if !revogar { throw PrecisaRevogar(certificados: aRevogar.map { $0.machineName ?? $0.name }) }
            }
        }

        // 3) Baixa e confere o pacote antes de mexer em certificado ou no app.
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let ipa = try await baixar(lancamento.url, para: pasta.appendingPathComponent("baixada.ipa"))
        avisar("preparando", "Abrindo o pacote…", 0.56)
        let appURL = try FileManager.default.unzipAppBundle(at: ipa, to: pasta.appendingPathComponent("app", isDirectory: true))
        try? FileManager.default.removeItem(at: ipa)
        let info = try lerInfo(appURL)
        let bidPacote = info["CFBundleIdentifier"] as? String ?? ""
        guard bidPacote == Self.bundleDaFonte || bidPacote == bid else {
            throw FalhaRenovacao("O pacote baixado não é a Agenda (\(bidPacote)).")
        }
        let versaoPacote = info["CFBundleShortVersionString"] as? String ?? "?"
        if !forcar && Self.comparar(versaoPacote, atual) <= 0 {
            throw FalhaRenovacao("A release ainda traz a versão \(versaoPacote). Tente de novo em alguns minutos.")
        }

        // 4) No limite de certificados: revoga (o usuário confirmou) e cria um novo.
        if chave == nil {
            avisar("certificado", "Trocando o certificado de assinatura…", 0.6)
            chave = try await trocarCertificado(aRevogar, time: time, sessao: s)
            certificadoNovo = true
        }
        guard let chave else { throw FalhaRenovacao("Sem certificado para assinar.") }

        // 5) App ID e perfil, depois do certificado (o perfil tem que trazer o certificado que vai assinar).
        avisar("perfil", "Baixando o perfil de provisionamento…", 0.64)
        let appIDs = try await portal.fetchAppIDs(for: time, session: s)
        var appID = appIDs.first(where: { $0.bundleIdentifier.lowercased() == bid.lowercased() })
        if appID == nil {
            appID = try await portal.addAppID(withName: "Agenda", bundleIdentifier: bid, team: time, session: s)
        }
        guard let appID else { throw FalhaRenovacao("App ID não encontrado.") }
        let perfil = try await portal.downloadProvisioningProfile(for: appID, isTeamProfile: true, subPlatform: nil,
                                                                  deviceType: .iPhone, team: time, session: s)
        guard perfil.certificates.contains(where: { Self.mesmoSerial($0.serialNumber, chave.serialNumber) }) else {
            throw FalhaRenovacao("O perfil novo ainda não traz o certificado de assinatura. Tente de novo em alguns minutos.")
        }

        // 6) Reassina (ResignAppOperation): bundle id do app instalado, para atualizar no lugar e manter os dados.
        avisar("assinando", "Assinando a versão \(versaoPacote)…", 0.68)
        try prepararPacote(appURL, bundleID: bid)
        try await AppBundleSigner(team: time, keyStore: chave).signApp(at: appURL, provisioningProfiles: [perfil], progress: nil)
        avisar("empacotando", "Empacotando…", 0.78)
        let ipaAssinada = try FileManager.default.zipAppBundle(at: appURL, compressionLevel: .none)

        // 7) SendAppOperation (AFC) + InstallAppOperation (installation_proxy).
        avisar("enviando", "Enviando para o iPhone…", 0.8)
        try await Aparelho.enviarPacote(ipaAssinada, bundleID: bid, pareamento: pareamento, ip: ip, portaRP: portaRP) { [weak self] f in
            self?.avisar("enviando", "Enviando para o iPhone…", 0.8 + 0.15 * f)
        }
        d.set(["de": atual, "para": versaoPacote, "quando": Date()], forKey: Self.kAtualizacao)
        avisar("instalando", "Instalando a versão \(versaoPacote)… o app fecha sozinho; abra de novo em seguida.", 0.96)
        DispatchQueue.main.async { self.aoInstalar?() }
        try await Aparelho.instalarPacote(bundleID: bid, pareamento: pareamento, ip: ip, portaRP: portaRP)
        avisar("pronto", "Versão \(versaoPacote) instalada.", 1)
        return [
            "de": atual,
            "para": versaoPacote,
            "certificadoNovo": certificadoNovo,
            "validade": iso(perfil.expirationDate),
            "teamId": time.identifier
        ]
    }

    // MARK: certificado

    /// Certificado guardado neste iPhone, se ainda vale no portal (não revogado nem vencido).
    func certificadoGuardado(valeEm lista: [X509Certificate]) -> KeyStore? {
        guard let s = Cofre.ler(.certificado), let i = s.firstIndex(of: ":"),
              let p12 = Data(base64Encoded: String(s[s.index(after: i)...])),
              let c = try? KeyStore(p12Data: p12, password: String(s[..<i])) else { return nil }
        guard let x = lista.first(where: { Self.mesmoSerial($0.serialNumber, c.serialNumber) }), x.expiryDate > Date() else {
            return nil
        }
        return c
    }

    private func guardarCertificado(_ c: KeyStore) throws {
        let senha = c.serialNumber
        let p12 = try c.exportP12(password: senha)
        Cofre.gravar(.certificado, senha + ":" + p12.base64EncodedString())
    }

    /// Como o requestCertificate do SideStore: cria no portal, busca de novo para ter o certificado completo
    /// e junta a chave privada gerada aqui (ela nunca sai do iPhone).
    private func criarCertificado(time: Team, sessao s: Session) async throws -> KeyStore {
        let novo = try await portal.addCertificate(machineName: "Agenda - iPhone", type: .development, to: time, session: s)
        let lista = (try? await portal.fetchCertificates(for: time, session: s)) ?? []
        let x509 = lista.first(where: { Self.mesmoSerial($0.serialNumber, novo.serialNumber) }) ?? novo.certificate
        let chave = KeyStore(certificate: x509, privateKey: novo.privateKey)
        try guardarCertificado(chave)
        return chave
    }

    private func trocarCertificado(_ candidatos: [X509Certificate], time: Team, sessao s: Session) async throws -> KeyStore {
        for c in candidatos.prefix(3) {
            _ = try await portal.revokeCertificate(c, for: time, session: s)
            do { return try await criarCertificado(time: time, sessao: s) }
            catch let e where Self.limiteDeCertificados(e) { continue }
        }
        throw FalhaRenovacao("A Apple não liberou um certificado novo (limite de certificados da conta).")
    }

    static func limiteDeCertificados(_ e: Error) -> Bool {
        if let p = e as? DeveloperPortalError, case .tooManyCertificates = p { return true }
        let m = e.localizedDescription.lowercased()
        return m.contains("maximum number of certificates") || m.contains("already have a current")
    }

    /// Primeiro um certificado antigo deste app (chave perdida), depois os do AltStore/SideStore, depois os mais antigos.
    static func ordemParaRevogar(_ lista: [X509Certificate]) -> [X509Certificate] {
        func prioridade(_ c: X509Certificate) -> Int {
            let n = (c.machineName ?? "").lowercased()
            if n.hasPrefix("agenda") { return 0 }
            if n.contains("altstore") || n.contains("sidestore") { return 1 }
            return 2
        }
        return lista.sorted { a, b in
            let pa = prioridade(a), pb = prioridade(b)
            return pa != pb ? pa < pb : a.creationDate < b.creationDate
        }
    }

    // MARK: pacote

    private func baixar(_ url: URL, para destino: URL) async throws -> URL {
        var observador: NSKeyValueObservation?
        defer { observador?.invalidate() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let pedido = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            let tarefa = URLSession.shared.downloadTask(with: pedido) { tmp, resposta, erro in
                if let erro { cont.resume(throwing: erro); return }
                let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
                guard let tmp, codigo == 200 else {
                    cont.resume(throwing: FalhaRenovacao("Não consegui baixar a versão nova (HTTP \(codigo)).")); return
                }
                do {
                    try? FileManager.default.removeItem(at: destino)
                    try FileManager.default.moveItem(at: tmp, to: destino)
                    cont.resume(returning: destino)
                } catch { cont.resume(throwing: error) }
            }
            observador = tarefa.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                self?.avisar("baixando", "Baixando a versão nova…", 0.15 + 0.4 * p.fractionCompleted)
            }
            tarefa.resume()
        }
    }

    private func lerInfo(_ appURL: URL) throws -> [String: Any] {
        let dados = try Data(contentsOf: appURL.appendingPathComponent("Info.plist"))
        guard let p = try PropertyListSerialization.propertyList(from: dados, format: nil) as? [String: Any] else {
            throw FalhaRenovacao("Info.plist do pacote ilegível.")
        }
        return p
    }

    /// Mesmo preparo do ResignAppOperation.prepare: bundle id do app instalado, sem DTXcode e sem _CodeSignature velho.
    private func prepararPacote(_ appURL: URL, bundleID: String) throws {
        var info = try lerInfo(appURL)
        info["CFBundleIdentifier"] = bundleID
        info.removeValue(forKey: "DTXcode")
        info.removeValue(forKey: "DTXcodeBuild")
        let dados = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try dados.write(to: appURL.appendingPathComponent("Info.plist"), options: .atomic)
        try? FileManager.default.removeItem(at: appURL.appendingPathComponent("_CodeSignature"))
    }

    // MARK: progresso (evento "atualizacao" para o JS)

    func avisar(_ etapa: String, _ texto: String, _ fracao: Double) {
        DispatchQueue.main.async {
            let pct = Int((min(max(fracao, 0), 1) * 100).rounded())
            if self.ultimoProgresso.0 == etapa && self.ultimoProgresso.1 == pct { return }
            self.ultimoProgresso = (etapa, pct)
            self.aoProgredir?(["etapa": etapa, "texto": texto, "progresso": pct])
        }
    }
}
