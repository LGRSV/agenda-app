// Biometria.swift — pede o Face ID (ou o código do iPhone, se o Face ID falhar) antes de renovar ou atualizar a Agenda.
// Pedido do João em 25/11/2026: "renovar só pelo Face ID". A senha do Apple ID guardada no Keychain passa a abrir só
// com o dono presente (ver Cofre.swift); o mesmo LAContext aprovado aqui é usado para ler a senha, sem pedir duas vezes.
// Parte do plugin AgendaRenovacao (AGPL-3.0).
import Foundation
import LocalAuthentication

enum Biometria {
    /// Contexto aprovado da operação em andamento (renovar/atualizar). Fora dela fica nil.
    static var contexto: LAContext?

    /// Mostra o Face ID. Lança FalhaRenovacao se a pessoa cancelar ou o rosto não for reconhecido.
    static func confirmar(_ motivo: String) async throws {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Usar o código do iPhone"
        ctx.localizedCancelTitle = "Cancelar"
        ctx.touchIDAuthenticationAllowableReuseDuration = 60
        var erro: NSError?
        let politica: LAPolicy = .deviceOwnerAuthentication   // Face ID primeiro; o código do iPhone só como reserva
        guard ctx.canEvaluatePolicy(politica, error: &erro) else {
            throw FalhaRenovacao("Ative o Face ID (ou um código no iPhone) para renovar a Agenda.")
        }
        do {
            _ = try await ctx.evaluatePolicy(politica, localizedReason: motivo)
        } catch {
            throw FalhaRenovacao("Renovação cancelada: o Face ID não confirmou.")
        }
        contexto = ctx
    }

    static func encerrar() {
        contexto?.invalidate()
        contexto = nil
    }

    /// Para ler itens protegidos sem nunca abrir o Face ID por conta própria (ex.: tela de estado, segundo plano).
    static func contextoSilencioso() -> LAContext {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        return ctx
    }
}
