import Foundation

enum TokenUsageResources {
    private static let bundleName = "TokenUsage_TokenUsageCore"

    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        // A normal macOS app keeps nested resource bundles under
        // Contents/Resources. SwiftPM command-line builds keep the same bundle
        // next to the executable, which Bundle.module resolves below.
        if
            let resourceRoot = Bundle.main.resourceURL,
            let nestedBundle = Bundle(
                url: resourceRoot.appendingPathComponent(bundleName).appendingPathExtension("bundle")
            ),
            let url = nestedBundle.url(forResource: name, withExtension: extensionName)
        {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: extensionName) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: extensionName)
    }
}
