import Foundation

/// 第二批 B9：app 自带的示例卡「白石」。bundle 里放卡 JSON（spec v3），卡面用默认卡面生成器画，
/// 原 PNG = 卡面 + chara / ccv3，没改过时 PNG / JSON 导出就是这两份原字节
enum CardSample {
    static let id = "sample-baishi"
    static let resourceName = "sample-card-baishi"
    static var bundledURL: URL? { Bundle.main.url(forResource: resourceName, withExtension: "json") }

    static func make(json: Data) throws -> CharacterCard {
        var card = CharacterCard(from: try TavernCard.parseJSON(data: json))
        card.id = id
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let face = CardDefaultFace.png(name: card.name) else { throw TavernCardPNGWriter.Failure.imageEncode }
        card.imageData = try TavernCardPNGWriter.write(object, into: face, stripGeneratorMetadata: false)
        card.originals.thumbnail = CardImageThumbnail.make(from: face)
        return card
    }
}

extension CharacterCardManager {
    /// 首次加载插入一次：没删过、卡库里也没有才插；只进卡库不建楼层（点进去才走「一卡一楼层」）
    func insertSampleCardIfNeeded(resource: URL? = CardSample.bundledURL) {
        guard !defaults.bool(forKey: CardLibraryPreferences.sampleCardDismissedKey),
              !cards.contains(where: { $0.id == CardSample.id }), let resource else { return }
        do { try add(CardSample.make(json: Data(contentsOf: resource))) } catch {
            NSLog("示例卡插入失败：%@", error.localizedDescription)
        }
    }
}
