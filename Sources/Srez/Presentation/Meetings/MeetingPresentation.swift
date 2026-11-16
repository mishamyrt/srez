import Foundation

extension MeetingJob {
    var retryTitle: String {
        kind == .transcription ? "Повторить" : "Повторить суммаризацию"
    }
}

extension ProcessingStage {
    var title: String {
        switch self {
        case .queued: "В очереди"
        case .queuedForSummary: "В очереди на суммаризацию"
        case .convertingAudio: "Преобразование в WAV…"
        case .checkingModel: "Проверка модели…"
        case .loadingModel: "Загрузка модели…"
        case .recognizing: "Распознавание речи…"
        case let .downloadingModel(file, total): "Скачивание модели: файл \(file) из \(total)…"
        case let .extractingFacts(part, total): "Извлечение фактов: часть \(part) из \(total)…"
        case let .reducingFacts(part, total): "Сжатие фактов: часть \(part) из \(total)…"
        case .composingSummary: "Определение типа и сборка протокола…"
        case .savingTranscript: "Сохранение расшифровки…"
        case .savingSummary: "Сохранение…"
        case .cancelling: "Отмена…"
        case .cancelled: "Отменено"
        case .unsupportedFormat: "Неподдерживаемый формат"
        case .failed: "Ошибка"
        case .transcriptReady: "Расшифровка готова"
        case .completed: "Готово"
        }
    }
}
