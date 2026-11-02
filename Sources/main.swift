// ScanMenu — une icône dans la barre de menus macOS :
//   • clic gauche  → lance un scan et l'enregistre dans le dossier choisi
//   • clic droit   → menu de réglages (dossier, format, résolution, source…)

import AppKit
import ImageCaptureCore
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Journal (~/Library/Logs/ScanMenu.log)

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScanMenu.log")

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

func describe(_ error: Error) -> String {
    let e = error as NSError
    return "\(e.localizedDescription) [\(e.domain) \(e.code)]"
}

// MARK: - Réglages persistants

enum ScanFormat: String, CaseIterable {
    case pdf = "PDF", jpeg = "JPEG", png = "PNG"
    var uti: String {
        switch self {
        case .pdf: return UTType.pdf.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        }
    }
}

enum ScanSource: String, CaseIterable {
    case auto = "Automatique", flatbed = "Vitre", feeder = "Chargeur de documents"
}

struct Settings {
    private static let d = UserDefaults.standard

    static var folder: URL {
        get {
            if let p = d.string(forKey: "folder") { return URL(fileURLWithPath: p) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Scans")
        }
        set { d.set(newValue.path, forKey: "folder") }
    }
    static var format: ScanFormat {
        get { ScanFormat(rawValue: d.string(forKey: "format") ?? "") ?? .pdf }
        set { d.set(newValue.rawValue, forKey: "format") }
    }
    static var source: ScanSource {
        get { ScanSource(rawValue: d.string(forKey: "source") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "source") }
    }
    static var resolution: Int {
        get { let r = d.integer(forKey: "resolution"); return r == 0 ? 300 : r }
        set { d.set(newValue, forKey: "resolution") }
    }
    static var color: Bool {
        get { d.object(forKey: "color") as? Bool ?? true }
        set { d.set(newValue, forKey: "color") }
    }
    static var revealAfterScan: Bool {
        get { d.bool(forKey: "reveal") }
        set { d.set(newValue, forKey: "reveal") }
    }
    /// Vrai une fois le lancement automatique proposé, pour ne pas le réactiver si l'utilisateur l'a désactivé.
    static var loginItemConfigured: Bool {
        get { d.bool(forKey: "loginItemConfigured") }
        set { d.set(newValue, forKey: "loginItemConfigured") }
    }
    static var preferredScanner: String? {
        get { d.string(forKey: "scanner") }
        set { d.set(newValue, forKey: "scanner") }
    }
}

// MARK: - Pilotage du scanner (ImageCaptureCore)

extension ICScannerDevice {
    var uid: String { uuidString ?? persistentIDString ?? name ?? "?" }
    var label: String {
        let via: String
        switch transportType {
        case ICDeviceTransport.transportTypeUSB.rawValue: via = "USB"
        case ICDeviceTransport.transportTypeTCPIP.rawValue: via = "réseau"
        case ICDeviceTransport.transportTypeBluetooth.rawValue: via = "Bluetooth"
        default: via = transportType ?? "?"
        }
        return "\(name ?? "Scanner") (\(via))"
    }
}

final class Scanner: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var devices: [ICScannerDevice] = []
    private var active: ICScannerDevice?
    private var scannedFiles: [URL] = []

    var onDevicesChanged: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onFinished: ((_ files: [URL], _ error: String?) -> Void)?

    var isBusy: Bool { active != nil }

    var current: ICScannerDevice? {
        devices.first { $0.uid == Settings.preferredScanner }
            ?? devices.first { $0.name == Settings.preferredScanner }
            ?? devices.first
    }

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.bluetooth.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
    }

    func scan() {
        guard !isBusy else { return }
        guard let device = current else {
            onFinished?([], "Aucun scanner détecté. Vérifiez qu'il est allumé et connecté.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: Settings.folder, withIntermediateDirectories: true)
        } catch {
            onFinished?([], "Impossible de créer le dossier : \(error.localizedDescription)")
            return
        }
        active = device
        scannedFiles = []
        log("Scan demandé sur « \(device.label) » id=\(device.uid), session ouverte : \(device.hasOpenSession)")
        device.delegate = self
        onStatus?("Connexion à \(device.name ?? "scanner")…")
        if device.hasOpenSession {
            selectUnit(on: device)
        } else {
            device.requestOpenSession()
        }
    }

    private func selectUnit(on device: ICScannerDevice) {
        let available = device.availableFunctionalUnitTypes.compactMap {
            ICScannerFunctionalUnitType(rawValue: $0.uintValue)
        }
        let wanted: ICScannerFunctionalUnitType
        switch Settings.source {
        case .flatbed: wanted = .flatbed
        case .feeder: wanted = .documentFeeder
        case .auto:
            // Chargeur si du papier y est posé, sinon la vitre.
            if available.contains(.documentFeeder),
               let feeder = device.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder,
               feeder.documentLoaded {
                wanted = .documentFeeder
            } else {
                wanted = available.contains(.flatbed) ? .flatbed : (available.first ?? .flatbed)
            }
        }
        log("Sources disponibles : \(available.map(\.rawValue)), actuelle : \(device.selectedFunctionalUnit.type.rawValue), voulue : \(wanted.rawValue)")
        // La liste peut être vide juste après l'ouverture de session : on tente quand même.
        guard available.isEmpty || available.contains(wanted) else {
            finish(error: "La source « \(Settings.source.rawValue) » n'est pas disponible sur ce scanner.")
            return
        }
        if device.selectedFunctionalUnit.type == wanted {
            startScan(on: device)
        } else {
            device.requestSelect(wanted)
        }
    }

    private func startScan(on device: ICScannerDevice) {
        let unit = device.selectedFunctionalUnit
        unit.measurementUnit = .inches
        let res = Settings.resolution
        if unit.supportedResolutions.contains(res) {
            unit.resolution = res
        } else if let closest = unit.supportedResolutions.min(by: { abs($0 - res) < abs($1 - res) }) {
            unit.resolution = closest
        }
        unit.pixelDataType = Settings.color ? .RGB : .gray
        unit.bitDepth = .depth8Bits
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeA4
        } else {
            unit.scanArea = NSRect(origin: .zero, size: unit.physicalSize)
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        device.transferMode = .fileBased
        device.downloadsDirectory = Settings.folder
        device.documentName = "Scan \(stamp.string(from: Date()))"
        device.documentUTI = Settings.format.uti

        log("Lancement : \(unit.resolution) ppp, \(Settings.color ? "couleur" : "gris"), \(Settings.format.rawValue), zone \(unit.scanArea)")
        onStatus?("Numérisation en cours…")
        device.requestScan()
    }

    private func finish(error: String?) {
        let files = scannedFiles
        log(error.map { "ÉCHEC : \($0)" } ?? "Terminé : \(files.map(\.lastPathComponent))")
        if let device = active, device.hasOpenSession { device.requestCloseSession() }
        active = nil
        onFinished?(files, error)
    }

    // ICDeviceBrowserDelegate
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let s = device as? ICScannerDevice else { return }
        log("Scanner détecté : \(s.label) id=\(s.uid) distant=\(s.isRemote)")
        devices.append(s)
        onDevicesChanged?()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
        if active === device { finish(error: "Le scanner a été déconnecté.") }
        onDevicesChanged?()
    }

    // ICDeviceDelegate
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let s = device as? ICScannerDevice, s === active else { return }
        if let error { finish(error: "Ouverture de session impossible : \(describe(error))"); return }
        selectUnit(on: s)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}

    // ICScannerDeviceDelegate
    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        guard scanner === active else { return }
        if let error { finish(error: "Sélection de la source impossible : \(describe(error))"); return }
        startScan(on: scanner)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        scannedFiles.append(url)
    }

    func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        log("Scanner disponible")
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let error { log("Erreur appareil : \(describe(error))") }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        guard scanner === active else { return }
        finish(error: error.map { "Échec du scan : \(describe($0))" })
    }
}

// MARK: - Barre de menus

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let scanner = Scanner()
    private var lastStatus = "Prêt"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            setIcon(busy: false)
            button.toolTip = "Clic : scanner • Clic droit : réglages"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        scanner.onStatus = { [weak self] in self?.lastStatus = $0 }
        scanner.onFinished = { [weak self] files, error in self?.scanFinished(files: files, error: error) }

        // Démarrage avec le système activé par défaut au premier lancement.
        if !Settings.loginItemConfigured {
            Settings.loginItemConfigured = true
            do { try SMAppService.mainApp.register(); log("Lancement automatique activé") }
            catch { log("Lancement automatique impossible : \(describe(error))") }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setIcon(busy: Bool) {
        let name = busy ? "scanner.fill" : "scanner"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Scanner")
            ?? NSImage(systemSymbolName: "doc.viewfinder", accessibilityDescription: "Scanner")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = busy
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            startScan()
        }
    }

    @objc private func startScan() {
        guard !scanner.isBusy else { return }
        setIcon(busy: true)
        scanner.scan()
    }

    private func scanFinished(files: [URL], error: String?) {
        setIcon(busy: false)
        if let error {
            lastStatus = "Erreur"
            notify(title: "Scan échoué", body: error)
            return
        }
        lastStatus = files.isEmpty ? "Scan terminé" : "Dernier : \(files.last!.lastPathComponent)"
        let body = files.count > 1 ? "\(files.count) fichiers enregistrés dans \(Settings.folder.lastPathComponent)"
                                   : "Enregistré dans \(Settings.folder.lastPathComponent)"
        notify(title: "Scan terminé", body: body)
        if Settings.revealAfterScan {
            if files.isEmpty { NSWorkspace.shared.open(Settings.folder) }
            else { NSWorkspace.shared.activateFileViewerSelecting(files) }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Menu de réglages (clic droit)

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: scanner.isBusy ? lastStatus : "État : \(lastStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let scanItem = NSMenuItem(title: "Scanner maintenant", action: #selector(startScan), keyEquivalent: "s")
        scanItem.isEnabled = !scanner.isBusy
        menu.addItem(scanItem)
        menu.addItem(.separator())

        // Scanner
        let scanners = NSMenu()
        if scanner.devices.isEmpty {
            let none = NSMenuItem(title: "Aucun scanner détecté", action: nil, keyEquivalent: "")
            none.isEnabled = false
            scanners.addItem(none)
        }
        for d in scanner.devices {
            let item = NSMenuItem(title: d.label, action: #selector(pickScanner(_:)), keyEquivalent: "")
            item.representedObject = d.uid
            item.state = d === scanner.current ? .on : .off
            scanners.addItem(item)
        }
        addSubmenu(to: menu, title: "Scanner : \(scanner.current?.label ?? "—")", submenu: scanners)

        // Dossier
        menu.addItem(NSMenuItem(title: "Dossier : \(Settings.folder.lastPathComponent)…",
                                action: #selector(chooseFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ouvrir le dossier", action: #selector(openFolder), keyEquivalent: "o"))
        menu.addItem(.separator())

        // Format, résolution, source, couleur
        addSubmenu(to: menu, title: "Format : \(Settings.format.rawValue)", submenu: choices(
            ScanFormat.allCases.map { ($0.rawValue, $0.rawValue, $0 == Settings.format) }, #selector(pickFormat(_:))))
        addSubmenu(to: menu, title: "Résolution : \(Settings.resolution) ppp", submenu: choices(
            [150, 200, 300, 600].map { ("\($0) ppp", $0, $0 == Settings.resolution) }, #selector(pickResolution(_:))))
        addSubmenu(to: menu, title: "Source : \(Settings.source.rawValue)", submenu: choices(
            ScanSource.allCases.map { ($0.rawValue, $0.rawValue, $0 == Settings.source) }, #selector(pickSource(_:))))

        let color = NSMenuItem(title: "Couleur", action: #selector(toggleColor), keyEquivalent: "")
        color.state = Settings.color ? .on : .off
        menu.addItem(color)
        let reveal = NSMenuItem(title: "Afficher le fichier après le scan", action: #selector(toggleReveal), keyEquivalent: "")
        reveal.state = Settings.revealAfterScan ? .on : .off
        menu.addItem(reveal)
        let login = NSMenuItem(title: "Démarrer avec le système", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Afficher le journal", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quitter ScanMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // On retire le menu pour que le clic gauche relance directement un scan.
        statusItem.menu = nil
    }

    private func addSubmenu(to menu: NSMenu, title: String, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func choices(_ options: [(String, Any, Bool)], _ action: Selector) -> NSMenu {
        let m = NSMenu()
        for (title, value, selected) in options {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = selected ? .on : .off
            m.addItem(item)
        }
        return m
    }

    @objc private func pickScanner(_ sender: NSMenuItem) { Settings.preferredScanner = sender.representedObject as? String }
    @objc private func pickFormat(_ sender: NSMenuItem) { Settings.format = ScanFormat(rawValue: sender.representedObject as! String)! }
    @objc private func pickResolution(_ sender: NSMenuItem) { Settings.resolution = sender.representedObject as! Int }
    @objc private func pickSource(_ sender: NSMenuItem) { Settings.source = ScanSource(rawValue: sender.representedObject as! String)! }
    @objc private func toggleColor() { Settings.color.toggle() }
    @objc private func toggleReveal() { Settings.revealAfterScan.toggle() }
    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func openFolder() { NSWorkspace.shared.open(Settings.folder) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            notify(title: "Lancement automatique", body: error.localizedDescription)
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Dossier de destination des scans"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Settings.folder = url }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
