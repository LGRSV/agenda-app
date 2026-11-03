// AgendaRenovacaoPlugin.swift — ponte Capacitor (JS: Capacitor.registerPlugin('AgendaRenovacao')).
// Métodos: estado, entrar, enviarCodigo, cancelarEntrada, sair, salvarPareamento, apagarPareamento, renovar.
// Evento: "codigo2fa" {modo, erro?, telefone?} -> responder com enviarCodigo({codigo}) ou enviarCodigo({sms:true}).
// Parte do plugin AgendaRenovacao (AGPL-3.0), baseado no fluxo de renovação do SideStore.
// ATENÇÃO: só este arquivo pode ter a anotação objc com nome — o Capacitor CLI procura ela para registrar o plugin.
import Foundation
import Capacitor

@objc(AgendaRenovacaoPlugin)
public class AgendaRenovacaoPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AgendaRenovacaoPlugin"
    public let jsName = "AgendaRenovacao"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "estado", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "entrar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enviarCodigo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelarEntrada", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sair", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "salvarPareamento", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "apagarPareamento", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "renovar", returnType: CAPPluginReturnPromise)
    ]

    private let motor = Renovador.shared

    override public func load() {
        motor.aoPedirCodigo = { [weak self] info in
            self?.notifyListeners("codigo2fa", data: info)
        }
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
}
