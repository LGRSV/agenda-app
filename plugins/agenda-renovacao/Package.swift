// swift-tools-version: 5.9
//
// Plugin "AgendaRenovacao" (Capacitor, só iOS).
// Renova o perfil de provisionamento de 7 dias do próprio app, do mesmo jeito que o SideStore:
//   - SideSign (https://github.com/SideStore/SideSign): login GSA/2FA, anisette remoto e portal do desenvolvedor;
//   - IDevice (https://github.com/SideStore/idevice, mesmo binário que o minimuxer do SideStore usa):
//     instala o perfil pelo serviço misagent do iOS, através da VPN de loopback (LocalDevVPN) + pairing file.
// Licença: AGPL-3.0 (código derivado/inspirado no SideStore, https://github.com/SideStore/SideStore).
import PackageDescription

let package = Package(
    name: "AgendaRenovacao",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "AgendaRenovacao",
            targets: ["AgendaRenovacaoPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", "7.0.0"..<"99.0.0"),
        // Mesmo commit que o SideStore usa (submódulo Dependencies/SideSign em 26/10/2026).
        .package(url: "https://github.com/SideStore/SideSign.git", revision: "752d1ef602aa792a432ffa1e71646dc1ecf7363c")
    ],
    targets: [
        // Mesmo xcframework (e mesmo checksum) que o minimuxer do SideStore usa (DeviceGateway/Package.swift).
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.68-ss-3e55c84/idevice-xcframework-v0.1.68-ss-3e55c84.zip",
            checksum: "445702d53942597deb4cdec2c4122d16a3f4ac124ce26cd75b68dab3dad92416"
        ),
        .target(
            name: "AgendaRenovacaoPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "SideSign", package: "SideSign"),
                "IDevice"
            ],
            path: "ios/Sources/AgendaRenovacaoPlugin"
        )
    ]
)
