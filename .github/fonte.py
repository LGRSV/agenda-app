"""Confere a .ipa e gera as fontes do app (formato AltStore, que o SideStore lê igual).

Uso (no CI, macOS):
  python3 fonte.py conferir <ipa> <versao> <build>
      Lê o Info.plist de dentro da .ipa e falha se CFBundleShortVersionString, CFBundleVersion ou
      CFBundleIdentifier não forem os esperados (o SideStore recusa a instalação se não baterem).
      Imprime versao=, build=, bundle=, tamanho=, sha256= (para o $GITHUB_OUTPUT).
  python3 fonte.py fontes <ipa> <versao> <build>
      Mesma conferência e grava, na pasta atual:
        sidestore.json  link da .ipa com a versão no nome (o arquivo não muda depois de publicado),
                        com size e sha256 dessa .ipa exata;
        altstore.json   igual à de antes (link fixo Agenda.ipa), para quem já usa e para o
                        atualizador do próprio app (Atualizador.swift lê esta).

Regras do SideStore (VerifyAppOperation): bundleIdentifier = CFBundleIdentifier, version =
CFBundleShortVersionString, buildVersion = CFBundleVersion, size = bytes da .ipa baixada e sha256
(se houver) = hash dela. Sem "version": 2 na fonte o SideStore não confere appPermissions, e sem
marketplaceID ele não trata a fonte como notarizada.
"""
import hashlib
import json
import os
import plistlib
import re
import sys
import zipfile
from datetime import datetime, timezone

BUNDLE = "com.lgrsv.agenda"
REPO = "https://github.com/LGRSV/agenda-app"
RAW = "https://raw.githubusercontent.com/LGRSV/agenda-app/fonte/"
ICONE = "https://lgrsv.github.io/agenda-iphone/icon-512.png"
DOWNLOAD_FIXO = REPO + "/releases/download/ultima/Agenda.ipa"

# Textos curtos da fonte antiga (altstore.json), mantidos como estavam.
PRIVACIDADE_ALTSTORE = {
    "NSLocationWhenInUseUsageDescription": "Registrar chegadas e saídas dos seus lugares.",
    "NSLocationAlwaysAndWhenInUseUsageDescription": "Registrar chegadas e saídas com o app fechado.",
    "NSLocationAlwaysUsageDescription": "Registrar chegadas e saídas com o app fechado.",
    "NSMicrophoneUsageDescription": "Ditar tarefas e perguntas ao Jarvis (só ao tocar no microfone).",
    "NSSpeechRecognitionUsageDescription": "Transcrever o ditado em português no próprio iPhone.",
    "NSContactsUsageDescription": "Buscar nome e telefone para ligar uma tarefa a uma pessoa.",
    "NSCalendarsFullAccessUsageDescription": "Mostrar os eventos do dia e da semana na tela inicial.",
    "NSPhotoLibraryAddUsageDescription": "Salvar no rolo as imagens e PDFs que você pedir.",
}


def nome_versionado(versao):
    return f"Agenda-{versao}.ipa"


def conferir(ipa, versao, build):
    """Confere a .ipa como o SideStore confere e devolve os dados da fonte."""
    if not re.fullmatch(r"\d+\.\d+\.\d+", versao) or not build.isdigit():
        raise SystemExit(f"versão/build esperados inválidos: {versao!r} / {build!r}")
    with zipfile.ZipFile(ipa) as z:
        nomes = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(nomes) != 1:
            raise SystemExit(f"esperava 1 Info.plist do app na .ipa, achei {nomes}")
        info = plistlib.loads(z.read(nomes[0]))
        extensoes = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/PlugIns/[^/]+\.appex/Info\.plist", n)]
    erros = []
    if info.get("CFBundleIdentifier") != BUNDLE:
        erros.append(f"CFBundleIdentifier = {info.get('CFBundleIdentifier')!r}, esperado {BUNDLE!r}")
    if info.get("CFBundleShortVersionString") != versao:
        erros.append(f"CFBundleShortVersionString = {info.get('CFBundleShortVersionString')!r}, esperado {versao!r}")
    if str(info.get("CFBundleVersion")) != build:
        erros.append(f"CFBundleVersion = {info.get('CFBundleVersion')!r}, esperado {build!r}")
    if erros:
        raise SystemExit("A .ipa não bate com a fonte (o SideStore recusaria):\n  " + "\n  ".join(erros))
    with open(ipa, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    privacidade = {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription") and isinstance(v, str)}
    return {
        "versao": versao,
        "build": build,
        "bundle": BUNDLE,
        "tamanho": os.path.getsize(ipa),
        "sha256": sha,
        "minOS": str(info.get("MinimumOSVersion") or "15.0"),
        "privacidade": privacidade,
        "extensoes": len(extensoes),
    }


def fonte(nome_arquivo, nome, descricao, versao_app, privacidade):
    return {
        "name": nome,
        "identifier": "com.lgrsv.agenda.fonte",
        "sourceURL": RAW + nome_arquivo,
        "apps": [{
            "name": "Agenda",
            "bundleIdentifier": BUNDLE,
            "developerName": "LGRSV",
            "localizedDescription": descricao,
            "iconURL": ICONE,
            "versions": [versao_app],
            "appPermissions": {"entitlements": [], "privacy": privacidade},
        }],
        "news": [],
    }


def gerar(dados, data):
    versao_base = {
        "version": dados["versao"],
        "buildVersion": dados["build"],
        "date": data,
    }
    sidestore = fonte(
        "sidestore.json",
        "Agenda do Lagares",
        "Agenda com GPS em segundo plano e lembretes locais. Instale, renove e atualize pelo SideStore "
        "(com o LocalDevVPN ligado). O app também consegue renovar o perfil de 7 dias e se atualizar "
        "sozinho (menu Renovação do app), sem nunca revogar o certificado do SideStore.",
        dict(versao_base,
             downloadURL=f"{REPO}/releases/download/ultima/{nome_versionado(dados['versao'])}",
             size=dados["tamanho"], sha256=dados["sha256"], minOSVersion=dados["minOS"]),
        dados["privacidade"] or PRIVACIDADE_ALTSTORE,
    )
    altstore = fonte(
        "altstore.json",
        "Agenda do Lagares",
        "Agenda com GPS em segundo plano, lembretes locais, renovação automática do perfil de 7 dias "
        "e atualização pelo próprio app (LocalDevVPN + pairing file).",
        dict(versao_base, downloadURL=DOWNLOAD_FIXO, size=dados["tamanho"], minOSVersion="15.0"),
        PRIVACIDADE_ALTSTORE,
    )
    for nome_arquivo, conteudo in (("sidestore.json", sidestore), ("altstore.json", altstore)):
        texto = json.dumps(conteudo, ensure_ascii=False, indent=2) + "\n"
        json.loads(texto)  # confere que é JSON válido
        with open(nome_arquivo, "w", encoding="utf-8", newline="\n") as f:
            f.write(texto)


def main(argv):
    if len(argv) != 5 or argv[1] not in ("conferir", "fontes"):
        raise SystemExit(__doc__)
    modo, ipa, versao, build = argv[1:]
    dados = conferir(ipa, versao, build)
    if dados["extensoes"]:
        # Cada extensão gasta um App ID dos 10 por semana da conta grátis.
        print(f"aviso: a .ipa tem {dados['extensoes']} extensão(ões)", file=sys.stderr)
    if modo == "conferir":
        for chave in ("versao", "build", "bundle", "tamanho", "sha256"):
            print(f"{chave}={dados[chave]}")
        return
    data = os.environ.get("DATA") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    gerar(dados, data)


if __name__ == "__main__":
    main(sys.argv)
