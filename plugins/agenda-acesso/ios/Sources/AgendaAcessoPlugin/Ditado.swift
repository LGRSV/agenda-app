// Ditado.swift — fala -> texto com o SFSpeechRecognizer, de preferência NO APARELHO
// (requiresOnDeviceRecognition). O áudio não é gravado em arquivo nem enviado pelo app.
import Foundation
import AVFoundation
import Speech

struct Falha: LocalizedError {
    let codigo: String
    let errorDescription: String?
    init(_ texto: String, codigo: String = "FALHA") {
        self.codigo = codigo
        self.errorDescription = texto
    }
}

final class Ditado {
    private let motor = AVAudioEngine()
    private var pedido: SFSpeechAudioBufferRecognitionRequest?
    private var tarefa: SFSpeechRecognitionTask?
    private var sessaoAtual = 0
    private var aoTerminar: ((String) -> Void)?
    private(set) var texto = ""
    private(set) var ativo = false
    /// Chamado (na fila principal) a cada trecho reconhecido: {texto, final, fim?}.
    var aoMudar: (([String: Any]) -> Void)?

    /// Começa a ouvir. Devolve true se o reconhecimento é feito no próprio iPhone.
    /// soNoAparelho = true: sem modelo local, falha com SEM_MODELO_LOCAL (nada sai do iPhone).
    func iniciar(idioma: String, soNoAparelho: Bool, segundosMax: Double) throws -> Bool {
        parar(cancelar: true)
        guard let reco = SFSpeechRecognizer(locale: Locale(identifier: idioma)) else {
            throw Falha("O iPhone não reconhece fala em \(idioma).", codigo: "SEM_IDIOMA")
        }
        let local = reco.supportsOnDeviceRecognition
        if soNoAparelho && !local {
            throw Falha("Este iPhone não tem o ditado em português no aparelho. Sem ele a transcrição passaria pelos servidores da Apple.", codigo: "SEM_MODELO_LOCAL")
        }
        guard reco.isAvailable else {
            throw Falha("O reconhecimento de fala está indisponível agora. Tente de novo em instantes.", codigo: "INDISPONIVEL")
        }
        let sessao = AVAudioSession.sharedInstance()
        try sessao.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try sessao.setActive(true, options: .notifyOthersOnDeactivation)

        let p = SFSpeechAudioBufferRecognitionRequest()
        p.shouldReportPartialResults = true
        if local { p.requiresOnDeviceRecognition = true }
        if #available(iOS 16, *) { p.addsPunctuation = true }

        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        guard formato.sampleRate > 0, formato.channelCount > 0 else {
            try? sessao.setActive(false, options: .notifyOthersOnDeactivation)
            throw Falha("Microfone indisponível (outro app pode estar usando).", codigo: "SEM_MICROFONE")
        }
        entrada.removeTap(onBus: 0)
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { buffer, _ in
            p.append(buffer)
        }
        motor.prepare()
        do {
            try motor.start()
        } catch {
            entrada.removeTap(onBus: 0)
            try? sessao.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        pedido = p
        texto = ""
        ativo = true
        sessaoAtual += 1
        let minha = sessaoAtual
        tarefa = reco.recognitionTask(with: p) { [weak self] resultado, erro in
            let t = resultado?.bestTranscription.formattedString
            let final = resultado?.isFinal ?? false
            DispatchQueue.main.async {
                guard let self, self.sessaoAtual == minha, self.ativo else { return }
                if let t {
                    self.texto = t
                    self.aoMudar?(["texto": t, "final": final])
                }
                if erro != nil || final { self.encerrar() }
            }
        }
        // Trava de segurança: para sozinho no limite de tempo.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(5, min(segundosMax, 120))) { [weak self] in
            guard let self, self.sessaoAtual == minha, self.ativo else { return }
            self.parar()
        }
        return local
    }

    /// Para de ouvir. cancelar = true descarta na hora; senão espera o resultado final (até 2 s).
    func parar(cancelar: Bool = false, pronto: ((String) -> Void)? = nil) {
        guard ativo else { pronto?(texto); return }
        if cancelar {
            tarefa?.cancel()
            encerrar()
            pronto?(texto)
            return
        }
        aoTerminar = pronto
        if motor.isRunning { motor.stop() }
        motor.inputNode.removeTap(onBus: 0)
        pedido?.endAudio()
        let minha = sessaoAtual
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.sessaoAtual == minha else { return }
            self.encerrar()
        }
    }

    private func encerrar() {
        guard ativo else { return }
        ativo = false
        if motor.isRunning { motor.stop() }
        motor.inputNode.removeTap(onBus: 0)
        pedido?.endAudio()
        tarefa?.cancel()
        pedido = nil
        tarefa = nil
        let sessao = AVAudioSession.sharedInstance()
        try? sessao.setActive(false, options: .notifyOthersOnDeactivation)
        try? sessao.setCategory(.playback, mode: .default, options: [])
        let fim = aoTerminar
        aoTerminar = nil
        aoMudar?(["texto": texto, "final": true, "fim": true])
        fim?(texto)
    }
}
