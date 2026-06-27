import SwiftUI
import AVFoundation
import PhotosUI
import GoogleSignIn
import GoogleSignInSwift
import MediaPlayer

// MARK: - App State & API Manager
class DocsManager: ObservableObject {
    @Published var documentId: String = UserDefaults.standard.string(forKey: "SavedDocId") ?? "" {
        didSet { UserDefaults.standard.set(documentId, forKey: "SavedDocId") }
    }
    @Published var accessToken: String = ""
    @Published var documentText: String = UserDefaults.standard.string(forKey: "CachedDocText") ?? ""
    @Published var isLoading: Bool = false
    @Published var statusMessage: String = "Sẵn sàng"
    
    func handleGoogleSignIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else { return }
              
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController, hint: nil, additionalScopes: ["https://www.googleapis.com/auth/documents"]) { result, error in
            DispatchQueue.main.async {
                if let error = error { self.statusMessage = "Lỗi login: \(error.localizedDescription)"; return }
                self.accessToken = result?.user.accessToken.tokenString ?? ""
                self.statusMessage = "Đã liên kết Google!"
            }
        }
    }
    
    func fetchDocument() {
        guard !documentId.isEmpty, !accessToken.isEmpty else {
            statusMessage = "Thiếu ID hoặc Token"
            return
        }
        isLoading = true
        statusMessage = "Đang kéo dữ liệu..."
        
        let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentId)")!
        var req = URLRequest(url: url)
        req.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                self.isLoading = false
                if let err = err { self.statusMessage = "Lỗi mạng: \(err.localizedDescription)"; return }
                guard let data = data else { return }
                
                var fullText = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let body = json["body"] as? [String: Any],
                   let contentArray = body["content"] as? [[String: Any]] {
                    for element in contentArray {
                        if let paragraph = element["paragraph"] as? [String: Any],
                           let elements = paragraph["elements"] as? [[String: Any]] {
                            for tElement in elements {
                                if let textRun = tElement["textRun"] as? [String: Any],
                                   let content = textRun["content"] as? String {
                                    fullText += content
                                }
                            }
                        }
                    }
                    self.documentText = fullText
                    UserDefaults.standard.set(fullText, forKey: "CachedDocText")
                    self.statusMessage = "Đồng bộ thành công"
                }
            }
        }.resume()
    }
    
    func insertImage(image: UIImage) { /* Mock payload */ }
    func saveEdits() { /* Mock payload */ }
}

// MARK: - TTS Manager
class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSManager()
    private let synthesizer = AVSpeechSynthesizer()
    
    @Published var isSpeaking = false
    @Published var currentProgress: Double = 0.0
    @Published var speechRate: Float = 0.5
    
    var documentId: String = ""
    var fullText: String = ""
    private var startIndex: Int = 0
    
    override init() {
        super.init()
        synthesizer.delegate = self
        setupAudioSession()
        setupLockScreenControls()
    }
    
    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    private func setupLockScreenControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.playPause(text: self?.fullText ?? "", docId: self?.documentId ?? ""); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.playPause(text: self?.fullText ?? "", docId: self?.documentId ?? ""); return .success
        }
    }
    
    private func updateNowPlayingInfo(isPaused: Bool = false) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = "Trình Đọc Truyện"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func playPause(text: String, docId: String) {
        if isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
            isSpeaking = false; updateNowPlayingInfo(isPaused: true)
        } else {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking(); isSpeaking = true; updateNowPlayingInfo()
            } else { startNew(text: text, docId: docId) }
        }
    }
    
    private func startNew(text: String, docId: String) {
        guard !text.isEmpty else { return }
        self.documentId = docId; self.fullText = text
        let savedIndex = UserDefaults.standard.integer(forKey: "TTS_Pos_\(docId)")
        self.startIndex = savedIndex
        let textToSpeak = (savedIndex > 0 && savedIndex < text.count) ? String(text.dropFirst(savedIndex)) : text
        if savedIndex == 0 { currentProgress = 0.0 }
        
        let utterance = AVSpeechUtterance(string: textToSpeak)
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = speechRate
        synthesizer.speak(utterance)
        isSpeaking = true; updateNowPlayingInfo()
    }
    
    func stopAndReset() {
        synthesizer.stopSpeaking(at: .immediate); isSpeaking = false; currentProgress = 0.0
        UserDefaults.standard.set(0, forKey: "TTS_Pos_\(documentId)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let globalIndex = self.startIndex + characterRange.location
        DispatchQueue.main.async {
            self.currentProgress = Double(globalIndex) / Double(max(1, self.fullText.count))
            UserDefaults.standard.set(globalIndex, forKey: "TTS_Pos_\(self.documentId)")
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false; self.currentProgress = 1.0
            UserDefaults.standard.set(0, forKey: "TTS_Pos_\(self.documentId)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
}

// MARK: - Main UI
struct ContentView: View {
    @StateObject private var docs = DocsManager()
    @StateObject private var tts = TTSManager.shared
    @State private var isDarkMode = false
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                (isDarkMode ? Color.black : Color(uiColor: .systemGroupedBackground)).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 0) {
                        TextEditor(text: $docs.documentText)
                            .font(.system(size: 18, weight: .regular, design: .serif))
                            .lineSpacing(8)
                            .padding()
                            .frame(minHeight: UIScreen.main.bounds.height * 0.7)
                            .background(isDarkMode ? Color(white: 0.1) : Color(red: 0.98, green: 0.96, blue: 0.9))
                            .foregroundColor(isDarkMode ? .white : .black)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                            .padding()
                        
                        Spacer().frame(height: 140)
                    }
                }
                
                playerBar
            }
            .navigationTitle("Trình Đọc Truyện")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gearshape.fill").foregroundColor(isDarkMode ? .gray : .blue)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isDarkMode.toggle() }) {
                        Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(isDarkMode ? .yellow : .indigo)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
        }
    }
    
    var playerBar: some View {
        VStack(spacing: 12) {
            ProgressView(value: tts.currentProgress).progressViewStyle(.linear).tint(.blue).padding(.horizontal)
            HStack(spacing: 30) {
                Button(action: { tts.stopAndReset() }) {
                    Image(systemName: "arrow.counterclockwise").font(.title2).foregroundColor(.gray)
                }
                Button(action: { tts.playPause(text: docs.documentText, docId: docs.documentId) }) {
                    Image(systemName: tts.isSpeaking ? "pause.circle.fill" : "play.circle.fill")
                        .resizable().frame(width: 50, height: 50).foregroundColor(.blue)
                        .shadow(color: .blue.opacity(0.3), radius: 5, y: 2)
                }
                Button(action: { docs.fetchDocument() }) {
                    Image(systemName: "arrow.down.doc.fill").font(.title2).foregroundColor(docs.isLoading ? .gray : .blue)
                }
                .disabled(docs.isLoading)
            }
            HStack {
                Image(systemName: "tortoise.fill").foregroundColor(.gray).font(.caption)
                Slider(value: $tts.speechRate, in: 0.1...1.0)
                Image(systemName: "hare.fill").foregroundColor(.gray).font(.caption)
            }.padding(.horizontal, 40)
            Text(docs.statusMessage).font(.caption).foregroundColor(.gray)
        }
        .padding(.vertical, 15).background(.ultraThinMaterial).cornerRadius(20)
        .padding(.horizontal).padding(.bottom, 10).shadow(color: .black.opacity(0.1), radius: 10, y: -2)
    }
    
    var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Tài khoản Google")) {
                    if docs.accessToken.isEmpty {
                        GoogleSignInButton(action: { docs.handleGoogleSignIn() }).frame(height: 50)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Đã liên kết"); Spacer()
                            Button("Thoát") { docs.accessToken = "" }.foregroundColor(.red)
                        }
                    }
                }
                Section(header: Text("Kết nối Docs")) { TextField("Document ID", text: $docs.documentId) }
            }
            .navigationTitle("Cài đặt").navigationBarItems(trailing: Button("Đóng") { showSettings = false })
        }
    }
}
