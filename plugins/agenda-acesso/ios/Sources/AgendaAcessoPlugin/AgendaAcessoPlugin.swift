// AgendaAcessoPlugin.swift — ponte Capacitor "AgendaAcesso" (a página remota chama por nativePromise).
// Métodos: estado, ditadoIniciar({idioma?, soNoAparelho?, segundosMax?}), ditadoParar({cancelar?}),
//          contatosBuscar({termo, limite?}), contatoNovo({nome?, telefone?}),
//          calendarioEventos({inicio, fim} em ms), calendarioCriar({titulo, inicio, fim, notas?}),
//          fotoEscolher({max?, largura?}), fotoSalvar({base64, tipo?}),
//          arquivoEscolher({maxMB?}), arquivoExportar({base64 | texto, nome}), arquivoAbrir({base64, nome}),
//          saudeEstado.
// Evento: "ditado" {texto, final, fim?}.
// Regras: cada permissão só é pedida quando o usuário toca na função; fotos e arquivos usam os seletores do
// sistema (sem acesso à biblioteca inteira); nada é enviado para fora do iPhone por este plugin.
// ATENÇÃO: só este arquivo pode ter a anotação objc com nome — o Capacitor CLI procura ela para registrar o plugin.
import Foundation
import UIKit
import Capacitor
import AVFoundation
import Speech
import Contacts
import ContactsUI
import EventKit
import EventKitUI
import Photos
import PhotosUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers

@objc(AgendaAcessoPlugin)
public class AgendaAcessoPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AgendaAcessoPlugin"
    public let jsName = "AgendaAcesso"
    public let pluginMethods: [CAPPluginMethod] = [
        "estado", "ditadoIniciar", "ditadoParar",
        "contatosBuscar", "contatoNovo",
        "calendarioEventos", "calendarioCriar",
        "fotoEscolher", "fotoSalvar",
        "arquivoEscolher", "arquivoExportar", "arquivoAbrir",
        "saudeEstado"
    ].map { CAPPluginMethod(name: $0, returnType: CAPPluginReturnPromise) }

    private let ditado = Ditado()
    private let agenda = EKEventStore()
    private var chamadaTela: CAPPluginCall?      // um seletor/tela do sistema por vez
    private var modoDocumento = ""               // "abrir" | "exportar"
    private var limiteBytes = 15 * 1024 * 1024
    private var larguraFoto: CGFloat = 1600
    private var arquivoPrevia: URL?

    override public func load() {
        ditado.aoMudar = { [weak self] dados in self?.notifyListeners("ditado", data: dados) }
    }

    // MARK: utilidades

    private func rejeitar(_ call: CAPPluginCall, _ erro: Error) {
        let codigo = (erro as? Falha)?.codigo
        call.reject(erro.localizedDescription, codigo, nil, ["mensagem": erro.localizedDescription])
    }

    /// Guarda a chamada que espera uma tela do sistema; se havia outra pendente, ela termina como cancelada.
    private func guardarChamada(_ call: CAPPluginCall) {
        if let antiga = chamadaTela { antiga.resolve(["cancelado": true]) }
        chamadaTela = call
    }

    private func terminar(_ dados: [String: Any]) {
        let c = chamadaTela
        chamadaTela = nil
        c?.resolve(dados)
    }

    private func apresentar(_ vc: UIViewController, _ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            guard let base = self?.bridge?.viewController else {
                call.reject("Tela indisponível.")
                if self?.chamadaTela === call { self?.chamadaTela = nil }
                return
            }
            var topo = base
            while let p = topo.presentedViewController { topo = p }
            topo.present(vc, animated: true)
        }
    }

    private func dadosBase64(_ call: CAPPluginCall) -> Data? {
        guard var s = call.getString("base64"), !s.isEmpty else { return nil }
        if s.hasPrefix("data:"), let i = s.firstIndex(of: ",") { s = String(s[s.index(after: i)...]) }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    private func nomeSeguro(_ nome: String?, padrao: String) -> String {
        let n = (nome ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? padrao : String(n.prefix(120))
    }

    private func arquivoTemporario(_ dados: Data, nome: String) throws -> URL {
        let pasta = FileManager.default.temporaryDirectory.appendingPathComponent("agenda-acesso", isDirectory: true)
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let url = pasta.appendingPathComponent(nome)
        try? FileManager.default.removeItem(at: url)
        try dados.write(to: url, options: .atomic)
        return url
    }

    private static func mime(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: estado das permissões (não pede nada)

    private func statusMicrofone() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "prompt"
        }
    }

    private func statusFala() -> String {
        switch SFSpeechRecognizer.authorizationStatus().rawValue {
        case 3: return "granted"
        case 2: return "denied"
        case 1: return "restricted"
        default: return "prompt"
        }
    }

    private func statusContatos() -> String {
        // 0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited (iOS 18)
        switch CNContactStore.authorizationStatus(for: .contacts).rawValue {
        case 3: return "granted"
        case 4: return "limited"
        case 2: return "denied"
        case 1: return "restricted"
        default: return "prompt"
        }
    }

    private func statusCalendario() -> String {
        // 0 notDetermined, 1 restricted, 2 denied, 3 fullAccess/authorized, 4 writeOnly (iOS 17)
        switch EKEventStore.authorizationStatus(for: .event).rawValue {
        case 3: return "granted"
        case 4: return "writeOnly"
        case 2: return "denied"
        case 1: return "restricted"
        default: return "prompt"
        }
    }

    private func statusFotosAdicionar() -> String {
        // 0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue {
        case 3, 4: return "granted"
        case 2: return "denied"
        case 1: return "restricted"
        default: return "prompt"
        }
    }

    /// O perfil de provisionamento instalado libera HealthKit? (conta grátis + reassinatura atual: não)
    private func perfilTemSaude() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let dados = try? Data(contentsOf: url) else { return false }
        let texto = String(decoding: dados, as: UTF8.self)
        return texto.contains("com.apple.developer.healthkit")
    }

    @objc func estado(_ call: CAPPluginCall) {
        call.resolve([
            "versao": 1,
            "microfone": statusMicrofone(),
            "fala": statusFala(),
            "contatos": statusContatos(),
            "calendario": statusCalendario(),
            "fotosAdicionar": statusFotosAdicionar(),
            "saude": perfilTemSaude() ? "perfil" : "indisponivel"
        ])
    }

    // MARK: ditado

    private func pedirDitado(_ fim: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            guard st == .authorized else {
                fim(false, "Sem permissão para o reconhecimento de fala. Libere em Ajustes > Agenda.")
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                fim(ok, ok ? "" : "Sem permissão para o microfone. Libere em Ajustes > Agenda > Microfone.")
            }
        }
    }

    @objc func ditadoIniciar(_ call: CAPPluginCall) {
        let idioma = call.getString("idioma") ?? "pt-BR"
        let soNoAparelho = call.getBool("soNoAparelho") ?? true
        let segundos = call.getDouble("segundosMax") ?? 60
        pedirDitado { [weak self] ok, motivo in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    call.reject(motivo, "SEM_PERMISSAO", nil, ["mensagem": motivo])
                    return
                }
                do {
                    let local = try self.ditado.iniciar(idioma: idioma, soNoAparelho: soNoAparelho, segundosMax: segundos)
                    call.resolve(["iniciado": true, "noAparelho": local])
                } catch {
                    self.rejeitar(call, error)
                }
            }
        }
    }

    @objc func ditadoParar(_ call: CAPPluginCall) {
        let cancelar = call.getBool("cancelar") ?? false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ditado.parar(cancelar: cancelar) { texto in call.resolve(["texto": texto]) }
        }
    }

    // MARK: contatos (só leitura; criar só pela tela do sistema, quando pedido)

    private func pedirContatos(_ fim: @escaping (Bool) -> Void) {
        let s = statusContatos()
        if s == "granted" || s == "limited" { fim(true); return }
        if s != "prompt" { fim(false); return }
        CNContactStore().requestAccess(for: .contacts) { ok, _ in fim(ok) }
    }

    private func contatoJSON(_ c: CNContact) -> [String: Any] {
        var nome = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        if nome.isEmpty { nome = c.organizationName }
        let tels: [[String: Any]] = c.phoneNumbers.map { v -> [String: Any] in
            ["rotulo": v.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "",
             "numero": v.value.stringValue]
        }
        return ["id": c.identifier, "nome": nome, "telefones": tels]
    }

    @objc func contatosBuscar(_ call: CAPPluginCall) {
        let termo = (call.getString("termo") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limite = min(max(call.getInt("limite") ?? 30, 1), 100)
        pedirContatos { [weak self] ok in
            guard let self else { return }
            guard ok else {
                call.reject("Sem permissão para os contatos. Libere em Ajustes > Agenda > Contatos.", "SEM_PERMISSAO", nil,
                            ["status": self.statusContatos()])
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let loja = CNContactStore()
                let chaves: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
                ]
                var lista: [[String: Any]] = []
                do {
                    let digitos = termo.filter { $0.isNumber }
                    if termo.isEmpty {
                        let req = CNContactFetchRequest(keysToFetch: chaves)
                        req.sortOrder = .userDefault
                        try loja.enumerateContacts(with: req) { c, parar in
                            lista.append(self.contatoJSON(c))
                            if lista.count >= limite { parar.pointee = true }
                        }
                    } else {
                        let pred: NSPredicate = digitos.count >= 4 && digitos.count >= termo.count - 4
                            ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: termo))
                            : CNContact.predicateForContacts(matchingName: termo)
                        for c in try loja.unifiedContacts(matching: pred, keysToFetch: chaves).prefix(limite) {
                            lista.append(self.contatoJSON(c))
                        }
                    }
                    call.resolve(["contatos": lista, "status": self.statusContatos()])
                } catch {
                    self.rejeitar(call, error)
                }
            }
        }
    }

    @objc func contatoNovo(_ call: CAPPluginCall) {
        let nome = (call.getString("nome") ?? "").trimmingCharacters(in: .whitespaces)
        let tel = (call.getString("telefone") ?? "").trimmingCharacters(in: .whitespaces)
        pedirContatos { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else {
                    call.reject("Sem permissão para os contatos. Libere em Ajustes > Agenda > Contatos.", "SEM_PERMISSAO")
                    return
                }
                let c = CNMutableContact()
                if !nome.isEmpty {
                    let partes = nome.split(separator: " ", maxSplits: 1).map(String.init)
                    c.givenName = partes[0]
                    if partes.count > 1 { c.familyName = partes[1] }
                }
                if !tel.isEmpty {
                    c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: tel))]
                }
                let vc = CNContactViewController(forNewContact: c)
                vc.contactStore = CNContactStore()
                vc.delegate = self
                self.guardarChamada(call)
                self.apresentar(UINavigationController(rootViewController: vc), call)
            }
        }
    }

    // MARK: calendário (ler eventos; criar só pela tela do sistema)

    private func pedirCalendario(_ fim: @escaping (Bool) -> Void) {
        let s = statusCalendario()
        if s == "granted" { fim(true); return }
        if s != "prompt" && s != "writeOnly" { fim(false); return }
        if #available(iOS 17.0, *) {
            agenda.requestFullAccessToEvents { ok, _ in fim(ok) }
        } else {
            agenda.requestAccess(to: .event) { ok, _ in fim(ok) }
        }
    }

    @objc func calendarioEventos(_ call: CAPPluginCall) {
        guard let ini = call.getDouble("inicio"), let fim = call.getDouble("fim"), fim > ini else {
            call.reject("Informe inicio e fim (ms).")
            return
        }
        let a = Date(timeIntervalSince1970: ini / 1000)
        let b = min(Date(timeIntervalSince1970: fim / 1000), a.addingTimeInterval(62 * 86400))
        pedirCalendario { [weak self] ok in
            guard let self else { return }
            guard ok else {
                call.reject("Sem permissão para o calendário. Libere em Ajustes > Agenda > Calendários.", "SEM_PERMISSAO", nil,
                            ["status": self.statusCalendario()])
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let pred = self.agenda.predicateForEvents(withStart: a, end: b, calendars: nil)
                let eventos = self.agenda.events(matching: pred)
                    .sorted { $0.startDate < $1.startDate }
                    .prefix(300)
                    .map { e -> [String: Any] in
                        [
                            "id": e.eventIdentifier ?? "",
                            "titulo": e.title ?? "",
                            "inicio": e.startDate.timeIntervalSince1970 * 1000,
                            "fim": e.endDate.timeIntervalSince1970 * 1000,
                            "diaInteiro": e.isAllDay,
                            "local": e.location ?? "",
                            "calendario": e.calendar?.title ?? ""
                        ]
                    }
                call.resolve(["eventos": Array(eventos)])
            }
        }
    }

    @objc func calendarioCriar(_ call: CAPPluginCall) {
        let titulo = call.getString("titulo") ?? ""
        guard let ini = call.getDouble("inicio") else { call.reject("Informe o início (ms)."); return }
        let fim = call.getDouble("fim") ?? (ini + 3600 * 1000)
        let notas = call.getString("notas")
        let mostrar = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let e = EKEvent(eventStore: self.agenda)
                e.title = titulo
                e.startDate = Date(timeIntervalSince1970: ini / 1000)
                e.endDate = Date(timeIntervalSince1970: max(fim, ini + 60000) / 1000)
                e.notes = notas
                if let cal = self.agenda.defaultCalendarForNewEvents { e.calendar = cal }
                let vc = EKEventEditViewController()
                vc.eventStore = self.agenda
                vc.event = e
                vc.editViewDelegate = self
                self.guardarChamada(call)
                self.apresentar(vc, call)
            }
        }
        // iOS 17+: a tela de novo evento roda fora do app e não precisa de permissão.
        if #available(iOS 17.0, *) { mostrar(); return }
        pedirCalendario { ok in
            if ok { mostrar() } else { call.reject("Sem permissão para o calendário.", "SEM_PERMISSAO") }
        }
    }

    // MARK: fotos (seletor do sistema; salvar só com a permissão de "adicionar")

    @objc func fotoEscolher(_ call: CAPPluginCall) {
        let maximo = min(max(call.getInt("max") ?? 1, 1), 10)
        larguraFoto = CGFloat(min(max(call.getInt("largura") ?? 1600, 320), 4000))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var conf = PHPickerConfiguration()
            conf.filter = .images
            conf.selectionLimit = maximo
            let vc = PHPickerViewController(configuration: conf)
            vc.delegate = self
            self.guardarChamada(call)
            self.apresentar(vc, call)
        }
    }

    private func reduzir(_ img: UIImage, _ largura: CGFloat) -> UIImage {
        let maior = max(img.size.width, img.size.height)
        guard maior > largura, maior > 0 else { return img }
        let f = largura / maior
        let tam = CGSize(width: floor(img.size.width * f), height: floor(img.size.height * f))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: tam, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: tam)) }
    }

    private func imagensParaSalvar(_ dados: Data, tipo: String) -> [UIImage] {
        if tipo.contains("pdf") || dados.starts(with: Array("%PDF".utf8)) {
            guard let pdf = PDFDocument(data: dados) else { return [] }
            return (0..<min(pdf.pageCount, 20)).compactMap { i in
                guard let pg = pdf.page(at: i) else { return nil }
                let caixa = pg.bounds(for: .mediaBox)
                let f = 2000 / max(caixa.width, caixa.height, 1)
                return pg.thumbnail(of: CGSize(width: caixa.width * f, height: caixa.height * f), for: .mediaBox)
            }
        }
        return UIImage(data: dados).map { [$0] } ?? []
    }

    @objc func fotoSalvar(_ call: CAPPluginCall) {
        guard let dados = dadosBase64(call) else { call.reject("Imagem vazia."); return }
        let imagens = imagensParaSalvar(dados, tipo: (call.getString("tipo") ?? "").lowercased())
        guard !imagens.isEmpty else { call.reject("Não consegui ler a imagem ou o PDF."); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                call.reject("Sem permissão para salvar no rolo. Libere em Ajustes > Agenda > Fotos.", "SEM_PERMISSAO")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for img in imagens { _ = PHAssetChangeRequest.creationRequestForAsset(from: img) }
            }) { ok, erro in
                if ok { call.resolve(["salvas": imagens.count]) }
                else { call.reject(erro?.localizedDescription ?? "Não salvou.") }
            }
        }
    }

    // MARK: arquivos (seletor do sistema, exportar para o Arquivos, pré-visualizar)

    @objc func arquivoEscolher(_ call: CAPPluginCall) {
        limiteBytes = min(max(call.getInt("maxMB") ?? 15, 1), 40) * 1024 * 1024
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
            vc.allowsMultipleSelection = false
            vc.delegate = self
            self.modoDocumento = "abrir"
            self.guardarChamada(call)
            self.apresentar(vc, call)
        }
    }

    @objc func arquivoExportar(_ call: CAPPluginCall) {
        let nome = nomeSeguro(call.getString("nome"), padrao: "agenda.txt")
        let dados: Data
        if let d = dadosBase64(call) { dados = d }
        else if let t = call.getString("texto") { dados = Data(t.utf8) }
        else { call.reject("Nada para exportar."); return }
        let url: URL
        do { url = try arquivoTemporario(dados, nome: nome) } catch { rejeitar(call, error); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let vc = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            vc.delegate = self
            self.modoDocumento = "exportar"
            self.guardarChamada(call)
            self.apresentar(vc, call)
        }
    }

    @objc func arquivoAbrir(_ call: CAPPluginCall) {
        guard let dados = dadosBase64(call) else { call.reject("Arquivo vazio."); return }
        let nome = nomeSeguro(call.getString("nome"), padrao: "anexo")
        do { arquivoPrevia = try arquivoTemporario(dados, nome: nome) } catch { rejeitar(call, error); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let vc = QLPreviewController()
            vc.dataSource = self
            self.apresentar(vc, call)
            call.resolve(["aberto": true])
        }
    }

    // MARK: saúde

    @objc func saudeEstado(_ call: CAPPluginCall) {
        call.resolve([
            "disponivel": false,
            "perfilTemSaude": perfilTemSaude(),
            "motivo": "Esta instalação (conta Apple grátis, reassinada pelo próprio app) não traz o direito de uso do HealthKit."
        ])
    }
}

// MARK: delegados das telas do sistema

extension AgendaAcessoPlugin: CNContactViewControllerDelegate {
    public func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        viewController.dismiss(animated: true)
        terminar(["salvo": contact != nil, "nome": contact.map { CNContactFormatter.string(from: $0, style: .fullName) ?? "" } ?? ""])
    }
}

extension AgendaAcessoPlugin: EKEventEditViewDelegate {
    public func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        controller.dismiss(animated: true)
        terminar(["salvo": action == .saved])
    }
}

extension AgendaAcessoPlugin: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        if results.isEmpty { terminar(["cancelado": true, "fotos": []]); return }
        let largura = larguraFoto
        let trava = NSLock()
        let saida = CaixaFotos(results.count)
        let grupo = DispatchGroup()
        for (i, r) in results.enumerated() {
            guard r.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            grupo.enter()
            r.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                defer { grupo.leave() }
                guard let self, let img = obj as? UIImage else { return }
                let menor = self.reduzir(img, largura)
                guard let jpg = menor.jpegData(compressionQuality: 0.8) else { return }
                let item: [String: Any] = [
                    "base64": jpg.base64EncodedString(),
                    "tipo": "image/jpeg",
                    "nome": "foto-\(i + 1).jpg",
                    "largura": Int(menor.size.width),
                    "altura": Int(menor.size.height),
                    "tamanho": jpg.count
                ]
                trava.lock(); saida.itens[i] = item; trava.unlock()
            }
        }
        grupo.notify(queue: .main) { [weak self] in
            self?.terminar(["fotos": saida.itens.compactMap { $0 }])
        }
    }
}

/// Resultados do seletor de fotos (cada item chega numa fila diferente).
final class CaixaFotos {
    var itens: [[String: Any]?]
    init(_ n: Int) { itens = Array(repeating: nil, count: n) }
}

extension AgendaAcessoPlugin: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if modoDocumento == "exportar" {
            terminar(["salvo": true])
            return
        }
        guard let url = urls.first else { terminar(["cancelado": true]); return }
        let acesso = url.startAccessingSecurityScopedResource()
        defer { if acesso { url.stopAccessingSecurityScopedResource() } }
        let tamanho = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if tamanho > limiteBytes {
            let c = chamadaTela
            chamadaTela = nil
            c?.reject("Arquivo grande demais (\(tamanho / 1048576) MB). O limite é \(limiteBytes / 1048576) MB.", "GRANDE_DEMAIS")
            return
        }
        guard let dados = try? Data(contentsOf: url) else {
            let c = chamadaTela
            chamadaTela = nil
            c?.reject("Não consegui ler o arquivo.")
            return
        }
        terminar([
            "base64": dados.base64EncodedString(),
            "nome": url.lastPathComponent,
            "tipo": Self.mime(url),
            "tamanho": dados.count
        ])
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        terminar(modoDocumento == "exportar" ? ["salvo": false] : ["cancelado": true])
    }
}

extension AgendaAcessoPlugin: QLPreviewControllerDataSource {
    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        arquivoPrevia == nil ? 0 : 1
    }

    public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (arquivoPrevia ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
