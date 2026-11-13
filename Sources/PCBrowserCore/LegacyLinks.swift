import Foundation

/// The three external links in the original's Help menu (commands 391–393).
public enum LegacyLinks {
    public static let homepage = URL(string: "http://www.yupiteru.co.jp/")!
    public static let googleMapsTerms = URL(string: "https://www.google.com/help/terms_maps.html?hl=en")!
    public static let googlePrivacy = URL(string: "https://www.google.com/intl/ALL/policies/privacy/index.html")!
    public static func url(commandID: Int) -> URL? {
        switch commandID {
        case 391: return homepage
        case 392: return googleMapsTerms
        case 393: return googlePrivacy
        default: return nil
        }
    }
}
