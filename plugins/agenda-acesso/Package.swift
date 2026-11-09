// swift-tools-version: 5.9
//
// Plugin "AgendaAcesso" (Capacitor, só iOS): ditado no aparelho, contatos, calendário, fotos e arquivos.
// Só usa frameworks do sistema; cada permissão é pedida quando o usuário toca na função.
import PackageDescription

let package = Package(
    name: "AgendaAcesso",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "AgendaAcesso",
            targets: ["AgendaAcessoPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", "7.0.0"..<"99.0.0")
    ],
    targets: [
        .target(
            name: "AgendaAcessoPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/AgendaAcessoPlugin"
        )
    ]
)
