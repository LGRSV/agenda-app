// Aparelho.swift — fala com o próprio iPhone pelo serviço misagent (instala/lista perfis de provisionamento)
// e, para atualizar o app, pelo AFC (envia a .ipa) + installation_proxy (instala).
// Usa a biblioteca IDevice (SideStore/idevice), a mesma do backend "idevice" do minimuxer do SideStore
// (DeviceGateway/idevice/IdeviceGateway.swift: performWithTcpService / performWithService + misagent_install).
// O caminho de rede é a VPN de loopback do app LocalDevVPN (o iPhone se enxerga em 10.7.0.1) e o
// "pairing file" gerado uma vez no PC (iloader). Parte do plugin AgendaRenovacao (AGPL-3.0).
import Foundation
import Network
import Darwin
import IDevice

struct FalhaRenovacao: LocalizedError {
    let mensagem: String
    init(_ mensagem: String) { self.mensagem = mensagem }
    var errorDescription: String? { mensagem }
}

enum TipoPareamento: String {
    case lockdown
    case rppairing
}

enum Aparelho {
    static let portaLockdown: UInt16 = 62078   // lockdownd
    static let portaRemotePairing: UInt16 = 49152
    static let ipPadrao = "10.7.0.1"           // LocalDevVPN
    private static let rotulo = "AgendaRenovacao"
    private static let fila = DispatchQueue(label: "agenda.renovacao.idevice")

    // MARK: pairing file

    static func lerPlist(_ dados: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: dados, options: [], format: nil)) as? [String: Any]
    }

    /// Mesma regra do PairingFileParser do minimuxer (chaves obrigatórias de cada formato).
    static func tipo(de dados: Data) throws -> TipoPareamento {
        guard let p = lerPlist(dados) else {
            throw FalhaRenovacao("O arquivo de pareamento não é um plist válido.")
        }
        let lockdown = ["WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey", "HostID",
                        "RootCertificate", "UDID", "EscrowBag", "HostCertificate", "DeviceCertificate"]
        let rp = ["private_key", "public_key", "identifier"]
        let temLockdown = lockdown.allSatisfy { p[$0] != nil }
        let temRP = rp.allSatisfy { p[$0] != nil }
        if temLockdown { return .lockdown }
        if temRP { return .rppairing }
        let faltam = lockdown.filter { p[$0] == nil }
        throw FalhaRenovacao("Arquivo de pareamento incompleto (faltam: \(faltam.joined(separator: ", "))).")
    }

    // MARK: VPN

    /// Testa se a VPN de loopback responde (conexão TCP em ip:porta, com prazo).
    static func vpnResponde(ip: String, porta: UInt16, prazo: TimeInterval = 2.5) async -> Bool {
        final class Uma: @unchecked Sendable {
            private let trava = NSLock()
            private var feito = false
            func primeira() -> Bool { trava.lock(); defer { trava.unlock() }; if feito { return false }; feito = true; return true }
        }
        guard let p = NWEndpoint.Port(rawValue: porta) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let uma = Uma()
            let conexao = NWConnection(host: NWEndpoint.Host(ip), port: p, using: .tcp)
            let fim: (Bool) -> Void = { ok in
                guard uma.primeira() else { return }
                conexao.cancel()
                cont.resume(returning: ok)
            }
            conexao.stateUpdateHandler = { estado in
                switch estado {
                case .ready: fim(true)
                case .failed, .waiting, .cancelled: fim(false)
                default: break
                }
            }
            conexao.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + prazo) { fim(false) }
        }
    }

    // MARK: misagent

    static func instalarPerfil(_ perfil: Data, pareamento: Data, ip: String, portaRP: UInt16) async throws {
        try await emSegundoPlano {
            try Aparelho.comMisagent(pareamento: pareamento, ip: ip, portaRP: portaRP) { cliente in
                try perfil.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        throw FalhaRenovacao("Perfil vazio.")
                    }
                    try Aparelho.checar(misagent_install(cliente, base, perfil.count), "instalar o perfil no iPhone")
                }
            }
        }
    }

    /// Perfis instalados no iPhone (dados brutos .mobileprovision).
    static func perfisInstalados(pareamento: Data, ip: String, portaRP: UInt16) async throws -> [Data] {
        try await emSegundoPlano {
            try Aparelho.comMisagent(pareamento: pareamento, ip: ip, portaRP: portaRP) { cliente in
                var perfis: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
                var tamanhos: UnsafeMutablePointer<Int>? = nil
                var total: Int = 0
                try Aparelho.checar(misagent_copy_all(cliente, &perfis, &tamanhos, &total), "listar os perfis do iPhone")
                defer { if perfis != nil { misagent_free_profiles(perfis, tamanhos, total) } }
                var saida: [Data] = []
                guard let perfis, let tamanhos else { return saida }
                for i in 0..<total {
                    if let p = perfis[i] { saida.append(Data(bytes: p, count: tamanhos[i])) }
                }
                return saida
            }
        }
    }

    // MARK: instalação de app (AFC + installation_proxy)

    // Igual ao IdeviceGateway do minimuxer (sendIpaAfc + installIpa): a .ipa vai pelo AFC para
    // PublicStaging/<bundle id>/app.ipa e o installation_proxy instala (atualiza, se o app já existe).
    typealias ConectaLockdown = (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?
    typealias ConectaRSD = (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?
    static let pastaStaging = "PublicStaging"

    static func enviarPacote(_ ipa: URL, bundleID: String, pareamento: Data, ip: String, portaRP: UInt16,
                             progresso: @escaping (Double) -> Void) async throws {
        let dados = try Data(contentsOf: ipa, options: .mappedIfSafe)
        guard !dados.isEmpty else { throw FalhaRenovacao("Pacote vazio.") }
        try await emSegundoPlano {
            try Aparelho.comServico(pareamento: pareamento, ip: ip, portaRP: portaRP, nome: "AFC",
                                    lockdown: afc_client_connect, rsd: afc_client_connect_rsd,
                                    liberar: afc_client_free) { cliente in
                let pasta = "\(Aparelho.pastaStaging)/\(bundleID)"
                // As pastas podem já existir e a sobra de uma tentativa anterior pode não existir: erros ignorados.
                Aparelho.ignorar(Aparelho.pastaStaging.withCString { afc_make_directory(cliente, $0) })
                Aparelho.ignorar(pasta.withCString { afc_remove_path_and_contents(cliente, $0) })
                Aparelho.ignorar(pasta.withCString { afc_make_directory(cliente, $0) })
                var arquivo: OpaquePointer? = nil
                try Aparelho.checar("\(pasta)/app.ipa".withCString { afc_file_open(cliente, $0, AfcFopenMode(rawValue: 4), &arquivo) },
                           "abrir o arquivo no iPhone (AFC)")
                guard let arquivo else { throw FalhaRenovacao("O AFC não abriu o arquivo no iPhone.") }
                defer { Aparelho.ignorar(afc_file_close(arquivo)) }
                try dados.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        throw FalhaRenovacao("Pacote vazio.")
                    }
                    let bloco = 1 << 20
                    var feito = 0
                    while feito < dados.count {
                        let n = min(bloco, dados.count - feito)
                        try Aparelho.checar(afc_file_write(arquivo, base + feito, n), "enviar o pacote para o iPhone (AFC)")
                        feito += n
                        progresso(Double(feito) / Double(dados.count))
                    }
                }
            }
        }
    }

    static func instalarPacote(bundleID: String, pareamento: Data, ip: String, portaRP: UInt16) async throws {
        try await emSegundoPlano {
            try Aparelho.comServico(pareamento: pareamento, ip: ip, portaRP: portaRP, nome: "installation_proxy",
                                    lockdown: installation_proxy_connect, rsd: installation_proxy_connect_rsd,
                                    liberar: installation_proxy_client_free) { cliente in
                try Aparelho.checar("\(Aparelho.pastaStaging)/\(bundleID)/app.ipa".withCString { installation_proxy_install(cliente, $0, nil) },
                           "instalar a versão nova")
            }
        }
    }

    // MARK: internos

    private static func emSegundoPlano<T>(_ trabalho: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            fila.async {
                do { cont.resume(returning: try trabalho()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func checar(_ erro: UnsafeMutablePointer<IdeviceFfiError>?, _ etapa: String) throws {
        guard let erro else { return }
        let codigo = erro.pointee.code
        let msg = erro.pointee.message.map { String(cString: $0) } ?? "sem detalhe"
        if Int(bitPattern: erro) > 0xff { idevice_error_free(erro) }
        throw FalhaRenovacao("Não consegui \(etapa): \(msg) (código \(codigo)).")
    }

    private static func comSockaddr<R>(ip: String, porta: UInt16,
                                       _ corpo: (UnsafePointer<sockaddr>, socklen_t) throws -> R) throws -> R {
        var end = sockaddr_in()
        end.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        end.sin_family = sa_family_t(AF_INET)
        end.sin_port = porta.bigEndian
        guard inet_pton(AF_INET, ip, &end.sin_addr) == 1 else {
            throw FalhaRenovacao("Endereço IP inválido: \(ip)")
        }
        return try withUnsafePointer(to: &end) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                try corpo(sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func ignorar(_ erro: UnsafeMutablePointer<IdeviceFfiError>?) {
        if let erro, Int(bitPattern: erro) > 0xff { idevice_error_free(erro) }
    }

    /// Mesmo caminho do comMisagent (pairing lockdown -> provider TCP; RemotePairing -> túnel RSD),
    /// para qualquer serviço (AFC, installation_proxy). Uma conexão nova por chamada, como o minimuxer.
    private static func comServico<T>(pareamento: Data, ip: String, portaRP: UInt16, nome: String,
                                      lockdown: ConectaLockdown, rsd: ConectaRSD,
                                      liberar: (OpaquePointer?) -> Void,
                                      _ acao: (OpaquePointer) throws -> T) throws -> T {
        switch try tipo(de: pareamento) {
        case .lockdown:
            var arquivo: OpaquePointer? = nil
            try pareamento.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try checar(idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                           UInt(pareamento.count), &arquivo),
                           "ler o arquivo de pareamento")
            }
            guard let arquivo else { throw FalhaRenovacao("Arquivo de pareamento ilegível.") }
            var provedor: OpaquePointer? = nil
            // O provider consome o pairing file (não liberar depois).
            let erroProv = try comSockaddr(ip: ip, porta: portaLockdown) { sa, _ in
                idevice_tcp_provider_new(sa, arquivo, rotulo, &provedor)
            }
            try checar(erroProv, "abrir conexão com o iPhone em \(ip)")
            guard let provedor else { throw FalhaRenovacao("Conexão com o iPhone não criada.") }
            var cliente: OpaquePointer? = nil
            if let erro = lockdown(provedor, &cliente) {
                // Como no minimuxer: em erro o provider não é liberado aqui.
                try checar(erro, "abrir o serviço \(nome) (VPN ligada? pareamento certo?)")
            }
            defer { idevice_provider_free(provedor) }
            guard let cliente else { throw FalhaRenovacao("Serviço \(nome) não respondeu.") }
            defer { liberar(cliente) }
            return try acao(cliente)

        case .rppairing:
            var arquivo: OpaquePointer? = nil
            try pareamento.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try checar(rp_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                      UInt(pareamento.count), &arquivo),
                           "ler o arquivo de pareamento (RemotePairing)")
            }
            guard let arquivo else { throw FalhaRenovacao("Arquivo de pareamento ilegível.") }
            defer { rp_pairing_file_free(arquivo) }
            var adaptador: OpaquePointer? = nil
            var aperto: OpaquePointer? = nil
            let erroTunel = try comSockaddr(ip: ip, porta: portaRP) { sa, tam in
                rotulo.withCString { host in
                    tunnel_create_rppairing_with_options(sa, tam, host, arquivo, false, nil, nil, &adaptador, &aperto)
                }
            }
            try checar(erroTunel, "abrir o túnel RemotePairing em \(ip):\(portaRP)")
            defer {
                if let aperto { rsd_handshake_free(aperto) }
                if let adaptador { adapter_free(adaptador) }
            }
            var cliente: OpaquePointer? = nil
            try checar(rsd(adaptador, aperto, &cliente), "abrir o serviço \(nome) (RSD)")
            guard let cliente else { throw FalhaRenovacao("Serviço \(nome) não respondeu.") }
            defer { liberar(cliente) }
            return try acao(cliente)
        }
    }

    private static func comMisagent<T>(pareamento: Data, ip: String, portaRP: UInt16,
                                       _ acao: (OpaquePointer) throws -> T) throws -> T {
        switch try tipo(de: pareamento) {
        case .lockdown:
            // Igual ao IdeviceGateway.performWithTcpService: pairing file -> provider TCP (lockdownd) -> misagent.
            var arquivo: OpaquePointer? = nil
            try pareamento.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try checar(idevice_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                           UInt(pareamento.count), &arquivo),
                           "ler o arquivo de pareamento")
            }
            guard let arquivo else { throw FalhaRenovacao("Arquivo de pareamento ilegível.") }
            var provedor: OpaquePointer? = nil
            // O provider consome o pairing file (não liberar depois).
            let erroProv = try comSockaddr(ip: ip, porta: portaLockdown) { sa, _ in
                idevice_tcp_provider_new(sa, arquivo, rotulo, &provedor)
            }
            try checar(erroProv, "abrir conexão com o iPhone em \(ip)")
            guard let provedor else { throw FalhaRenovacao("Conexão com o iPhone não criada.") }
            var cliente: OpaquePointer? = nil
            if let erro = misagent_connect(provedor, &cliente) {
                // Como no minimuxer: em erro o provider não é liberado aqui.
                try checar(erro, "abrir o serviço misagent (VPN ligada? pareamento certo?)")
            }
            defer { idevice_provider_free(provedor) }
            guard let cliente else { throw FalhaRenovacao("Serviço misagent não respondeu.") }
            defer { misagent_client_free(cliente) }
            return try acao(cliente)

        case .rppairing:
            // Igual ao IdeviceGateway.ensureRPConnection + performWithService (RemotePairing -> RSD -> misagent).
            var arquivo: OpaquePointer? = nil
            try pareamento.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try checar(rp_pairing_file_from_bytes(buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                      UInt(pareamento.count), &arquivo),
                           "ler o arquivo de pareamento (RemotePairing)")
            }
            guard let arquivo else { throw FalhaRenovacao("Arquivo de pareamento ilegível.") }
            defer { rp_pairing_file_free(arquivo) }
            var adaptador: OpaquePointer? = nil
            var aperto: OpaquePointer? = nil
            let erroTunel = try comSockaddr(ip: ip, porta: portaRP) { sa, tam in
                rotulo.withCString { host in
                    tunnel_create_rppairing_with_options(sa, tam, host, arquivo, false, nil, nil, &adaptador, &aperto)
                }
            }
            try checar(erroTunel, "abrir o túnel RemotePairing em \(ip):\(portaRP)")
            defer {
                if let aperto { rsd_handshake_free(aperto) }
                if let adaptador { adapter_free(adaptador) }
            }
            var cliente: OpaquePointer? = nil
            try checar(misagent_connect_rsd(adaptador, aperto, &cliente), "abrir o serviço misagent (RSD)")
            guard let cliente else { throw FalhaRenovacao("Serviço misagent não respondeu.") }
            defer { misagent_client_free(cliente) }
            return try acao(cliente)
        }
    }
}
