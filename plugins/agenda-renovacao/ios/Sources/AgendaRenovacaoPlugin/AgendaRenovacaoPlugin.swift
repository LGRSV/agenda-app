// AgendaRenovacaoPlugin.swift — ponte Capacitor (JS: Capacitor.registerPlugin('AgendaRenovacao')).
// Métodos: estado, entrar, enviarCodigo, cancelarEntrada, sair, salvarPareamento, apagarPareamento, renovar, iconeAtual, trocarIcone,
//          versaoDisponivel, atualizar ({revogar?, forcar?}), ligarVpn.
// Eventos: "codigo2fa" {modo, erro?, telefone?} -> responder com enviarCodigo({codigo}) ou enviarCodigo({sms:true});
//          "atualizacao" {etapa, texto, progresso 0-100} durante atualizar().
// Parte do plugin AgendaRenovacao (AGPL-3.0), baseado no fluxo de renovação do SideStore.
// ATENÇÃO: só este arquivo pode ter a anotação objc com nome — o Capacitor CLI procura ela para registrar o plugin.
import Foundation
import UIKit
import Capacitor

@objc(AgendaRenovacaoPlugin)
public class AgendaRenovacaoPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AgendaRenovacaoPlugin"
    public let jsName = "AgendaRenovacao"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "estado", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "entrar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "entrarNativo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enviarCodigo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelarEntrada", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sair", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "salvarPareamento", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "apagarPareamento", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "renovar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "iconeAtual", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "trocarIcone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "versaoDisponivel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "atualizar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ligarVpn", returnType: CAPPluginReturnPromise)
    ]

    private let motor = Renovador.shared
    private var tarefaFundo: UIBackgroundTaskIdentifier = .invalid

    override public func load() {
        motor.aoPedirCodigo = { [weak self] info in
            self?.notifyListeners("codigo2fa", data: info)
        }
        motor.aoProgredir = { [weak self] info in
            self?.notifyListeners("atualizacao", data: info)
        }
        motor.aoInstalar = { [weak self] in self?.sairParaTelaInicial() }
    }

    private func lerIP(_ call: CAPPluginCall) -> String {
        let s = (call.getString("ip") ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? Aparelho.ipPadrao : s
    }

    private func lerPorta(_ call: CAPPluginCall) -> UInt16 {
        let p = call.getInt("porta") ?? Int(Aparelho.portaRemotePairing)
        return (1...65535).contains(p) ? UInt16(p) : Aparelho.portaRemotePairing
    }

    private func rejeitar(_ call: CAPPluginCall, _ erro: Error) {
        call.reject(erro.localizedDescription, nil, nil, ["mensagem": erro.localizedDescription])
    }

    @objc func estado(_ call: CAPPluginCall) {
        let ip = lerIP(call), porta = lerPorta(call), aparelho = call.getBool("aparelho") ?? false
        Task {
            let r = await motor.estado(ip: ip, portaRP: porta, lerAparelho: aparelho)
            call.resolve(r)
        }
    }

    @objc func entrar(_ call: CAPPluginCall) {
        guard let id = call.getString("appleId"), !id.isEmpty,
              let senha = call.getString("senha"), !senha.isEmpty else {
            call.reject("Informe Apple ID e senha.")
            return
        }
        Task {
            do { call.resolve(try await motor.entrar(appleID: id, senha: senha)) }
            catch { rejeitar(call, error) }
        }
    }

    /// Login com janela NATIVA do iOS: Apple ID e senha nunca passam pelo JavaScript da página
    /// (que vem da internet). O JS só recebe o resultado (nome e Apple ID mascarado).
    @objc func entrarNativo(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let vc = self.bridge?.viewController else {
                call.reject("Tela indisponível.")
                return
            }
            let alerta = UIAlertController(title: "Entrar com o Apple ID",
                                           message: "Use o mesmo Apple ID do AltStore. A senha fica só no Keychain deste iPhone.",
                                           preferredStyle: .alert)
            alerta.addTextField { t in
                t.placeholder = "Apple ID (e-mail)"
                t.keyboardType = .emailAddress
                t.textContentType = .username
                t.autocapitalizationType = .none
                t.autocorrectionType = .no
            }
            alerta.addTextField { t in
                t.placeholder = "Senha"
                t.isSecureTextEntry = true
                t.textContentType = .password
            }
            alerta.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in
                call.reject("Cancelado.")
            })
            alerta.addAction(UIAlertAction(title: "Entrar", style: .default) { [weak self] _ in
                let id = (alerta.textFields?[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let senha = alerta.textFields?[1].text ?? ""
                guard let self, !id.isEmpty, !senha.isEmpty else {
                    call.reject("Informe Apple ID e senha.")
                    return
                }
                Task {
                    do { call.resolve(try await self.motor.entrar(appleID: id, senha: senha)) }
                    catch { self.rejeitar(call, error) }
                }
            })
            vc.present(alerta, animated: true)
        }
    }

    @objc func enviarCodigo(_ call: CAPPluginCall) {
        let ok = motor.responderCodigo(codigo: call.getString("codigo"), sms: call.getBool("sms") ?? false, cancelar: false)
        call.resolve(["aceito": ok])
    }

    @objc func cancelarEntrada(_ call: CAPPluginCall) {
        let ok = motor.responderCodigo(codigo: nil, sms: false, cancelar: true)
        call.resolve(["cancelado": ok])
    }

    @objc func sair(_ call: CAPPluginCall) {
        motor.sair()
        call.resolve()
    }

    @objc func salvarPareamento(_ call: CAPPluginCall) {
        var dados: Data? = nil
        if let b64 = call.getString("base64"), !b64.isEmpty {
            dados = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        } else if let texto = call.getString("conteudo"), !texto.isEmpty {
            dados = texto.data(using: .utf8)
        }
        guard let dados else {
            call.reject("Arquivo de pareamento vazio.")
            return
        }
        do { call.resolve(try motor.salvarPareamento(dados)) }
        catch { rejeitar(call, error) }
    }

    @objc func apagarPareamento(_ call: CAPPluginCall) {
        motor.apagarPareamento()
        call.resolve()
    }

    @objc func renovar(_ call: CAPPluginCall) {
        let ip = lerIP(call), porta = lerPorta(call)
        Task {
            do { call.resolve(try await motor.renovar(ip: ip, portaRP: porta)) }
            catch { rejeitar(call, error) }
        }
    }

    // MARK: atualização do app (Atualizador.swift)

    @objc func versaoDisponivel(_ call: CAPPluginCall) {
        Task { call.resolve(await motor.versaoDisponivel()) }
    }

    @objc func atualizar(_ call: CAPPluginCall) {
        let ip = lerIP(call), porta = lerPorta(call)
        let revogar = call.getBool("revogar") ?? false, forcar = call.getBool("forcar") ?? false
        Task {
            do {
                call.resolve(try await motor.atualizar(ip: ip, portaRP: porta, revogar: revogar, forcar: forcar))
            } catch let e as PrecisaRevogar {
                call.reject(e.localizedDescription, "PRECISA_REVOGAR", nil,
                            ["mensagem": e.localizedDescription, "certificados": e.certificados])
            } catch {
                rejeitar(call, error)
            }
            DispatchQueue.main.async { [weak self] in self?.encerrarTarefaFundo() }
        }
    }

    /// Como o InstallAppOperation.handleSelfReinstallation do SideStore: reinstalar o próprio app só termina
    /// quando ele sai da frente. Segura o processo em segundo plano e vai para a tela inicial (sem forçar o fechamento).
    private func sairParaTelaInicial() {
        let app = UIApplication.shared
        encerrarTarefaFundo()
        tarefaFundo = app.beginBackgroundTask(withName: "AtualizarAgenda") { [weak self] in self?.encerrarTarefaFundo() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard app.applicationState == .active else { return }
            _ = app.perform(#selector(NSXPCConnection.suspend))
        }
    }

    private func encerrarTarefaFundo() {
        guard tarefaFundo != .invalid else { return }
        UIApplication.shared.endBackgroundTask(tarefaFundo)
        tarefaFundo = .invalid
    }

    /// Abre o LocalDevVPN pelo link dele (localdevvpn://enable?scheme=...): ele liga o túnel e,
    /// 1 s depois, abre o esquema de volta (o deste app, se o Info.plist tiver um).
    @objc func ligarVpn(_ call: CAPPluginCall) {
        let tipos = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let esquemas = tipos.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        let volta = esquemas.first(where: { $0 == "agenda-lgrsv" }) ?? esquemas.first
        var c = URLComponents()
        c.scheme = "localdevvpn"
        c.host = "enable"
        if let volta { c.queryItems = [URLQueryItem(name: "scheme", value: volta)] }
        guard let url = c.url else { call.reject("Link do LocalDevVPN inválido."); return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                call.resolve(["aberto": ok, "volta": volta ?? ""])
            }
        }
    }

    // Ícones alternativos (ex.: "AC"), embutidos no app pelo build. "" volta ao ícone padrão (JL).
    @objc func iconeAtual(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve([
                "icone": UIApplication.shared.alternateIconName ?? "",
                "suporta": UIApplication.shared.supportsAlternateIcons
            ])
        }
    }

    @objc func trocarIcone(_ call: CAPPluginCall) {
        let nome = (call.getString("nome") ?? "").trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                call.reject("Este iPhone não permite trocar o ícone.")
                return
            }
            let alvo: String? = nome.isEmpty ? nil : nome
            if UIApplication.shared.alternateIconName == alvo {
                call.resolve(["icone": nome, "mudou": false])
                return
            }
            UIApplication.shared.setAlternateIconName(alvo) { erro in
                if let erro = erro { call.reject(erro.localizedDescription) }
                else { call.resolve(["icone": nome, "mudou": true]) }
            }
        }
    }
}
