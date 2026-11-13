//
//  VoiceLanguageCatalog.swift
//  leanring-buddy
//
//  Catalog of OpenAI Realtime voices (10), Gemini Live voices (30), speech speeds,
//  133 supported voice/dictation languages, and a bundled voice preview player.
//

import AVFoundation
import Combine
import Foundation

public enum VoiceCatalogProvider: String, Codable, CaseIterable, Sendable {
    case openAI = "openai"
    case gemini = "gemini"
}

public struct CatalogVoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let provider: VoiceCatalogProvider
    public let toneDescription: String
    public let previewFilename: String

    public init(
        id: String,
        displayName: String,
        provider: VoiceCatalogProvider,
        toneDescription: String,
        previewFilename: String
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.toneDescription = toneDescription
        self.previewFilename = previewFilename
    }
}

public struct SpeechSpeedOption: Identifiable, Hashable, Sendable {
    public var id: Double { rate }
    public let rate: Double
    public let label: String

    public init(rate: Double, label: String) {
        self.rate = rate
        self.label = label
    }
}

public struct VoiceLanguage: Identifiable, Hashable, Sendable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let nativeName: String
    public let bcp47Locale: String

    public init(
        code: String,
        name: String,
        nativeName: String,
        bcp47Locale: String? = nil
    ) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.bcp47Locale = bcp47Locale ?? code
    }

    public var displayLabel: String {
        if nativeName == name || nativeName.isEmpty {
            return name
        }
        return "\(name) (\(nativeName))"
    }
}

public enum VoiceLanguageCatalog {
    public static let defaultOpenAIVoiceID = "cedar"
    public static let defaultGeminiVoiceID = "Puck"

    public static let openAIVoices: [CatalogVoice] = [
        CatalogVoice(id: "cedar", displayName: "Cedar", provider: .openAI, toneDescription: "Warm, grounded, conversational", previewFilename: "realtime-voice-preview-cedar.mp3"),
        CatalogVoice(id: "marin", displayName: "Marin", provider: .openAI, toneDescription: "Bright, clear, expressive", previewFilename: "realtime-voice-preview-marin.mp3"),
        CatalogVoice(id: "alloy", displayName: "Alloy", provider: .openAI, toneDescription: "Balanced, neutral, articulate", previewFilename: "realtime-voice-preview-alloy.mp3"),
        CatalogVoice(id: "ash", displayName: "Ash", provider: .openAI, toneDescription: "Crisp, focused, direct", previewFilename: "realtime-voice-preview-ash.mp3"),
        CatalogVoice(id: "ballad", displayName: "Ballad", provider: .openAI, toneDescription: "Smooth, narrative, lyrical", previewFilename: "realtime-voice-preview-ballad.mp3"),
        CatalogVoice(id: "coral", displayName: "Coral", provider: .openAI, toneDescription: "Friendly, energetic, upbeat", previewFilename: "realtime-voice-preview-coral.mp3"),
        CatalogVoice(id: "echo", displayName: "Echo", provider: .openAI, toneDescription: "Steady, resonant, calm", previewFilename: "realtime-voice-preview-echo.mp3"),
        CatalogVoice(id: "sage", displayName: "Sage", provider: .openAI, toneDescription: "Thoughtful, poised, measured", previewFilename: "realtime-voice-preview-sage.mp3"),
        CatalogVoice(id: "shimmer", displayName: "Shimmer", provider: .openAI, toneDescription: "Light, airy, gentle", previewFilename: "realtime-voice-preview-shimmer.mp3"),
        CatalogVoice(id: "verse", displayName: "Verse", provider: .openAI, toneDescription: "Dynamic, expressive, lively", previewFilename: "realtime-voice-preview-verse.mp3")
    ]

    public static let geminiVoices: [CatalogVoice] = [
        CatalogVoice(id: "Puck", displayName: "Puck", provider: .gemini, toneDescription: "Upbeat, playful, brisk", previewFilename: "gemini-voice-preview-puck.mp3"),
        CatalogVoice(id: "Charon", displayName: "Charon", provider: .gemini, toneDescription: "Informative, steady, clear", previewFilename: "gemini-voice-preview-charon.mp3"),
        CatalogVoice(id: "Kore", displayName: "Kore", provider: .gemini, toneDescription: "Firm, crisp, confident", previewFilename: "gemini-voice-preview-kore.mp3"),
        CatalogVoice(id: "Fenrir", displayName: "Fenrir", provider: .gemini, toneDescription: "Excitable, energetic, vivid", previewFilename: "gemini-voice-preview-fenrir.mp3"),
        CatalogVoice(id: "Aoede", displayName: "Aoede", provider: .gemini, toneDescription: "Breezy, natural, melodic", previewFilename: "gemini-voice-preview-aoede.mp3"),
        CatalogVoice(id: "Leda", displayName: "Leda", provider: .gemini, toneDescription: "Youthful, bright, agile", previewFilename: "gemini-voice-preview-leda.mp3"),
        CatalogVoice(id: "Orus", displayName: "Orus", provider: .gemini, toneDescription: "Composed, authoritative, firm", previewFilename: "gemini-voice-preview-orus.mp3"),
        CatalogVoice(id: "Zephyr", displayName: "Zephyr", provider: .gemini, toneDescription: "Bright, airy, open", previewFilename: "gemini-voice-preview-zephyr.mp3"),
        CatalogVoice(id: "Achernar", displayName: "Achernar", provider: .gemini, toneDescription: "Soft, gentle, reassuring", previewFilename: "gemini-voice-preview-achernar.mp3"),
        CatalogVoice(id: "Achird", displayName: "Achird", provider: .gemini, toneDescription: "Friendly, warm, approachable", previewFilename: "gemini-voice-preview-achird.mp3"),
        CatalogVoice(id: "Algenib", displayName: "Algenib", provider: .gemini, toneDescription: "Gravelly, textured, deep", previewFilename: "gemini-voice-preview-algenib.mp3"),
        CatalogVoice(id: "Algieba", displayName: "Algieba", provider: .gemini, toneDescription: "Smooth, polished, poised", previewFilename: "gemini-voice-preview-algieba.mp3"),
        CatalogVoice(id: "Alnilam", displayName: "Alnilam", provider: .gemini, toneDescription: "Firm, grounded, articulate", previewFilename: "gemini-voice-preview-alnilam.mp3"),
        CatalogVoice(id: "Autonoe", displayName: "Autonoe", provider: .gemini, toneDescription: "Bright, expressive, clear", previewFilename: "gemini-voice-preview-autonoe.mp3"),
        CatalogVoice(id: "Callirrhoe", displayName: "Callirrhoe", provider: .gemini, toneDescription: "Easygoing, relaxed, fluid", previewFilename: "gemini-voice-preview-callirrhoe.mp3"),
        CatalogVoice(id: "Despina", displayName: "Despina", provider: .gemini, toneDescription: "Smooth, warm, inviting", previewFilename: "gemini-voice-preview-despina.mp3"),
        CatalogVoice(id: "Enceladus", displayName: "Enceladus", provider: .gemini, toneDescription: "Breathy, soft, intimate", previewFilename: "gemini-voice-preview-enceladus.mp3"),
        CatalogVoice(id: "Erinome", displayName: "Erinome", provider: .gemini, toneDescription: "Clear, neutral, crisp", previewFilename: "gemini-voice-preview-erinome.mp3"),
        CatalogVoice(id: "Gacrux", displayName: "Gacrux", provider: .gemini, toneDescription: "Mature, steady, thoughtful", previewFilename: "gemini-voice-preview-gacrux.mp3"),
        CatalogVoice(id: "Iapetus", displayName: "Iapetus", provider: .gemini, toneDescription: "Clear, direct, balanced", previewFilename: "gemini-voice-preview-iapetus.mp3"),
        CatalogVoice(id: "Laomedeia", displayName: "Laomedeia", provider: .gemini, toneDescription: "Upbeat, lively, bright", previewFilename: "gemini-voice-preview-laomedeia.mp3"),
        CatalogVoice(id: "Pulcherrima", displayName: "Pulcherrima", provider: .gemini, toneDescription: "Forward, expressive, vivid", previewFilename: "gemini-voice-preview-pulcherrima.mp3"),
        CatalogVoice(id: "Rasalgethi", displayName: "Rasalgethi", provider: .gemini, toneDescription: "Informative, measured, clear", previewFilename: "gemini-voice-preview-rasalgethi.mp3"),
        CatalogVoice(id: "Sadachbia", displayName: "Sadachbia", provider: .gemini, toneDescription: "Lively, animated, warm", previewFilename: "gemini-voice-preview-sadachbia.mp3"),
        CatalogVoice(id: "Schedar", displayName: "Schedar", provider: .gemini, toneDescription: "Even, calm, balanced", previewFilename: "gemini-voice-preview-schedar.mp3"),
        CatalogVoice(id: "Sulafat", displayName: "Sulafat", provider: .gemini, toneDescription: "Warm, gentle, steady", previewFilename: "gemini-voice-preview-sulafat.mp3"),
        CatalogVoice(id: "Umbriel", displayName: "Umbriel", provider: .gemini, toneDescription: "Easygoing, mellow, relaxed", previewFilename: "gemini-voice-preview-umbriel.mp3"),
        CatalogVoice(id: "Vindemiatrix", displayName: "Vindemiatrix", provider: .gemini, toneDescription: "Gentle, calm, reflective", previewFilename: "gemini-voice-preview-vindemiatrix.mp3"),
        CatalogVoice(id: "Zubenelgenubi", displayName: "Zubenelgenubi", provider: .gemini, toneDescription: "Casual, natural, conversational", previewFilename: "gemini-voice-preview-zubenelgenubi.mp3"),
        CatalogVoice(id: "Sadaltager", displayName: "Sadaltager", provider: .gemini, toneDescription: "Knowledgeable, poised, clear", previewFilename: "gemini-voice-preview-sadaltager.mp3")
    ]

    public static var allVoices: [CatalogVoice] {
        openAIVoices + geminiVoices
    }

    public static let speechSpeeds: [SpeechSpeedOption] = [
        SpeechSpeedOption(rate: 0.5, label: "0.5x"),
        SpeechSpeedOption(rate: 0.75, label: "0.75x"),
        SpeechSpeedOption(rate: 0.9, label: "0.9x"),
        SpeechSpeedOption(rate: 1.0, label: "1.0x"),
        SpeechSpeedOption(rate: 1.1, label: "1.1x"),
        SpeechSpeedOption(rate: 1.25, label: "1.25x"),
        SpeechSpeedOption(rate: 1.5, label: "1.5x")
    ]

    public static let supportedLanguages: [VoiceLanguage] = [
        VoiceLanguage(code: "auto", name: "Auto-Detect", nativeName: "Automatic", bcp47Locale: "auto"),
        VoiceLanguage(code: "en", name: "English", nativeName: "English", bcp47Locale: "en-US"),
        VoiceLanguage(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia", bcp47Locale: "id-ID"),
        VoiceLanguage(code: "jv", name: "Javanese", nativeName: "Basa Jawa", bcp47Locale: "jv-ID"),
        VoiceLanguage(code: "su", name: "Sundanese", nativeName: "Basa Sunda", bcp47Locale: "su-ID"),
        VoiceLanguage(code: "es", name: "Spanish", nativeName: "Español", bcp47Locale: "es-ES"),
        VoiceLanguage(code: "ja", name: "Japanese", nativeName: "日本語", bcp47Locale: "ja-JP"),
        VoiceLanguage(code: "zh", name: "Chinese (Mandarin)", nativeName: "中文", bcp47Locale: "zh-CN"),
        VoiceLanguage(code: "ar", name: "Arabic", nativeName: "العربية", bcp47Locale: "ar-SA"),
        VoiceLanguage(code: "fr", name: "French", nativeName: "Français", bcp47Locale: "fr-FR"),
        VoiceLanguage(code: "de", name: "German", nativeName: "Deutsch", bcp47Locale: "de-DE"),
        VoiceLanguage(code: "ko", name: "Korean", nativeName: "한국어", bcp47Locale: "ko-KR"),
        VoiceLanguage(code: "pt", name: "Portuguese", nativeName: "Português", bcp47Locale: "pt-BR"),
        VoiceLanguage(code: "hi", name: "Hindi", nativeName: "हिन्दी", bcp47Locale: "hi-IN"),
        VoiceLanguage(code: "ru", name: "Russian", nativeName: "Русский", bcp47Locale: "ru-RU"),
        VoiceLanguage(code: "it", name: "Italian", nativeName: "Italiano", bcp47Locale: "it-IT"),
        VoiceLanguage(code: "nl", name: "Dutch", nativeName: "Nederlands", bcp47Locale: "nl-NL"),
        VoiceLanguage(code: "tr", name: "Turkish", nativeName: "Türkçe", bcp47Locale: "tr-TR"),
        VoiceLanguage(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt", bcp47Locale: "vi-VN"),
        VoiceLanguage(code: "th", name: "Thai", nativeName: "ไทย", bcp47Locale: "th-TH"),
        VoiceLanguage(code: "ms", name: "Malay", nativeName: "Bahasa Melayu", bcp47Locale: "ms-MY"),
        VoiceLanguage(code: "tl", name: "Tagalog", nativeName: "Tagalog", bcp47Locale: "fil-PH"),
        VoiceLanguage(code: "pl", name: "Polish", nativeName: "Polski", bcp47Locale: "pl-PL"),
        VoiceLanguage(code: "uk", name: "Ukrainian", nativeName: "Українська", bcp47Locale: "uk-UA"),
        VoiceLanguage(code: "sv", name: "Swedish", nativeName: "Svenska", bcp47Locale: "sv-SE"),
        VoiceLanguage(code: "da", name: "Danish", nativeName: "Dansk", bcp47Locale: "da-DK"),
        VoiceLanguage(code: "no", name: "Norwegian", nativeName: "Norsk", bcp47Locale: "nb-NO"),
        VoiceLanguage(code: "fi", name: "Finnish", nativeName: "Suomi", bcp47Locale: "fi-FI"),
        VoiceLanguage(code: "el", name: "Greek", nativeName: "Ελληνικά", bcp47Locale: "el-GR"),
        VoiceLanguage(code: "cs", name: "Czech", nativeName: "Čeština", bcp47Locale: "cs-CZ"),
        VoiceLanguage(code: "ro", name: "Romanian", nativeName: "Română", bcp47Locale: "ro-RO"),
        VoiceLanguage(code: "hu", name: "Hungarian", nativeName: "Magyar", bcp47Locale: "hu-HU"),
        VoiceLanguage(code: "he", name: "Hebrew", nativeName: "עברית", bcp47Locale: "he-IL"),
        VoiceLanguage(code: "fa", name: "Persian", nativeName: "فارسی", bcp47Locale: "fa-IR"),
        VoiceLanguage(code: "bn", name: "Bengali", nativeName: "বাংলা", bcp47Locale: "bn-BD"),
        VoiceLanguage(code: "ur", name: "Urdu", nativeName: "اردو", bcp47Locale: "ur-PK"),
        VoiceLanguage(code: "ta", name: "Tamil", nativeName: "தமிழ்", bcp47Locale: "ta-IN"),
        VoiceLanguage(code: "te", name: "Telugu", nativeName: "తెలుగు", bcp47Locale: "te-IN"),
        VoiceLanguage(code: "mr", name: "Marathi", nativeName: "मराठी", bcp47Locale: "mr-IN"),
        VoiceLanguage(code: "gu", name: "Gujarati", nativeName: "ગુજરાતી", bcp47Locale: "gu-IN"),
        VoiceLanguage(code: "kn", name: "Kannada", nativeName: "ಕನ್ನಡ", bcp47Locale: "kn-IN"),
        VoiceLanguage(code: "ml", name: "Malayalam", nativeName: "മലയാളം", bcp47Locale: "ml-IN"),
        VoiceLanguage(code: "pa", name: "Punjabi", nativeName: "ਪੰਜਾਬੀ", bcp47Locale: "pa-IN"),
        VoiceLanguage(code: "sw", name: "Swahili", nativeName: "Kiswahili", bcp47Locale: "sw-KE"),
        VoiceLanguage(code: "af", name: "Afrikaans", nativeName: "Afrikaans", bcp47Locale: "af-ZA"),
        VoiceLanguage(code: "am", name: "Amharic", nativeName: "አማርኛ", bcp47Locale: "am-ET"),
        VoiceLanguage(code: "az", name: "Azerbaijani", nativeName: "Azərbaycan", bcp47Locale: "az-AZ"),
        VoiceLanguage(code: "be", name: "Belarusian", nativeName: "Беларуская", bcp47Locale: "be-BY"),
        VoiceLanguage(code: "bg", name: "Bulgarian", nativeName: "Български", bcp47Locale: "bg-BG"),
        VoiceLanguage(code: "bs", name: "Bosnian", nativeName: "Bosanski", bcp47Locale: "bs-BA"),
        VoiceLanguage(code: "ca", name: "Catalan", nativeName: "Català", bcp47Locale: "ca-ES"),
        VoiceLanguage(code: "ceb", name: "Cebuano", nativeName: "Sinugboanon", bcp47Locale: "ceb-PH"),
        VoiceLanguage(code: "co", name: "Corsican", nativeName: "Corsu", bcp47Locale: "co-FR"),
        VoiceLanguage(code: "cy", name: "Welsh", nativeName: "Cymraeg", bcp47Locale: "cy-GB"),
        VoiceLanguage(code: "eo", name: "Esperanto", nativeName: "Esperanto", bcp47Locale: "eo"),
        VoiceLanguage(code: "et", name: "Estonian", nativeName: "Eesti", bcp47Locale: "et-EE"),
        VoiceLanguage(code: "eu", name: "Basque", nativeName: "Euskara", bcp47Locale: "eu-ES"),
        VoiceLanguage(code: "fil", name: "Filipino", nativeName: "Filipino", bcp47Locale: "fil-PH"),
        VoiceLanguage(code: "fy", name: "Western Frisian", nativeName: "Frysk", bcp47Locale: "fy-NL"),
        VoiceLanguage(code: "ga", name: "Irish", nativeName: "Gaeilge", bcp47Locale: "ga-IE"),
        VoiceLanguage(code: "gd", name: "Scottish Gaelic", nativeName: "Gàidhlig", bcp47Locale: "gd-GB"),
        VoiceLanguage(code: "gl", name: "Galician", nativeName: "Galego", bcp47Locale: "gl-ES"),
        VoiceLanguage(code: "ha", name: "Hausa", nativeName: "Hausa", bcp47Locale: "ha-NG"),
        VoiceLanguage(code: "haw", name: "Hawaiian", nativeName: "ʻŌlelo Hawaiʻi", bcp47Locale: "haw-US"),
        VoiceLanguage(code: "hmn", name: "Hmong", nativeName: "Hmoob", bcp47Locale: "hmn"),
        VoiceLanguage(code: "hr", name: "Croatian", nativeName: "Hrvatski", bcp47Locale: "hr-HR"),
        VoiceLanguage(code: "ht", name: "Haitian Creole", nativeName: "Kreyòl Ayisyen", bcp47Locale: "ht-HT"),
        VoiceLanguage(code: "hy", name: "Armenian", nativeName: "Հայերեն", bcp47Locale: "hy-AM"),
        VoiceLanguage(code: "ig", name: "Igbo", nativeName: "Asụsụ Igbo", bcp47Locale: "ig-NG"),
        VoiceLanguage(code: "is", name: "Icelandic", nativeName: "Íslenska", bcp47Locale: "is-IS"),
        VoiceLanguage(code: "ka", name: "Georgian", nativeName: "ქართული", bcp47Locale: "ka-GE"),
        VoiceLanguage(code: "kk", name: "Kazakh", nativeName: "Қазақ тілі", bcp47Locale: "kk-KZ"),
        VoiceLanguage(code: "km", name: "Khmer", nativeName: "ភាសាខ្មែរ", bcp47Locale: "km-KH"),
        VoiceLanguage(code: "ku", name: "Kurdish", nativeName: "Kurdî", bcp47Locale: "ku-TR"),
        VoiceLanguage(code: "ky", name: "Kyrgyz", nativeName: "Кыргызча", bcp47Locale: "ky-KG"),
        VoiceLanguage(code: "la", name: "Latin", nativeName: "Latina", bcp47Locale: "la"),
        VoiceLanguage(code: "lb", name: "Luxembourgish", nativeName: "Lëtzebuergesch", bcp47Locale: "lb-LU"),
        VoiceLanguage(code: "lo", name: "Lao", nativeName: "ລາວ", bcp47Locale: "lo-LA"),
        VoiceLanguage(code: "lt", name: "Lithuanian", nativeName: "Lietuvių", bcp47Locale: "lt-LT"),
        VoiceLanguage(code: "lv", name: "Latvian", nativeName: "Latviešu", bcp47Locale: "lv-LV"),
        VoiceLanguage(code: "mg", name: "Malagasy", nativeName: "Malagasy", bcp47Locale: "mg-MG"),
        VoiceLanguage(code: "mi", name: "Maori", nativeName: "Te Reo Māori", bcp47Locale: "mi-NZ"),
        VoiceLanguage(code: "mk", name: "Macedonian", nativeName: "Македонски", bcp47Locale: "mk-MK"),
        VoiceLanguage(code: "mn", name: "Mongolian", nativeName: "Монгол", bcp47Locale: "mn-MN"),
        VoiceLanguage(code: "mt", name: "Maltese", nativeName: "Malti", bcp47Locale: "mt-MT"),
        VoiceLanguage(code: "my", name: "Burmese", nativeName: "မြန်မာ", bcp47Locale: "my-MM"),
        VoiceLanguage(code: "ne", name: "Nepali", nativeName: "नेपाली", bcp47Locale: "ne-NP"),
        VoiceLanguage(code: "ny", name: "Chichewa", nativeName: "Chichewa", bcp47Locale: "ny-MW"),
        VoiceLanguage(code: "or", name: "Odia", nativeName: "ଓଡ଼ିଆ", bcp47Locale: "or-IN"),
        VoiceLanguage(code: "ps", name: "Pashto", nativeName: "پښتو", bcp47Locale: "ps-AF"),
        VoiceLanguage(code: "rw", name: "Kinyarwanda", nativeName: "Ikinyarwanda", bcp47Locale: "rw-RW"),
        VoiceLanguage(code: "sd", name: "Sindhi", nativeName: "سنڌي", bcp47Locale: "sd-PK"),
        VoiceLanguage(code: "si", name: "Sinhala", nativeName: "සිංහල", bcp47Locale: "si-LK"),
        VoiceLanguage(code: "sk", name: "Slovak", nativeName: "Slovenčina", bcp47Locale: "sk-SK"),
        VoiceLanguage(code: "sl", name: "Slovenian", nativeName: "Slovenščina", bcp47Locale: "sl-SI"),
        VoiceLanguage(code: "sm", name: "Samoan", nativeName: "Gagana Samoa", bcp47Locale: "sm-WS"),
        VoiceLanguage(code: "sn", name: "Shona", nativeName: "ChiShona", bcp47Locale: "sn-ZW"),
        VoiceLanguage(code: "so", name: "Somali", nativeName: "Soomaali", bcp47Locale: "so-SO"),
        VoiceLanguage(code: "sq", name: "Albanian", nativeName: "Shqip", bcp47Locale: "sq-AL"),
        VoiceLanguage(code: "sr", name: "Serbian", nativeName: "Српски", bcp47Locale: "sr-RS"),
        VoiceLanguage(code: "st", name: "Sesotho", nativeName: "Sesotho", bcp47Locale: "st-ZA"),
        VoiceLanguage(code: "tg", name: "Tajik", nativeName: "Тоҷикӣ", bcp47Locale: "tg-TJ"),
        VoiceLanguage(code: "tk", name: "Turkmen", nativeName: "Türkmençe", bcp47Locale: "tk-TM"),
        VoiceLanguage(code: "tt", name: "Tatar", nativeName: "Татарча", bcp47Locale: "tt-RU"),
        VoiceLanguage(code: "ug", name: "Uyghur", nativeName: "ئۇيغۇرچە", bcp47Locale: "ug-CN"),
        VoiceLanguage(code: "uz", name: "Uzbek", nativeName: "Oʻzbek", bcp47Locale: "uz-UZ"),
        VoiceLanguage(code: "xh", name: "Xhosa", nativeName: "isiXhosa", bcp47Locale: "xh-ZA"),
        VoiceLanguage(code: "yi", name: "Yiddish", nativeName: "ייִדיש", bcp47Locale: "yi"),
        VoiceLanguage(code: "yo", name: "Yoruba", nativeName: "Yorùbá", bcp47Locale: "yo-NG"),
        VoiceLanguage(code: "zu", name: "Zulu", nativeName: "isiZulu", bcp47Locale: "zu-ZA"),
        VoiceLanguage(code: "as", name: "Assamese", nativeName: "অসমীয়া", bcp47Locale: "as-IN"),
        VoiceLanguage(code: "ay", name: "Aymara", nativeName: "Aymar aru", bcp47Locale: "ay-BO"),
        VoiceLanguage(code: "bm", name: "Bambara", nativeName: "Bamanankan", bcp47Locale: "bm-ML"),
        VoiceLanguage(code: "bho", name: "Bhojpuri", nativeName: "भोजपुरी", bcp47Locale: "bho-IN"),
        VoiceLanguage(code: "dv", name: "Dhivehi", nativeName: "ދިވެހި", bcp47Locale: "dv-MV"),
        VoiceLanguage(code: "doi", name: "Dogri", nativeName: "डोगरी", bcp47Locale: "doi-IN"),
        VoiceLanguage(code: "ee", name: "Ewe", nativeName: "Eʋegbe", bcp47Locale: "ee-GH"),
        VoiceLanguage(code: "gn", name: "Guarani", nativeName: "Avañe'ẽ", bcp47Locale: "gn-PY"),
        VoiceLanguage(code: "ilo", name: "Ilocano", nativeName: "Ilokano", bcp47Locale: "ilo-PH"),
        VoiceLanguage(code: "kon", name: "Konkani", nativeName: "कोंकणी", bcp47Locale: "kok-IN"),
        VoiceLanguage(code: "kri", name: "Krio", nativeName: "Krio", bcp47Locale: "kri-SL"),
        VoiceLanguage(code: "ckb", name: "Kurdish (Sorani)", nativeName: "کوردیی ناوەندی", bcp47Locale: "ckb-IQ"),
        VoiceLanguage(code: "ln", name: "Lingala", nativeName: "Lingála", bcp47Locale: "ln-CD"),
        VoiceLanguage(code: "lg", name: "Luganda", nativeName: "Luganda", bcp47Locale: "lg-UG"),
        VoiceLanguage(code: "mai", name: "Maithili", nativeName: "मैथिली", bcp47Locale: "mai-IN"),
        VoiceLanguage(code: "mni", name: "Meiteilon (Manipuri)", nativeName: "মৈতৈলোন্", bcp47Locale: "mni-IN"),
        VoiceLanguage(code: "lus", name: "Mizo", nativeName: "Mizo ṭawng", bcp47Locale: "lus-IN"),
        VoiceLanguage(code: "om", name: "Oromo", nativeName: "Afaan Oromoo", bcp47Locale: "om-ET"),
        VoiceLanguage(code: "qu", name: "Quechua", nativeName: "Runa Simi", bcp47Locale: "qu-PE"),
        VoiceLanguage(code: "sa", name: "Sanskrit", nativeName: "संस्कृतम्", bcp47Locale: "sa-IN"),
        VoiceLanguage(code: "nso", name: "Sepedi", nativeName: "Sesotho sa Leboa", bcp47Locale: "nso-ZA"),
        VoiceLanguage(code: "ti", name: "Tigrinya", nativeName: "ትግርኛ", bcp47Locale: "ti-ER"),
        VoiceLanguage(code: "ts", name: "Tsonga", nativeName: "Xitsonga", bcp47Locale: "ts-ZA")
    ]

    public static func voice(forID id: String) -> CatalogVoice? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allVoices.first { $0.id.lowercased() == normalized }
    }

    public static func language(forCode code: String) -> VoiceLanguage? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedLanguages.first { $0.code.lowercased() == normalized }
    }

    public static func openAIVoiceName(forSelectedID id: String) -> String {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let matched = openAIVoices.first(where: { $0.id.lowercased() == normalized }) {
            return matched.id
        }
        return defaultOpenAIVoiceID
    }

    public static func geminiVoiceName(forSelectedID id: String) -> String {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let matched = geminiVoices.first(where: { $0.id.lowercased() == normalized }) {
            return matched.id
        }
        return defaultGeminiVoiceID
    }
}

@MainActor
public final class VoicePreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = VoicePreviewPlayer()

    @Published public private(set) var currentlyPlayingVoiceID: String?
    @Published public private(set) var isPlaying = false

    private var audioPlayer: AVAudioPlayer?

    private override init() {
        super.init()
    }

    public func playPreview(for voiceID: String) {
        if currentlyPlayingVoiceID == voiceID, isPlaying {
            stopPreview()
            return
        }

        stopPreview()

        guard let catalogVoice = VoiceLanguageCatalog.voice(forID: voiceID) else { return }
        let filename = catalogVoice.previewFilename
        let fileExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension

        let previewURL = Bundle.main.url(forResource: baseName, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: baseName, withExtension: fileExtension, subdirectory: "Resources")

        guard let url = previewURL else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            currentlyPlayingVoiceID = catalogVoice.id
            isPlaying = true
        } catch {
            currentlyPlayingVoiceID = nil
            isPlaying = false
        }
    }

    public func stopPreview() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentlyPlayingVoiceID = nil
        isPlaying = false
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.audioPlayer === player {
                self.audioPlayer = nil
                self.currentlyPlayingVoiceID = nil
                self.isPlaying = false
            }
        }
    }
}
