// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteWall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NoteWall",
            path: "Sources/NoteWall"
        )
    ]
)
